import Foundation

public struct ScanProgress: Sendable, Equatable {
    public var files: Int = 0
    public var directories: Int = 0
    public var bytes: Int64 = 0
    public var unreadable: Int = 0
    public var currentPath: String = ""
    public init() {}
}

/// Параллельный обход файловой системы с подсчётом фактического размера на диске.
public final class DiskScanner: @unchecked Sendable {
    /// Пути, которые пропускаются при сканировании корня «/» (дубли Data-тома, внешние диски, псевдо-ФС).
    public static let rootExclusions: Set<String> = [
        "/System/Volumes", "/Volumes", "/dev", "/net", "/home", "/Network",
    ]

    public var excludedPaths: Set<String> = []

    private let lock = NSLock()
    private var state = ScanProgress()
    private var cancelled = false
    private var seenHardLinks = Set<InodeKey>()

    private struct InodeKey: Hashable {
        let dev: Int32
        let ino: UInt64
    }

    static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey,
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .totalFileSizeKey, .fileSizeKey,
        .contentModificationDateKey, .contentAccessDateKey, .linkCountKey,
    ]
    static let keySet = Set(keys)

    public init() {}

    public var progress: ScanProgress {
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

    /// Сканирует каталог и возвращает корень дерева (имя корня — полный путь).
    public func scan(path: String) -> FileNode {
        lock.lock()
        state = ScanProgress()
        cancelled = false
        seenHardLinks.removeAll()
        lock.unlock()

        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: Self.keySet)
        let root = FileNode(
            name: path,
            isDirectory: true,
            isPackage: values?.isPackage ?? false,
            modified: values?.contentModificationDate,
            accessed: values?.contentAccessDate
        )
        scanDirectory(root, url: url, depth: 0)
        return root
    }

    private func scanDirectory(_ node: FileNode, url: URL, depth: Int) {
        if isCancelled { return }
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: Self.keys, options: []
            )
        } catch {
            node.unreadable = true
            lock.lock()
            state.unreadable += 1
            lock.unlock()
            return
        }

        var subdirs: [(FileNode, URL)] = []
        var bytes: Int64 = 0
        var files = 0
        node.children.reserveCapacity(entries.count)

        for entry in entries {
            if !excludedPaths.isEmpty, excludedPaths.contains(entry.path) { continue }
            guard let v = try? entry.resourceValues(forKeys: Self.keySet) else { continue }
            let isLink = v.isSymbolicLink ?? false
            let isDir = (v.isDirectory ?? false) && !isLink
            if isDir {
                let child = FileNode(
                    name: entry.lastPathComponent,
                    isDirectory: true,
                    isPackage: v.isPackage ?? false,
                    modified: v.contentModificationDate,
                    accessed: v.contentAccessDate
                )
                node.addChild(child)
                subdirs.append((child, entry))
            } else {
                var allocated = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
                let logical = Int64(v.totalFileSize ?? v.fileSize ?? 0)
                if !isLink, (v.linkCount ?? 1) > 1, isRepeatedHardLink(entry.path) {
                    allocated = 0
                }
                let child = FileNode(
                    name: entry.lastPathComponent,
                    isDirectory: false,
                    isSymlink: isLink,
                    size: allocated,
                    logicalSize: logical,
                    modified: v.contentModificationDate,
                    accessed: v.contentAccessDate
                )
                node.addChild(child)
                bytes += allocated
                files += 1
            }
        }

        lock.lock()
        state.files += files
        state.directories += 1
        state.bytes += bytes
        state.currentPath = url.path
        lock.unlock()

        if depth < 2, subdirs.count > 1 {
            DispatchQueue.concurrentPerform(iterations: subdirs.count) { i in
                let (child, childURL) = subdirs[i]
                scanDirectory(child, url: childURL, depth: depth + 1)
            }
        } else {
            for (child, childURL) in subdirs {
                scanDirectory(child, url: childURL, depth: depth + 1)
            }
        }
        node.recomputeTotals()
    }

    /// Жёсткие ссылки на один и тот же inode учитываются в размере один раз.
    private func isRepeatedHardLink(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        let key = InodeKey(dev: st.st_dev, ino: UInt64(st.st_ino))
        lock.lock()
        defer { lock.unlock() }
        return !seenHardLinks.insert(key).inserted
    }
}
