import Foundation
import CryptoKit

/// Слепок размеров папок после сканирования — для сравнения «что выросло».
public struct ScanSnapshot: Codable, Sendable, Identifiable, Hashable {
    public var id: Date { date }
    public let rootPath: String
    public let date: Date
    public let total: Int64
    public let fileCount: Int
    /// Относительный путь → размер на диске (папки и крупные файлы).
    public let sizes: [String: Int64]

    public init(rootPath: String, date: Date, total: Int64, fileCount: Int, sizes: [String: Int64]) {
        self.rootPath = rootPath
        self.date = date
        self.total = total
        self.fileCount = fileCount
        self.sizes = sizes
    }

    public static func make(
        from root: FileNode,
        maxDepth: Int = 5,
        minSize: Int64 = 1_000_000,
        limit: Int = 20_000,
        date: Date = Date()
    ) -> ScanSnapshot {
        var sizes: [String: Int64] = [:]
        var queue: [(FileNode, String, Int)] = [(root, "", 0)]
        var head = 0
        while head < queue.count {
            let (node, rel, depth) = queue[head]
            head += 1
            guard depth < maxDepth else { continue }
            for c in node.children where c.size >= minSize {
                let p = rel.isEmpty ? c.name : rel + "/" + c.name
                sizes[p] = c.size
                if c.isDirectory { queue.append((c, p, depth + 1)) }
            }
        }
        if sizes.count > limit {
            sizes = Dictionary(uniqueKeysWithValues: sizes.sorted { $0.value > $1.value }.prefix(limit).map { ($0.key, $0.value) })
        }
        return ScanSnapshot(rootPath: root.path, date: date, total: root.size, fileCount: root.fileCount, sizes: sizes)
    }
}

public struct SizeChange: Identifiable, Hashable, Sendable {
    public var id: String { path }
    /// Путь относительно корня сканирования.
    public let path: String
    public let before: Int64
    public let after: Int64

    public var delta: Int64 { after - before }
    public var isNew: Bool { before == 0 }
    public var isGone: Bool { after == 0 }
    public var name: String { (path as NSString).lastPathComponent }
}

public enum SnapshotDiff {
    /// Изменения размеров между слепками. Папка не показывается, если почти весь её прирост
    /// объясняется одной вложенной папкой — тогда показывается именно она.
    public static func compare(old: ScanSnapshot, new: ScanSnapshot, minDelta: Int64 = 10_000_000, limit: Int = 200) -> [SizeChange] {
        let keys = Set(old.sizes.keys).union(new.sizes.keys)
        var candidates: [String: SizeChange] = [:]
        for k in keys {
            let change = SizeChange(path: k, before: old.sizes[k] ?? 0, after: new.sizes[k] ?? 0)
            if abs(change.delta) >= minDelta { candidates[k] = change }
        }
        var redundant = Set<String>()
        for (path, child) in candidates {
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                if let p = candidates[parent], (p.delta > 0) == (child.delta > 0),
                   Double(abs(child.delta)) >= 0.8 * Double(abs(p.delta)) {
                    redundant.insert(parent)
                }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        return candidates.values
            .filter { !redundant.contains($0.path) }
            .sorted { abs($0.delta) == abs($1.delta) ? $0.path < $1.path : abs($0.delta) > abs($1.delta) }
            .prefix(limit)
            .map { $0 }
    }
}

/// Хранилище слепков: по папке на каждый корень сканирования, не больше `keep` слепков.
public final class SnapshotStore: @unchecked Sendable {
    public let directory: URL
    public let keep: Int

    public init(directory: URL, keep: Int = 30) {
        self.directory = directory
        self.keep = keep
    }

    public static var defaultDirectory: URL {
        SessionStore.defaultDirectory.deletingLastPathComponent().appendingPathComponent("Snapshots", isDirectory: true)
    }

    private func folder(for root: String) -> URL {
        let key = SHA256.hash(data: Data(root.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key, isDirectory: true)
    }

    public func save(_ snapshot: ScanSnapshot) {
        let dir = folder(for: snapshot.rootPath)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let name = String(Int(snapshot.date.timeIntervalSince1970)) + ".json"
        if let data = try? encoder.encode(snapshot) {
            try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
        }
        let files = list(dir)
        for f in files.dropFirst(keep) { try? FileManager.default.removeItem(at: f) }
    }

    /// Слепки для корня, новые первыми.
    public func load(root: String) -> [ScanSnapshot] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return list(folder(for: root)).compactMap { try? decoder.decode(ScanSnapshot.self, from: Data(contentsOf: $0)) }
    }

    private func list(_ dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { (Int($0.deletingPathExtension().lastPathComponent) ?? 0) > (Int($1.deletingPathExtension().lastPathComponent) ?? 0) }
    }
}
