import Foundation
import CryptoKit

public struct DuplicateFile: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let size: Int64
    public let modified: Date?
    public let created: Date?

    public var name: String { (path as NSString).lastPathComponent }
    public var directory: String { (path as NSString).deletingLastPathComponent }
}

public struct DuplicateGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public let size: Int64
    public var files: [DuplicateFile]

    public var kind: FileKind { FileKind(extension: (name as NSString).pathExtension) }
    public var name: String { files.first?.name ?? "" }
    /// Объём, который освободится, если оставить одну копию.
    public var wasted: Int64 { size * Int64(max(files.count - 1, 0)) }
}

public enum KeepRule: String, CaseIterable, Identifiable, Sendable {
    case oldest, newest, shortestPath, notInDownloads

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .oldest: return "Самую старую"
        case .newest: return "Самую новую"
        case .shortestPath: return "С самым коротким путём"
        case .notInDownloads: return "Не из Загрузок"
        }
    }

    public func keeper(in group: DuplicateGroup, home: String = NSHomeDirectory()) -> DuplicateFile {
        let files = group.files
        func birth(_ f: DuplicateFile) -> Date { f.created ?? f.modified ?? .distantFuture }
        switch self {
        case .oldest:
            return files.min { birth($0) < birth($1) }!
        case .newest:
            return files.max { ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast) }!
        case .shortestPath:
            return files.min { ($0.path.count, $0.path) < ($1.path.count, $1.path) }!
        case .notInDownloads:
            let downloads = home + "/Downloads"
            let outside = files.filter { !SafetyGuard.isInside($0.path, downloads) }
            let pool = outside.isEmpty ? files : outside
            return pool.min { birth($0) < birth($1) }!
        }
    }
}

public struct DuplicateProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable { case idle, collecting, partialHash, fullHash, done }
    public var phase: Phase = .idle
    public var done: Int = 0
    public var total: Int = 0
    public init() {}

    public var title: String {
        switch phase {
        case .idle: return ""
        case .collecting: return "Сбор файлов"
        case .partialHash: return "Быстрое сравнение"
        case .fullHash: return "Полное сравнение содержимого"
        case .done: return "Готово"
        }
    }
}

/// Поиск точных дубликатов: размер → хэш начала и конца файла → полный хэш (SHA-256).
public final class DuplicateFinder: @unchecked Sendable {
    public var minSize: Int64 = 1024
    public var includeLibrary = false
    public let home: String

    static let edgeChunk = 64 * 1024
    static let skippedDirectoryNames: Set<String> = [".git", "node_modules", ".Trash"]

    private let lock = NSLock()
    private var state = DuplicateProgress()
    private var cancelled = false

    public init(home: String = NSHomeDirectory()) {
        self.home = home
    }

