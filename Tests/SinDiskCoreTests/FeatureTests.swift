import XCTest
@testable import SinDiskCore

final class UninstallerTests: XCTestCase {
    private func makeApp(_ t: TempTree, dir: String, name: String, bundleID: String) throws -> String {
        let app = try t.dir("\(dir)/\(name).app/Contents")
        let plist: NSDictionary = ["CFBundleIdentifier": bundleID, "CFBundleShortVersionString": "2.1"]
        XCTAssertTrue(plist.write(toFile: app + "/Info.plist", atomically: true))
        try t.file("\(dir)/\(name).app/Contents/MacOS/\(name)", bytes: 50_000)
        return (app as NSString).deletingLastPathComponent
    }

    func testFindsAppsAndLeftovers() throws {
        let t = try TempTree()
        let home = try t.dir("home")
        let appPath = try makeApp(t, dir: "Applications", name: "Foo Editor", bundleID: "com.example.FooEditor")
        _ = try makeApp(t, dir: "Applications/Suite", name: "Bar", bundleID: "com.example.bar")
        _ = try makeApp(t, dir: "Applications", name: "Notes", bundleID: "com.apple.Notes")

        try t.file("home/Library/Application Support/com.example.FooEditor/db.sqlite", bytes: 20_000)
        try t.file("home/Library/Application Support/Foo Editor/state.json", bytes: 1_000)
        try t.file("home/Library/Caches/com.example.FooEditor/cache.bin", bytes: 30_000)
        try t.file("home/Library/Caches/com.example.FooEditor.helper/x", bytes: 1_000)
        try t.file("home/Library/Preferences/com.example.FooEditor.plist", bytes: 500)
        try t.file("home/Library/Saved Application State/com.example.FooEditor.savedState/w", bytes: 500)
        try t.file("home/Library/Group Containers/ABCDE12345.com.example.FooEditor/data", bytes: 800)
        try t.file("home/Library/Caches/com.example.FooEditorPro/other", bytes: 800)   // чужое
        try t.file("home/Library/Logs/Foo/log.txt", bytes: 100)                         // не совпадает

        let u = AppUninstaller(home: home, appDirectories: [t.root + "/Applications"])
        let apps = u.installedApps()
        XCTAssertEqual(apps.map(\.name), ["Bar", "Foo Editor"], "Приложения Apple не показываются, подпапки учитываются")
        let foo = try XCTUnwrap(apps.first { $0.bundleID == "com.example.FooEditor" })
        XCTAssertEqual(foo.version, "2.1")
        XCTAssertEqual(foo.path, appPath)

        let files = u.files(for: AppUninstaller.measure(foo))
        let names = Set(files.map(\.name))
        XCTAssertEqual(files.first?.kind, .bundle)
        XCTAssertTrue(names.isSuperset(of: [
            "Foo Editor.app", "com.example.FooEditor", "Foo Editor", "com.example.FooEditor.helper",
            "com.example.FooEditor.plist", "com.example.FooEditor.savedState", "ABCDE12345.com.example.FooEditor",
        ]))
        XCTAssertFalse(names.contains("com.example.FooEditorPro"))
        XCTAssertFalse(names.contains("Foo"))
        XCTAssertTrue(files.allSatisfy { $0.size > 0 })

        // Все найденные пути разрешены к удалению, сами папки Library — нет.
        let guard_ = SafetyGuard(home: home, ownBundlePath: nil)
        XCTAssertTrue(files.allSatisfy { guard_.check($0.path).isAllowed }, "\(files.map(\.path))")
        XCTAssertFalse(guard_.check(home + "/Library/Preferences").isAllowed)
    }
}

final class DevToolsTests: XCTestCase {
    func testParseDocker() {
        let out = """
        {"Active":"2","Reclaimable":"1.2GB (60%)","Size":"2GB","TotalCount":"5","Type":"Images"}
        {"Active":"1","Reclaimable":"300MB (100%)","Size":"300MB","TotalCount":"3","Type":"Containers"}
        {"Active":"1","Reclaimable":"5GB (90%)","Size":"6GB","TotalCount":"2","Type":"Local Volumes"}
        {"Active":"0","Reclaimable":"512.5kB","Size":"512.5kB","TotalCount":"7","Type":"Build Cache"}
        """
        XCTAssertEqual(DevToolsCleaner.parseDockerReclaimable(out), 1_200_000_000 + 300_000_000 + 512_500)
    }

