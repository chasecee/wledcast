import CoreGraphics
import XCTest
@testable import WledCore

final class MosaicPlacementTests: XCTestCase {
    func testRegionModeMosaicMatchesTopRegionInnerBounds() {
        let rect = OverlayWindowController.mosaicRect(
            mode: .region,
            topSize: CGSize(width: 600, height: 360),
            border: 4,
            videoRect: .zero,
            cropBox: .full
        )

        XCTAssertEqual(rect.origin.x, 4, accuracy: 0.001)
        XCTAssertEqual(rect.origin.y, 4, accuracy: 0.001)
        XCTAssertEqual(rect.width, 592, accuracy: 0.001)
        XCTAssertEqual(rect.height, 352, accuracy: 0.001)
    }

    func testVideoModeMosaicMatchesCropRect() {
        let rect = OverlayWindowController.mosaicRect(
            mode: .video,
            topSize: CGSize(width: 800, height: 450),
            border: 4,
            videoRect: CGRect(x: 100, y: 20, width: 600, height: 360),
            cropBox: VideoCropBox(x: 0.25, y: 0.1, width: 0.5, height: 0.6)
        )

        XCTAssertEqual(rect.origin.x, 250, accuracy: 0.001)
        XCTAssertEqual(rect.origin.y, 56, accuracy: 0.001)
        XCTAssertEqual(rect.width, 300, accuracy: 0.001)
        XCTAssertEqual(rect.height, 216, accuracy: 0.001)
    }
}
