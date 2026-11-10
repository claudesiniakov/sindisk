import XCTest
@testable import SinDiskCore

final class DuplicateFinderTests: XCTestCase {
    func testFindsExactDuplicatesOnly() throws {
        let t = try TempTree()
        let size = 300_000
        try t.file("photos/a.jpg", bytes: size, seed: 7)
        try t.file("backup/a copy.jpg", bytes: size, seed: 7)
        // Тот же размер, те же начало и конец, но другая середина — не дубликат.
        try t.file("other/c.jpg", bytes: size, seed: 7, tail: 0xEE)
        // Жёсткая ссылка — не дубликат (одни и те же данные).
        try FileManager.default.linkItem(atPath: t.root + "/photos/a.jpg", toPath: t.root + "/photos/link.jpg")
        // Маленькие одинаковые файлы (хэшируются целиком на первом этапе).
        try t.file("s1.txt", bytes: 5_000, seed: 3)
        try t.file("s2.txt", bytes: 5_000, seed: 3)
        // Ниже порога — игнорируется.
        try t.file("tiny1", bytes: 10)
        try t.file("tiny2", bytes: 10)

        let root = DiskScanner().scan(path: t.root)
        let finder = DuplicateFinder(home: "/nonexistent-home")
        finder.minSize = 1024
        let groups = finder.find(in: root)

        XCTAssertEqual(groups.count, 2)
        let big = try XCTUnwrap(groups.first { $0.size == Int64(size) })
        XCTAssertEqual(big.files.count, 2)
        XCTAssertFalse(big.files.contains { $0.path.hasSuffix("c.jpg") })
        XCTAssertEqual(big.wasted, Int64(size))
        XCTAssertEqual(big.kind, .image)
        XCTAssertEqual(groups.first?.id, big.id, "Группы отсортированы по лишнему объёму")
    }

    func testKeepRules() {
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000_000)
        let g = DuplicateGroup(id: "x", size: 10, files: [
            DuplicateFile(path: "/Users/u/Downloads/a.jpg", size: 10, modified: old, created: old),
            DuplicateFile(path: "/Users/u/Pictures/long/path/a.jpg", size: 10, modified: new, created: new),
            DuplicateFile(path: "/Users/u/a.jpg", size: 10, modified: new, created: new),
        ])
        XCTAssertEqual(KeepRule.oldest.keeper(in: g, home: "/Users/u").path, "/Users/u/Downloads/a.jpg")
        XCTAssertEqual(KeepRule.shortestPath.keeper(in: g, home: "/Users/u").path, "/Users/u/a.jpg")
        XCTAssertNotEqual(KeepRule.notInDownloads.keeper(in: g, home: "/Users/u").path, "/Users/u/Downloads/a.jpg")
    }
}

final class CleanEngineTests: XCTestCase {
    func makeEngine(_ t: TempTree) throws -> CleanEngine {
        let store = SessionStore(directory: URL(fileURLWithPath: try t.dir(".sessions")))
        return CleanEngine(safety: SafetyGuard(home: "/nonexistent-home", ownBundlePath: nil), store: store)
    }

    func testTrashAndUndo() throws {
        let t = try TempTree()
        let path = try t.file("junk/file.log", bytes: 4_000)
        let engine = try makeEngine(t)

        let session = engine.clean([CleanRequest(path: path, size: 4_000)], title: "test")
        XCTAssertEqual(session.records.first?.status, .done, session.records.first?.message ?? "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(session.canUndo)
        XCTAssertEqual(session.freed, 4_000)
        XCTAssertEqual(engine.store?.load().first?.id, session.id, "Сессия сохранена в журнал")

        let undone = engine.undo(session)
        XCTAssertEqual(undone.records.first?.status, .restored)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertFalse(undone.canUndo)
    }

    func testProtectedAndChangedFilesAreNotDeleted() throws {
        let t = try TempTree()
        let path = try t.file("doc.txt", bytes: 100)
        let engine = try makeEngine(t)
        let session = engine.clean([
            CleanRequest(path: "/System/Library/CoreServices/SystemVersion.plist", size: 1),
            CleanRequest(path: path, size: 100, expectedModified: Date(timeIntervalSince1970: 0)),
            CleanRequest(path: t.root + "/missing.txt", size: 1),
        ], title: "safety")
        XCTAssertEqual(session.records.map(\.status), [.failed, .skipped, .skipped])
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(session.freed, 0)
    }

    func testPermanentDelete() throws {
        let t = try TempTree()
        let path = try t.file("cache/blob", bytes: 1_000)
        let engine = try makeEngine(t)
        let session = engine.clean([CleanRequest(path: path, size: 1_000, mode: .permanent)], title: "perm")
        XCTAssertEqual(session.records.first?.status, .done)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertFalse(session.canUndo)
    }

    func testReplaceWithCloneKeepsPathAndContent() throws {
        let t = try TempTree()
        let keeper = try t.file("a/orig.bin", bytes: 200_000, seed: 9)
        let dup = try t.file("b/copy.bin", bytes: 200_000, seed: 9)
        let engine = try makeEngine(t)

        let session = engine.clean([CleanRequest(path: dup, size: 200_000, mode: .cloneOf(keeper))], title: "clone")
        let record = try XCTUnwrap(session.records.first)
        XCTAssertEqual(record.status, .done, record.message ?? "")
        XCTAssertTrue(FileManager.default.contentsEqual(atPath: keeper, andPath: dup))
        XCTAssertNotNil(record.trashedPath)

        let undone = engine.undo(session)
        XCTAssertEqual(undone.records.first?.status, .restored)
        XCTAssertTrue(FileManager.default.contentsEqual(atPath: keeper, andPath: dup))
    }
}