    func testParseSimulators() {
        let json = """
        {"devices": {
          "com.apple.CoreSimulator.SimRuntime.iOS-16-0": [
            {"udid": "AAA", "isAvailable": false, "name": "iPhone 14"},
            {"udid": "BBB", "isAvailable": true, "name": "iPhone 14 Pro"}],
          "com.apple.CoreSimulator.SimRuntime.iOS-15-0": [
            {"udid": "CCC", "isAvailable": false, "name": "iPhone 13"}]
        }}
        """
        XCTAssertEqual(Set(DevToolsCleaner.parseUnavailableSimulators(json)), ["AAA", "CCC"])
        XCTAssertTrue(DevToolsCleaner.parseUnavailableSimulators("oops").isEmpty)
    }

    func testParseBrew() {
        let out = """
        Would remove: /Users/u/Library/Caches/Homebrew/node--21.1.0.bottle.tar.gz (12.4MB)
        ==> This operation would free approximately 1.5GB of disk space.
        """
        XCTAssertEqual(DevToolsCleaner.parseBrewDryRun(out), 1_500_000_000)
        XCTAssertNil(DevToolsCleaner.parseBrewDryRun("nothing to do"))
    }

    func testShellRunCapturesOutputAndTimeout() {
        let r = Shell.run("/bin/sh", ["-c", "echo hello; echo oops 1>&2; exit 3"])
        XCTAssertEqual(r.status, 3)
        XCTAssertEqual(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
        XCTAssertEqual(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines), "oops")
        XCTAssertFalse(r.ok)

        let slow = Shell.run("/bin/sleep", ["5"], timeout: 0.5)
        XCTAssertTrue(slow.timedOut)

        let missing = Shell.run("/nonexistent/tool", [])
        XCTAssertFalse(missing.ok)
    }
}

final class SnapshotTests: XCTestCase {
    func testSnapshotAndDiff() throws {
        let t = try TempTree()
        try t.file("Projects/app/build/out.bin", bytes: 3_000_000)
        try t.file("Projects/app/src/main.swift", bytes: 2_000_000)
        try t.file("Movies/old.mov", bytes: 4_000_000)
        let before = ScanSnapshot.make(from: DiskScanner().scan(path: t.root), minSize: 1_000_000,
                                       date: Date(timeIntervalSince1970: 1_000))
        XCTAssertNotNil(before.sizes["Projects/app/build"])
        XCTAssertNotNil(before.sizes["Movies/old.mov"])

        // Сборка выросла, фильм удалён, появилась новая папка.
        try t.file("Projects/app/build/out2.bin", bytes: 6_000_000)
        try FileManager.default.removeItem(atPath: t.root + "/Movies/old.mov")
        try t.file("Downloads/new.dmg", bytes: 5_000_000)
        let after = ScanSnapshot.make(from: DiskScanner().scan(path: t.root), minSize: 1_000_000,
                                      date: Date(timeIntervalSince1970: 2_000))

        let changes = SnapshotDiff.compare(old: before, new: after, minDelta: 1_000_000)
        let byPath = Dictionary(uniqueKeysWithValues: changes.map { ($0.path, $0) })
        // Рост объясняется одним новым файлом — показан он, а не цепочка родительских папок.
        XCTAssertTrue(byPath["Projects/app/build/out2.bin"]?.isNew ?? false)
        XCTAssertNil(byPath["Projects/app/build"])
        XCTAssertNil(byPath["Projects/app"])
        XCTAssertNil(byPath["Projects"])
        XCTAssertTrue(byPath["Movies/old.mov"]?.isGone ?? false)
        XCTAssertTrue(changes.contains { $0.path.hasPrefix("Downloads") && $0.isNew })
        XCTAssertEqual(changes.first.map { abs($0.delta) }, changes.map { abs($0.delta) }.max())
    }

    func testFolderShownWhenGrowthIsSpreadOut() {
        let old = ScanSnapshot(rootPath: "/r", date: Date(timeIntervalSince1970: 1), total: 100, fileCount: 1,
                               sizes: ["Mail": 50_000_000, "Mail/A": 20_000_000, "Mail/B": 20_000_000])
        let new = ScanSnapshot(rootPath: "/r", date: Date(timeIntervalSince1970: 2), total: 200, fileCount: 1,
                               sizes: ["Mail": 110_000_000, "Mail/A": 50_000_000, "Mail/B": 50_000_000])
        let changes = SnapshotDiff.compare(old: old, new: new, minDelta: 10_000_000)
        XCTAssertEqual(changes.first?.path, "Mail", "Рост поровну в двух папках — показан их общий родитель первым")
        XCTAssertEqual(changes.count, 3)
    }

