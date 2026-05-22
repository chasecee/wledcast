import CoreGraphics
import XCTest
@testable import WledCore

final class WindowLayoutTests: XCTestCase {
    func testCaptureRectExcludesSettingsHeight() {
        let windowFrame = CGRect(x: 120, y: 80, width: 640, height: 500)
        let settingsHeight: CGFloat = 180

        let topFrame = OverlayWindowController.topRegionFrame(
            windowFrame: windowFrame,
            settingsHeight: settingsHeight
        )

        XCTAssertEqual(topFrame.minX, 120, accuracy: 0.001)
        XCTAssertEqual(topFrame.minY, 260, accuracy: 0.001)
        XCTAssertEqual(topFrame.width, 640, accuracy: 0.001)
        XCTAssertEqual(topFrame.height, 320, accuracy: 0.001)
    }

    func testVideoAspectFitForTopRegion() {
        let fitted = OverlayWindowController.fittedSize(
            for: 16.0 / 9.0,
            starting: CGSize(width: 900, height: 800),
            minimumWidth: 360,
            minimumHeight: 32
        )

        XCTAssertEqual(fitted.width / fitted.height, 16.0 / 9.0, accuracy: 0.001)
    }

    func testMinimumWindowWidthFollowsSettingsMinimumWidth() {
        let minimum = OverlayWindowController.minimumWindowSize(
            settingsHeight: 220,
            minimumSettingsWidth: 420
        )

        XCTAssertEqual(minimum.width, 420, accuracy: 0.001)
        XCTAssertEqual(minimum.height, 252, accuracy: 0.001)
    }
}
