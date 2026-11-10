import Foundation
import XCTest

/// Временная папка с файлами для тестов.
final class TempTree {
    let root: String

    init() throws {
        let base = FileManager.default.temporaryDirectory.path
        root = SafetyGuardNormalized(base + "/sindisk-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    @discardableResult
    func file(_ relative: String, bytes: Int, seed: UInt8 = 1, tail: UInt8? = nil) throws -> String {
        let path = root + "/" + relative
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { buf in
            for i in 0..<bytes { buf[i] = UInt8(truncatingIfNeeded: i &* 31 &+ Int(seed)) }
        }
        if let tail, bytes > 0 {
            data[bytes / 2] = tail
        }
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    func dir(_ relative: String) throws -> String {
        let path = root + "/" + relative
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    func setModified(_ path: String, daysAgo: Double) throws {
        let date = Date().addingTimeInterval(-daysAgo * 86_400)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: root)
    }
}

/// Канонический путь (/var → /private/var), чтобы пути в тестах совпадали с путями сканера.
func SafetyGuardNormalized(_ path: String) -> String {
    let parent = (path as NSString).deletingLastPathComponent
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard realpath(parent, &buffer) != nil else { return path }
    return String(cString: buffer) + "/" + (path as NSString).lastPathComponent
}
