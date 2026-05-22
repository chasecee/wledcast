import Foundation
import XCTest
@testable import WledCore

final class VideoSettingsStoreTests: XCTestCase {
    func testVideoKeyUsesYouTubeID() {
        let url = URL(fileURLWithPath: "/tmp/macro-flowers-trimmed-a_KReRCKZQI.mp4")
        XCTAssertEqual(VideoKey.from(url: url), "a_KReRCKZQI")
    }

    func testVideoKeyFallsBackToFilename() {
        let url = URL(fileURLWithPath: "/tmp/local-clip.mp4")
        XCTAssertEqual(VideoKey.from(url: url), "local-clip")
    }

    func testSaveAndLoadRoundTrip() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("video-settings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }

        let store = VideoSettingsStore(fileURL: file)
        let url = URL(fileURLWithPath: "/tmp/caterpillar-3KODjN2uHVQ.mp4")
        let settings = VideoSettings(
            crop: VideoCropBox(x: 0.1, y: 0.2, width: 0.5, height: 0.5),
            loopRange: LoopRange(start: 0.1, end: 0.9)
        )
        store.save(settings, for: url)

        let reloaded = VideoSettingsStore(fileURL: file)
        let loaded = reloaded.settings(for: url)
        XCTAssertEqual(loaded.crop, settings.crop)
        XCTAssertEqual(loaded.loopRange, settings.loopRange)
    }

    func testPruneRemovesMissingVideos() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("video-settings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }

        let store = VideoSettingsStore(fileURL: file)
        let keep = URL(fileURLWithPath: "/tmp/keep-3KODjN2uHVQ.mp4")
        let drop = URL(fileURLWithPath: "/tmp/drop-abc12345678.mp4")
        store.save(VideoSettings(), for: keep)
        store.save(VideoSettings(loopRange: LoopRange(start: 0.2, end: 0.8)), for: drop)
        store.prune(keeping: [keep])

        let reloaded = VideoSettingsStore(fileURL: file)
        XCTAssertEqual(reloaded.settings(for: keep).loopRange, .full)
        XCTAssertEqual(reloaded.settings(for: drop).loopRange, .full)
    }
}
