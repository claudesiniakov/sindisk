import Foundation

/// Блокировка «много читателей — один писатель» для дерева файлов: фоновые обходы (поиск,
/// анализ, дубликаты, слепки) берут чтение, удаление узлов после очистки — запись.
public enum TreeAccess {
    private final class RWLock: @unchecked Sendable {
        var lock = pthread_rwlock_t()
        init() { pthread_rwlock_init(&lock, nil) }
        deinit { pthread_rwlock_destroy(&lock) }
    }

    private static let shared = RWLock()

    public static func read<T>(_ body: () throws -> T) rethrows -> T {
        pthread_rwlock_rdlock(&shared.lock)
        defer { pthread_rwlock_unlock(&shared.lock) }
        return try body()
    }

    public static func write<T>(_ body: () throws -> T) rethrows -> T {
        pthread_rwlock_wrlock(&shared.lock)
        defer { pthread_rwlock_unlock(&shared.lock) }
        return try body()
    }
}

/// Узел дерева файловой системы. Размеры каталогов агрегированы по всему поддереву.
public final class FileNode: Identifiable, @unchecked Sendable {
    public var id: ObjectIdentifier { ObjectIdentifier(self) }

    /// Имя элемента; у корня дерева — полный путь.
    public let name: String
    public let isDirectory: Bool
    public let isPackage: Bool
    public let isSymlink: Bool
    /// Фактически занятое место на диске (allocated size).
    public internal(set) var size: Int64
    /// Логический размер (сумма длин файлов).
    public internal(set) var logicalSize: Int64
    public internal(set) var fileCount: Int
    public let modified: Date?
    public let accessed: Date?
    public internal(set) var children: [FileNode] = []
    public internal(set) weak var parent: FileNode?
    public internal(set) var unreadable = false

    public init(
        name: String,
        isDirectory: Bool,
        isPackage: Bool = false,
        isSymlink: Bool = false,
        size: Int64 = 0,
        logicalSize: Int64 = 0,
        modified: Date? = nil,
        accessed: Date? = nil
    ) {
        self.name = name
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isSymlink = isSymlink
        self.size = size
        self.logicalSize = logicalSize
        self.fileCount = isDirectory ? 0 : 1
        self.modified = modified
        self.accessed = accessed
    }

    public var path: String {
        guard let parent else { return name }
        let p = parent.path
        return p.hasSuffix("/") ? p + name : p + "/" + name
    }

    public var url: URL { URL(fileURLWithPath: path) }

    public var displayName: String {
        parent == nil ? (name == "/" ? "Macintosh HD" : (name as NSString).lastPathComponent) : name
    }

    public var fileExtension: String { (name as NSString).pathExtension.lowercased() }

    public var kind: FileKind {
        if isDirectory {
            return isPackage && fileExtension == "app" ? .app : .folder
        }
        return FileKind(extension: fileExtension)
    }

    /// Цепочка от корня до узла включительно.
    public var ancestry: [FileNode] {
        var chain: [FileNode] = []
        var cur: FileNode? = self
        while let n = cur {
            chain.append(n)
            cur = n.parent
        }
        return chain.reversed()
    }

    public var depth: Int { ancestry.count - 1 }

    public func isDescendant(of other: FileNode) -> Bool {
        var cur = parent
        while let n = cur {
            if n === other { return true }
            cur = n.parent
        }
        return false
    }

    public func child(named childName: String) -> FileNode? {
        children.first { $0.name == childName }
    }

    /// Поиск узла по абсолютному пути внутри поддерева.
    public func node(atPath target: String) -> FileNode? {
        let base = path
        if target == base { return self }
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard target.hasPrefix(prefix) else { return nil }
        var cur = self
        for comp in target.dropFirst(prefix.count).split(separator: "/") {
            guard let next = cur.child(named: String(comp)) else { return nil }
            cur = next
        }
        return cur
    }

    /// Удаляет узел из дерева и пересчитывает размеры предков.
    public func detach() {
        TreeAccess.write {
            guard let parent else { return }
            parent.children.removeAll { $0 === self }
            var cur: FileNode? = parent
            while let n = cur {
                n.size -= size
                n.logicalSize -= logicalSize
                n.fileCount -= fileCount
                cur = n.parent
            }
            self.parent = nil
        }
    }

    func addChild(_ child: FileNode) {
        child.parent = self
        children.append(child)
    }

    func recomputeTotals() {
        var s: Int64 = 0, l: Int64 = 0, c = 0
        for ch in children {
            s += ch.size
            l += ch.logicalSize
            c += ch.fileCount
        }
        size = s
        logicalSize = l
        fileCount = c
        children.sort { $0.size > $1.size }
    }
}

public struct KindTotal: Identifiable, Hashable, Sendable {
    public var id: FileKind { kind }
    public let kind: FileKind
    public let size: Int64
}

/// Сводная статистика по дереву.
public enum TreeStats {
    /// Объём по типам файлов. Бандлы приложений учитываются целиком как «Приложения».
    public static func kindTotals(_ root: FileNode) -> [KindTotal] {
        TreeAccess.read { kindTotalsUnlocked(root) }
    }

    private static func kindTotalsUnlocked(_ root: FileNode) -> [KindTotal] {
        var totals: [FileKind: Int64] = [:]
        var stack = [root]
        while let n = stack.popLast() {
            for c in n.children {
                if c.isDirectory {
                    if c.isPackage {
                        totals[c.kind == .app ? .app : .other, default: 0] += c.size
                    } else {
                        stack.append(c)
                    }
                } else {
                    totals[c.kind, default: 0] += c.size
                }
            }
        }
        return totals.filter { $0.value > 0 }
            .map { KindTotal(kind: $0.key, size: $0.value) }
            .sorted { $0.size > $1.size }
    }

    /// Самые большие файлы дерева.
    public static func largestFiles(_ root: FileNode, limit: Int = 50) -> [FileNode] {
        TreeAccess.read { largestFilesUnlocked(root, limit: limit) }
    }

    private static func largestFilesUnlocked(_ root: FileNode, limit: Int) -> [FileNode] {
        var result: [FileNode] = []
        var minKept: Int64 = 0
        var stack = [root]
        while let n = stack.popLast() {
            for c in n.children {
                if c.isDirectory {
                    if !c.isPackage, c.size > minKept || result.count < limit { stack.append(c) }
                } else if result.count < limit || c.size > minKept {
                    result.append(c)
                    if result.count > limit * 2 {
                        result.sort { $0.size > $1.size }
                        result.removeLast(result.count - limit)
                        minKept = result.last?.size ?? 0
                    }
                }
            }
        }
        result.sort { $0.size > $1.size }
        return Array(result.prefix(limit))
    }
}
