import Foundation
import XCTest
@testable import WledCore

final class YouTubeDownloaderTests: XCTestCase {
    func testRejectsNonYouTubeURL() async throws {
        let downloader = YouTubeDownloader()
        let scriptURL = URL(fileURLWithPath: "/tmp/fetch_video.sh")
        do {
            _ = try await downloader.fetch(url: "https://example.com/foo", scriptURL: scriptURL)
            XCTFail("expected invalidURL")
        } catch let error as YouTubeDownloaderError {
            XCTAssertEqual(error, .invalidURL)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testParsesSavedPathFromScriptOutput() {
        let output = "line one\nsaved: /tmp/x.mp4 (12.3MB)\n"
        let result = YouTubeDownloader.parseSavedPath(from: output)
        XCTAssertEqual(result?.path, "/tmp/x.mp4")
    }
}