    public var progress: DuplicateProgress {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    private func setPhase(_ phase: DuplicateProgress.Phase, total: Int) {
        lock.lock()
        state.phase = phase
        state.total = total
        state.done = 0
        lock.unlock()
    }

    private func tick() {
        lock.lock()
        state.done += 1
        lock.unlock()
    }

    private struct Entry {
        let path: String
        let size: Int64
        let modified: Date?
    }

    public func find(in root: FileNode) -> [DuplicateGroup] {
        setPhase(.collecting, total: 0)
        let bySize = Dictionary(grouping: collect(root), by: \.size).filter { $0.value.count > 1 }

        // Отбрасываем жёсткие ссылки на один и тот же inode и собираем даты создания.
        var candidates: [(entry: Entry, created: Date?)] = []
        for (_, entries) in bySize {
            var seen = Set<String>()
            var unique: [(Entry, Date?)] = []
            for e in entries {
                var st = stat()
                guard lstat(e.path, &st) == 0 else { continue }
                let key = "\(st.st_dev):\(st.st_ino)"
                guard seen.insert(key).inserted else { continue }
                let created = Date(timeIntervalSince1970: TimeInterval(st.st_birthtimespec.tv_sec))
                unique.append((e, created))
            }
            if unique.count > 1 { candidates.append(contentsOf: unique.map { (entry: $0.0, created: $0.1) }) }
        }
        if isCancelled { return [] }

        // Этап 1: хэш первых и последних 64 КБ.
        setPhase(.partialHash, total: candidates.count)
        let partial = hashAll(candidates.map(\.entry)) { [self] e in partialHash(e) }
        if isCancelled { return [] }

        var byPartial: [String: [Int]] = [:]
        for (i, h) in partial.enumerated() {
            guard let h else { continue }
            byPartial["\(candidates[i].entry.size)-\(h)", default: []].append(i)
        }
        byPartial = byPartial.filter { $0.value.count > 1 }

        // Этап 2: полный хэш для файлов, которые не прочитаны целиком на первом этапе.
        let needFull = byPartial.values.flatMap { $0 }.filter { candidates[$0].entry.size > Int64(2 * Self.edgeChunk) }
        setPhase(.fullHash, total: needFull.count)
        let fullHashes = hashAll(needFull.map { candidates[$0].entry }) { [self] e in fullHash(e) }
        if isCancelled { return [] }
        var fullByIndex: [Int: String] = [:]
        for (k, idx) in needFull.enumerated() {
            if let h = fullHashes[k] { fullByIndex[idx] = h }
        }

        var groups: [String: [Int]] = [:]
        for (key, indices) in byPartial {
            for i in indices {
                if candidates[i].entry.size > Int64(2 * Self.edgeChunk) {
                    guard let full = fullByIndex[i] else { continue }
                    groups["\(candidates[i].entry.size)-\(full)", default: []].append(i)
                } else {
                    groups[key, default: []].append(i)
                }
            }
        }

        let result: [DuplicateGroup] = groups.compactMap { key, indices in
            guard indices.count > 1 else { return nil }
            let files = indices.map { i -> DuplicateFile in
                let c = candidates[i]
                return DuplicateFile(path: c.entry.path, size: c.entry.size, modified: c.entry.modified, created: c.created)
            }.sorted { $0.path < $1.path }
            return DuplicateGroup(id: key, size: files[0].size, files: files)
        }
        setPhase(.done, total: result.count)
        return result.sorted { $0.wasted == $1.wasted ? $0.id < $1.id : $0.wasted > $1.wasted }
    }

    // MARK: - Сбор файлов

    private func collect(_ root: FileNode) -> [Entry] {
        let homeLibrary = home + "/Library"
        var out: [Entry] = []
        var stack: [(FileNode, String)] = [(root, root.path)]
        while let item = stack.popLast() {
            let (dir, dirPath) = item
            if isCancelled { return [] }
            for c in dir.children {
                let p = dirPath.hasSuffix("/") ? dirPath + c.name : dirPath + "/" + c.name
                if c.isDirectory {
                    if c.isPackage || c.name.hasPrefix(".") || Self.skippedDirectoryNames.contains(c.name) { continue }
                    if !includeLibrary, p == homeLibrary { continue }
                    if p == "/System" || p == "/Library" || p == "/private" || p == "/usr" { continue }
                    stack.append((c, p))
                } else if !c.isSymlink, !c.name.hasPrefix("."), c.logicalSize >= minSize, c.size > 0 {
                    out.append(Entry(path: p, size: c.logicalSize, modified: c.modified))
                }
            }
        }
        return out
    }

    // MARK: - Хэширование

    private func hashAll(_ entries: [Entry], _ hash: @escaping (Entry) -> String?) -> [String?] {
        var results = [String?](repeating: nil, count: entries.count)
        let resultLock = NSLock()
        DispatchQueue.concurrentPerform(iterations: entries.count) { i in
            if isCancelled { return }
            let h = hash(entries[i])
            resultLock.lock()
            results[i] = h
            resultLock.unlock()
            tick()
        }
        return results
    }

    private func partialHash(_ e: Entry) -> String? {
        guard let handle = FileHandle(forReadingAtPath: e.path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunk = Self.edgeChunk
        do {
            if e.size <= Int64(2 * chunk) {
                while let data = try handle.read(upToCount: chunk), !data.isEmpty { hasher.update(data: data) }
            } else {
                if let head = try handle.read(upToCount: chunk) { hasher.update(data: head) }
                try handle.seek(toOffset: UInt64(e.size) - UInt64(chunk))
                if let tail = try handle.read(upToCount: chunk) { hasher.update(data: tail) }
            }
        } catch {
            return nil
        }
        return Self.hex(hasher.finalize())
    }

    private func fullHash(_ e: Entry) -> String? {
        guard let handle = FileHandle(forReadingAtPath: e.path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while true {
                if isCancelled { return nil }
                let ok: Bool = try autoreleasepool {
                    guard let data = try handle.read(upToCount: 1 << 20), !data.isEmpty else { return false }
                    hasher.update(data: data)
                    return true
                }
                if !ok { break }
            }
        } catch {
            return nil
        }
        return Self.hex(hasher.finalize())
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