    func testStoreKeepsNewestFirst() throws {
        let t = try TempTree()
        let store = SnapshotStore(directory: URL(fileURLWithPath: try t.dir("snaps")), keep: 2)
        for i in 1...3 {
            store.save(ScanSnapshot(rootPath: "/Users/u", date: Date(timeIntervalSince1970: Double(i) * 1000),
                                    total: Int64(i), fileCount: i, sizes: ["a": Int64(i)]))
        }
        store.save(ScanSnapshot(rootPath: "/", date: Date(timeIntervalSince1970: 5000), total: 9, fileCount: 9, sizes: [:]))
        let loaded = store.load(root: "/Users/u")
        XCTAssertEqual(loaded.map(\.total), [3, 2], "Хранятся последние `keep`, новые первыми")
        XCTAssertEqual(store.load(root: "/").count, 1, "Корни хранятся раздельно")
    }
}

final class SafetyFixTests: XCTestCase {
    private func engine() -> CleanEngine {
        CleanEngine(safety: SafetyGuard(home: "/nonexistent-home", ownBundlePath: nil), store: nil)
    }

    func testDuplicateIsKeptWhenKeeperChangedOrMissing() throws {
        let t = try TempTree()
        let keeper = try t.file("a/orig.bin", bytes: 100_000, seed: 5)
        let dup = try t.file("b/copy.bin", bytes: 100_000, seed: 5)
        // Оставляемая копия изменилась после поиска дубликатов.
        try t.file("a/orig.bin", bytes: 100_000, seed: 6)

        let clone = engine().clean([CleanRequest(path: dup, size: 100_000, mode: .cloneOf(keeper))], title: "t")
        XCTAssertEqual(clone.records.first?.status, .skipped)
        let trash = engine().clean([CleanRequest(path: dup, size: 100_000, mode: .trash, mustMatch: keeper)], title: "t")
        XCTAssertEqual(trash.records.first?.status, .skipped)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dup), "Копия не тронута")

        try FileManager.default.removeItem(atPath: keeper)
        let gone = engine().clean([CleanRequest(path: dup, size: 100_000, mode: .trash, mustMatch: keeper)], title: "t")
        XCTAssertEqual(gone.records.first?.status, .skipped)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dup), "Последняя копия не удаляется")
    }

    func testCachesOfRunningAppsAreNotPreselected() throws {
        let t = try TempTree()
        try t.file("Library/Caches/com.example.Browser/data", bytes: 9_000)
        try t.file("Library/Caches/com.example.Browser.helper/data", bytes: 9_000)
        try t.file("Library/Caches/com.example.Idle/data", bytes: 9_000)
        let analyzer = Analyzer(home: t.root, runningBundleIDs: ["com.example.browser"])
        let caches = try XCTUnwrap(analyzer.analyze(tree: DiskScanner().scan(path: t.root)).first { $0.category == .caches })
        let byName = Dictionary(uniqueKeysWithValues: caches.items.map { ($0.name, $0) })
        XCTAssertEqual(byName["com.example.Browser"]?.selectedByDefault, false)
        XCTAssertEqual(byName["com.example.Browser.helper"]?.selectedByDefault, false)
        XCTAssertNotNil(byName["com.example.Browser"]?.note)
        XCTAssertEqual(byName["com.example.Idle"]?.selectedByDefault, true)
    }

    func testTreeCanBeReadWhileNodesAreDetached() throws {
        let t = try TempTree()
        for i in 0..<300 { try t.file("d\(i % 10)/f\(i).bin", bytes: 2_000) }
        let root = DiskScanner().scan(path: t.root)
        let victims = root.children.flatMap(\.children)
        let query = SearchQuery.parse("*.bin")
        let done = expectation(description: "readers")
        DispatchQueue.global().async {
            for _ in 0..<200 {
                _ = SearchEngine.search(root: root, query: query)
                _ = TreeStats.kindTotals(root)
            }
            done.fulfill()
        }
        for v in victims { v.detach() }
        wait(for: [done], timeout: 60)
        XCTAssertEqual(root.fileCount, 0)
        XCTAssertEqual(root.size, 0)
    }
}
