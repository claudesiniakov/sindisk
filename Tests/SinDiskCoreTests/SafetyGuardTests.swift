import XCTest
@testable import SinDiskCore

final class SafetyGuardTests: XCTestCase {
    let guard_ = SafetyGuard(home: "/Users/test", ownBundlePath: "/Applications/SinDisk.app")

    func testSystemAreasAreProtected() {
        for p in ["/System/Library/Kernels/kernel", "/usr/bin/ls", "/bin/sh", "/sbin/mount",
                  "/private/var/db/receipts/x", "/Library/Apple/System", "/private/var/vm/sleepimage", "/etc/hosts"] {
            XCTAssertFalse(guard_.check(p).isAllowed, p)
        }
    }

    func testUsrLocalIsAllowedButNotItsRoot() {
        XCTAssertTrue(guard_.check("/usr/local/Cellar/old").isAllowed)
        XCTAssertFalse(guard_.check("/usr/local").isAllowed)
    }

    func testRootFoldersAreProtectedButContentsAllowed() {
        for p in ["/", "/Users", "/Applications", "/Users/test", "/Users/test/Documents", "/Users/test/Downloads",
                  "/Users/test/Library", "/Users/test/Library/Caches", "/Users/test/.Trash"] {
            XCTAssertFalse(guard_.check(p).isAllowed, p)
        }
        for p in ["/Users/test/Documents/report.pdf", "/Users/test/Library/Caches/com.example.app",
                  "/Users/test/Downloads/setup.dmg", "/Applications/Old.app"] {
            XCTAssertTrue(guard_.check(p).isAllowed, p)
        }
    }

    func testPersonalDataIsProtected() {
        for p in ["/Users/test/Library/Keychains/login.keychain-db", "/Users/test/Library/Messages/chat.db",
                  "/Users/test/Library/Mail/V10", "/Users/test/Pictures/Photos Library.photoslibrary/originals/a.heic"] {
            XCTAssertFalse(guard_.check(p).isAllowed, p)
        }
    }

    func testOwnBundleAndRelativePaths() {
        XCTAssertFalse(guard_.check("/Applications/SinDisk.app/Contents/MacOS/SinDisk").isAllowed)
        XCTAssertFalse(guard_.check("relative/path").isAllowed)
    }

    func testDotDotCannotEscape() {
        XCTAssertFalse(guard_.check("/Users/test/Documents/../Documents").isAllowed)
        XCTAssertFalse(guard_.check("/Users/test/Downloads/../../../System/Library").isAllowed)
    }

    func testSymlinkedParentIsResolved() throws {
        let t = try TempTree()
        let realDir = try t.dir("real")
        try t.file("real/a.txt", bytes: 10)
        let link = t.root + "/link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: realDir)
        XCTAssertEqual(SafetyGuard.normalize(link + "/a.txt"), realDir + "/a.txt")
        // Сама ссылка не раскрывается: удаляется ссылка, а не цель.
        XCTAssertEqual(SafetyGuard.normalize(link), link)
    }
}
