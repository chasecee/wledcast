import XCTest
@testable import WledCore

final class TemporalSmootherTests: XCTestCase {
    func testStrengthZeroPassesThrough() {
        let smoother = TemporalSmoother()
        let first = RGBFrame(width: 2, height: 1, pixels: [10, 20, 30, 40, 50, 60])
        let second = RGBFrame(width: 2, height: 1, pixels: [70, 80, 90, 100, 110, 120])

        _ = smoother.apply(frame: first, strength: 0)
        let out = smoother.apply(frame: second, strength: 0)

        XCTAssertEqual(out.pixels, second.pixels)
    }

    func testStrengthOneFreezesOutput() {
        let smoother = TemporalSmoother()
        let first = RGBFrame(width: 1, height: 1, pixels: [20, 40, 60])
        let second = RGBFrame(width: 1, height: 1, pixels: [220, 200, 180])

        let seeded = smoother.apply(frame: first, strength: 1)
        let frozen = smoother.apply(frame: second, strength: 1)

        XCTAssertEqual(seeded.pixels, first.pixels)
        XCTAssertEqual(frozen.pixels, first.pixels)
    }

    func testDeadbandSuppressesSmallChanges() {
        let smoother = TemporalSmoother()
        let first = RGBFrame(width: 1, height: 1, pixels: [100, 100, 100])
        let second = RGBFrame(width: 1, height: 1, pixels: [103, 103, 103])

        _ = smoother.apply(frame: first, strength: 0.5)
        let out = smoother.apply(frame: second, strength: 0.5)

        XCTAssertEqual(out.pixels, first.pixels)
    }
}
