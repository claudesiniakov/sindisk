import XCTest
@testable import SinDiskCore

final class UpdateTests: XCTestCase {
    func testVersionComparison() throws {
        let v = { (s: String) in try XCTUnwrap(AppVersion(s)) }
        XCTAssertLessThan(try v("0.9.1"), try v("0.10.0"))
        XCTAssertLessThan(try v("v0.1.0"), try v("0.2"))
        XCTAssertEqual(try v("v1.0"), try v("1.0.0"))
        XCTAssertEqual(try v("1.2.0-beta").description, "1.2.0")
        XCTAssertFalse(try v("1.0.0") < v("1.0"))
        XCTAssertNil(AppVersion("f1700b2"))
        XCTAssertNil(AppVersion(""))
    }

    func testParseGitHubRelease() throws {
        let json = """
        {
          "tag_name": "v0.2.0",
          "name": "SinDisk 0.2.0",
          "body": "* Обновления внутри приложения",
          "html_url": "https://github.com/claudesiniakov/sindisk/releases/tag/v0.2.0",
          "published_at": "2026-11-10T08:00:00Z",
          "draft": false,
          "prerelease": false,
          "assets": [
            {"name": "SinDisk.zip", "size": 720000,
             "browser_download_url": "https://github.com/claudesiniakov/sindisk/releases/download/v0.2.0/SinDisk.zip"},
            {"name": "SinDisk.zip.sha256", "size": 78,
             "browser_download_url": "https://github.com/claudesiniakov/sindisk/releases/download/v0.2.0/SinDisk.zip.sha256"}
          ]
        }
        """
        let r = try ReleaseFeed.parse(Data(json.utf8))
        XCTAssertEqual(r.version, AppVersion("0.2.0"))
        XCTAssertEqual(r.title, "SinDisk 0.2.0")
        XCTAssertEqual(r.archiveSize, 720_000)
        XCTAssertNotNil(r.checksumURL)
        XCTAssertNotNil(r.publishedAt)
    }

    func testRejectsForeignDownloadsAndMissingArchive() {
        let foreign = """
        {"tag_name": "v9.9.9", "html_url": "https://github.com/x/y", "assets": [
          {"name": "SinDisk.zip", "browser_download_url": "https://evil.example.com/SinDisk.zip"}]}
        """
        XCTAssertThrowsError(try ReleaseFeed.parse(Data(foreign.utf8))) {
            XCTAssertEqual($0 as? ReleaseFeedError, .noArchive)
        }
        let noAssets = """
        {"tag_name": "v1.0.0", "html_url": "https://github.com/x/y", "assets": []}
        """
        XCTAssertThrowsError(try ReleaseFeed.parse(Data(noAssets.utf8)))
        XCTAssertThrowsError(try ReleaseFeed.parse(Data("not json".utf8)))
    }

    func testChecksum() throws {
        let t = try TempTree()
        let path = try t.file("SinDisk.zip", bytes: 0)
        try Data("abc".utf8).write(to: URL(fileURLWithPath: path))
        let sum = try UpdateVerifier.sha256(of: URL(fileURLWithPath: path))
        XCTAssertEqual(sum, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(UpdateVerifier.parseChecksum("\(sum)  SinDisk.zip\n"), sum)
        XCTAssertNil(UpdateVerifier.parseChecksum("xyz  SinDisk.zip"))
    }
}
