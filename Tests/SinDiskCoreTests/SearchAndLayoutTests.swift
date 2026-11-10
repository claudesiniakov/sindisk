import XCTest
import CoreGraphics
@testable import SinDiskCore

final class SearchTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testParseFilters() {
        let q = SearchQuery.parse("отчёт *.mov size:>1GB ext:.dmg,ZIP kind:video in:~/Downloads -in:~/Projects type:file",
                                  now: now, home: "/Users/u")
        XCTAssertEqual(q.terms, [SearchQuery.fold("отчёт")])
        XCTAssertEqual(q.globs, ["*.mov"])
        XCTAssertEqual(q.minSize, 1_000_000_000)
        XCTAssertNil(q.maxSize)
        XCTAssertEqual(q.extensions, ["dmg", "zip"])
        XCTAssertEqual(q.kinds, [.video])
        XCTAssertEqual(q.inPaths, ["/Users/u/Downloads"])
        XCTAssertEqual(q.notInPaths, ["/Users/u/Projects"])
        XCTAssertEqual(q.onlyFiles, true)
        XCTAssertTrue(q.errors.isEmpty)
    }

    func testSizeRangeAndDates() {
        let q = SearchQuery.parse("size:100MB..500MB opened:>1y modified:<7d", now: now)
        XCTAssertEqual(q.minSize, 100_000_000)
        XCTAssertEqual(q.maxSize, 500_000_000)
        XCTAssertEqual(q.openedBefore, now.addingTimeInterval(-365 * 86_400))
        XCTAssertNil(q.openedAfter)
        XCTAssertEqual(q.modifiedAfter, now.addingTimeInterval(-7 * 86_400))
        XCTAssertNotNil(SearchQuery.parse("modified:<2025-01-01").modifiedBefore)
        XCTAssertFalse(SearchQuery.parse("size:lots").errors.isEmpty)
    }

    func testFoldingIgnoresCaseAndYo() {
        XCTAssertEqual(SearchQuery.fold("ЁЛКА"), SearchQuery.fold("елка"))
    }

    func testByteParse() {
        XCTAssertEqual(ByteFormat.parse("1.5GB"), 1_500_000_000)
        XCTAssertEqual(ByteFormat.parse("500 МБ"), 500_000_000)
        XCTAssertEqual(ByteFormat.parse("10k"), 10_000)
        XCTAssertNil(ByteFormat.parse("abc"))
    }

    func testSearchOverTree() throws {
        let t = try TempTree()
        try t.file("Downloads/Setup.dmg", bytes: 50_000)
        try t.file("Downloads/notes.txt", bytes: 100)
        try t.file("Movies/Trip.MOV", bytes: 80_000)
        try t.file("Projects/Trip.mov", bytes: 90_000)
        let root = DiskScanner().scan(path: t.root)

        let movs = SearchEngine.search(root: root, query: SearchQuery.parse("*.mov -in:\(t.root)/Projects"))
        XCTAssertEqual(movs.map(\.name), ["Trip.MOV"])

        let dl = SearchEngine.search(root: root, query: SearchQuery.parse("in:\(t.root)/Downloads size:>10KB"))
        XCTAssertEqual(dl.map(\.name), ["Setup.dmg"])

        let byKind = SearchEngine.search(root: root, query: SearchQuery.parse("kind:installer"))
        XCTAssertEqual(byKind.count, 1)

        let folders = SearchEngine.search(root: root, query: SearchQuery.parse("movies"))
        XCTAssertEqual(folders.first?.isDirectory, true, "Папки находятся по имени")

        XCTAssertTrue(SearchEngine.search(root: root, query: SearchQuery.parse("")).isEmpty)
    }
}

