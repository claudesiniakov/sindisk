import Foundation

/// Сохранение дерева последнего сканирования на диск, чтобы приложение открывалось
/// сразу с картой, а не с пустым экраном. Формат: компактный двоичный, сжатие LZFSE.
public enum TreeCache {
    static let magic: [UInt8] = Array("SDT1".utf8)

    private enum Flag {
        static let directory: UInt8 = 1
        static let package: UInt8 = 2
        static let symlink: UInt8 = 4
        static let unreadable: UInt8 = 8
        static let hasModified: UInt8 = 16
        static let hasAccessed: UInt8 = 32
    }

    // MARK: - Запись

    public static func encode(_ root: FileNode, scannedAt: Date) -> Data {
        var out = [UInt8]()
        out.reserveCapacity(1 << 20)
        out.append(contentsOf: magic)
        put(scannedAt.timeIntervalSinceReferenceDate.bitPattern, &out)
        TreeAccess.read { write(root, &out) }
        return Data(out)
    }

    private static func put<T: FixedWidthInteger>(_ value: T, _ out: inout [UInt8]) {
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
    }

    private static func write(_ node: FileNode, _ out: inout [UInt8]) {
        var flags: UInt8 = 0
        if node.isDirectory { flags |= Flag.directory }
        if node.isPackage { flags |= Flag.package }
        if node.isSymlink { flags |= Flag.symlink }
        if node.unreadable { flags |= Flag.unreadable }
        if node.modified != nil { flags |= Flag.hasModified }
        if node.accessed != nil { flags |= Flag.hasAccessed }
        out.append(flags)
        let name = Array(node.name.utf8.prefix(Int(UInt16.max)))
        put(UInt16(name.count), &out)
        out.append(contentsOf: name)
        if let m = node.modified { put(m.timeIntervalSinceReferenceDate.bitPattern, &out) }
        if let a = node.accessed { put(a.timeIntervalSinceReferenceDate.bitPattern, &out) }
        if node.isDirectory {
            put(UInt32(node.children.count), &out)
            for c in node.children { write(c, &out) }
        } else {
            put(node.size, &out)
            put(node.logicalSize, &out)
        }
    }

    // MARK: - Чтение

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0

        mutating func take<T: FixedWidthInteger>(_ type: T.Type) -> T? {
            let n = MemoryLayout<T>.size
            guard offset + n <= bytes.count else { return nil }
            var value: T = 0
            withUnsafeMutableBytes(of: &value) { dst in
                bytes.withUnsafeBytes { src in
                    dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: src[offset..<offset + n]))
                }
            }
            offset += n
            return T(littleEndian: value)
        }

        mutating func string(_ count: Int) -> String? {
            guard offset + count <= bytes.count else { return nil }
            defer { offset += count }
            return String(decoding: bytes[offset..<offset + count], as: UTF8.self)
        }

        mutating func date() -> Date? {
            take(UInt64.self).map { Date(timeIntervalSinceReferenceDate: Double(bitPattern: $0)) }
        }
    }

    public static func decode(_ data: Data) -> (root: FileNode, scannedAt: Date)? {
        var r = Reader(bytes: Array(data))
        guard r.bytes.count > magic.count, Array(r.bytes[0..<magic.count]) == magic else { return nil }
        r.offset = magic.count
        guard let scannedAt = r.date(), let root = read(&r, depth: 0), r.offset == r.bytes.count else { return nil }
        return (root, scannedAt)
    }

    private static func read(_ r: inout Reader, depth: Int) -> FileNode? {
        guard depth < 512, let flags = r.take(UInt8.self), let nameLength = r.take(UInt16.self),
              let name = r.string(Int(nameLength)) else { return nil }
        var modified: Date?, accessed: Date?
        if flags & Flag.hasModified != 0 {
            guard let d = r.date() else { return nil }
            modified = d
        }
        if flags & Flag.hasAccessed != 0 {
            guard let d = r.date() else { return nil }
            accessed = d
        }
        if flags & Flag.directory != 0 {
            guard let count = r.take(UInt32.self) else { return nil }
            let node = FileNode(name: name, isDirectory: true, isPackage: flags & Flag.package != 0,
                                modified: modified, accessed: accessed)
            node.unreadable = flags & Flag.unreadable != 0
            node.children.reserveCapacity(Int(min(count, 100_000)))
            for _ in 0..<count {
                guard let child = read(&r, depth: depth + 1) else { return nil }
                node.addChild(child)
            }
            node.recomputeTotals()
            return node
        }
        guard let size = r.take(Int64.self), let logical = r.take(Int64.self) else { return nil }
        return FileNode(name: name, isDirectory: false, isSymlink: flags & Flag.symlink != 0,
                        size: size, logicalSize: logical, modified: modified, accessed: accessed)
    }

    // MARK: - Файл

    public static var defaultURL: URL {
        SessionStore.defaultDirectory.deletingLastPathComponent().appendingPathComponent("LastScan.bin")
    }

    public static func save(_ root: FileNode, scannedAt: Date, to url: URL = defaultURL) throws {
        let raw = encode(root, scannedAt: scannedAt)
        let packed = try (raw as NSData).compressed(using: .lzfse)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (packed as Data).write(to: url, options: .atomic)
    }

    public static func load(from url: URL = defaultURL) -> (root: FileNode, scannedAt: Date)? {
        guard let packed = try? Data(contentsOf: url),
              let raw = try? (packed as NSData).decompressed(using: .lzfse) else { return nil }
        return decode(raw as Data)
    }
}
