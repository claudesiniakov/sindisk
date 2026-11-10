import XCTest
@testable import SinDiskCore

final class ScannerTests: XCTestCase {
    func testScanBuildsTreeWithAggregatedSizes() throws {
        let t = try TempTree()
        try t.file("a/one.bin", bytes: 10_000)
        try t.file("a/two.bin", bytes: 20_000)
        try t.file("b/deep/three.mov", bytes: 300_000)
        try t.file("top.txt", bytes: 100)

        let root = DiskScanner().scan(path: t.root)
        XCTAssertEqual(root.fileCount, 4)
        XCTAssertEqual(root.logicalSize, 330_100)
        XCTAssertGreaterThanOrEqual(root.size, 330_100)
        XCTAssertEqual(root.children.first?.name, "b", "Дети отсортированы по убыванию размера")

        let movie = try XCTUnwrap(root.node(atPath: t.root + "/b/deep/three.mov"))
        XCTAssertEqual(movie.kind, .video)
        XCTAssertEqual(movie.path, t.root + "/b/deep/three.mov")
        XCTAssertNil(root.node(atPath: t.root + "/missing"))
    }

    func testDetachUpdatesAncestors() throws {
        let t = try TempTree()
        try t.file("a/one.bin", bytes: 10_000)
        try t.file("a/two.bin", bytes: 20_000)
        let root = DiskScanner().scan(path: t.root)
        let before = root.size
        let two = try XCTUnwrap(root.node(atPath: t.root + "/a/two.bin"))
        let twoSize = two.size
        two.detach()
        XCTAssertEqual(root.size, before - twoSize)
        XCTAssertEqual(root.fileCount, 1)
        XCTAssertNil(root.node(atPath: t.root + "/a/two.bin"))
    }

    func testHardLinksCountedOnce() throws {
        let t = try TempTree()
        let a = try t.file("a.bin", bytes: 200_000)
        try FileManager.default.linkItem(atPath: a, toPath: t.root + "/b.bin")
        let root = DiskScanner().scan(path: t.root)
        let sizes = root.children.map(\.size).sorted()
        XCTAssertEqual(sizes.first, 0, "Вторая жёсткая ссылка не занимает места")
        XCTAssertGreaterThan(sizes.last ?? 0, 0)
    }

    func testExclusionsAndSymlinks() throws {
        let t = try TempTree()
        try t.file("keep/x.bin", bytes: 5_000)
        try t.file("skip/y.bin", bytes: 5_000)
        try FileManager.default.createSymbolicLink(atPath: t.root + "/loop", withDestinationPath: t.root)
        let scanner = DiskScanner()
        scanner.excludedPaths = [t.root + "/skip"]
        let root = scanner.scan(path: t.root)
        XCTAssertNil(root.child(named: "skip"))
        let link = try XCTUnwrap(root.child(named: "loop"))
        XCTAssertFalse(link.isDirectory, "Символические ссылки не обходятся")
        XCTAssertTrue(link.isSymlink)
    }

    func testTreeStats() throws {
        let t = try TempTree()
        try t.file("v.mp4", bytes: 50_000)
        try t.file("p.jpg", bytes: 20_000)
        try t.file("App.app/Contents/MacOS/bin", bytes: 30_000)
        let root = DiskScanner().scan(path: t.root)
        let kinds = Dictionary(uniqueKeysWithValues: TreeStats.kindTotals(root).map { ($0.kind, $0.size) })
        XCTAssertNotNil(kinds[.video])
        XCTAssertNotNil(kinds[.image])
        XCTAssertNotNil(kinds[.app], "Бандл .app учитывается как приложение")
        XCTAssertEqual(TreeStats.largestFiles(root, limit: 1).first?.name, "v.mp4")
    }
}