final class LayoutTests: XCTestCase {
    func testSquarifyFillsRectInOrder() {
        let values: [Double] = [6, 6, 4, 3, 2, 2, 1, 0]
        let rect = CGRect(x: 0, y: 0, width: 600, height: 400)
        let rects = Treemap.squarify(values, in: rect)
        XCTAssertEqual(rects.count, values.count)
        let area = rects.reduce(0.0) { $0 + Double($1.width * $1.height) }
        XCTAssertEqual(area, 600 * 400, accuracy: 1)
        XCTAssertEqual(rects.last, .zero, "Нулевое значение — пустой прямоугольник")
        for (v, r) in zip(values, rects) where v > 0 {
            XCTAssertEqual(Double(r.width * r.height), v / 24 * 240_000, accuracy: 1)
            XCTAssertTrue(rect.insetBy(dx: -0.5, dy: -0.5).contains(r))
        }
    }

    func testSunburstCoversFullCircle() throws {
        let t = try TempTree()
        try t.file("a/1.bin", bytes: 40_000)
        try t.file("a/2.bin", bytes: 30_000)
        try t.file("b.bin", bytes: 30_000)
        let root = DiskScanner().scan(path: t.root)
        let arcs = Sunburst.layout(root: root)
        let ring1 = arcs.filter { $0.depth == 1 }
        XCTAssertEqual(ring1.reduce(0) { $0 + ($1.end - $1.start) }, 2 * .pi, accuracy: 1e-9)
        XCTAssertTrue(arcs.contains { $0.depth == 2 })
        let hit = Sunburst.hit(arcs, depth: 1, angle: 0.01)
        XCTAssertEqual(hit?.node.name, "a")
    }

    func testTilesNestSecondLevel() throws {
        let t = try TempTree()
        try t.file("a/1.bin", bytes: 400_000)
        try t.file("a/2.bin", bytes: 300_000)
        try t.file("b.bin", bytes: 100_000)
        let root = DiskScanner().scan(path: t.root)
        let tiles = Treemap.tiles(for: root, in: CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertTrue(tiles.contains { $0.level == 2 })
        XCTAssertEqual(tiles.filter { $0.level == 1 }.count, 2)
    }
}

final class AnalyzerTests: XCTestCase {
    func testCategoriesFromFakeHome() throws {
        let t = try TempTree()
        let home = t.root
        try t.file("Library/Caches/com.example.app/data.bin", bytes: 20_000)
        try t.file("Library/Caches/com.apple.Safari/cache.db", bytes: 10_000)
        try t.file("Library/Logs/app.log", bytes: 3_000)
        try t.file("Library/Developer/Xcode/DerivedData/MyApp-abc/Build/x.o", bytes: 50_000)
        try t.file("Downloads/Installer.dmg", bytes: 40_000)
        let old = try t.file("Downloads/old.zip", bytes: 1_000)
        try t.setModified(old, daysAgo: 400)
        try t.file("Projects/web/node_modules/lib/index.js", bytes: 7_000)
        try t.file("Movies/huge.mov", bytes: 2_000_000)
        try t.file("Library/Application Support/com.gone.app/state.bin", bytes: 5_000)

        let tree = DiskScanner().scan(path: home)
        let analyzer = Analyzer(
            home: home,
            settings: AnalyzerSettings(largeFileBytes: 1_000_000),
            appInstalled: { _ in false }
        )
        let results = Dictionary(uniqueKeysWithValues: analyzer.analyze(tree: tree).map { ($0.category, $0) })

        let caches = try XCTUnwrap(results[.caches])
        XCTAssertEqual(caches.items.count, 2)
        XCTAssertTrue(caches.items.first { $0.name == "com.example.app" }!.selectedByDefault)
        XCTAssertFalse(caches.items.first { $0.name == "com.apple.Safari" }!.selectedByDefault)
        XCTAssertNotNil(results[.logs])
        XCTAssertEqual(results[.xcode]?.items.first?.name, "MyApp-abc")
        XCTAssertEqual(results[.installers]?.items.first?.name, "Installer.dmg")
        XCTAssertEqual(results[.oldDownloads]?.items.first?.name, "old.zip")
        XCTAssertEqual(results[.nodeModules]?.items.first?.note, "Проект «web»")
        XCTAssertEqual(results[.largeFiles]?.items.first?.name, "huge.mov")
        XCTAssertEqual(results[.leftovers]?.items.first?.name, "com.gone.app")
        XCTAssertNil(results[.trash])
    }
}
