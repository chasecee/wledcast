import Foundation
import XCTest
@testable import WledCore

final class FilterPipelineTests: XCTestCase {
    func testFilterPipelineMatchesFixture() throws {
        let fixture = try FixtureLoader.loadJSON(name: "filter_fixture")
        let inputWidth = fixture["input_width"] as! Int
        let inputHeight = fixture["input_height"] as! Int
        let outputWidth = fixture["output_width"] as! Int
        let outputHeight = fixture["output_height"] as! Int
        let inputPixels = fixture["input_pixels"] as! [Int]
        let outputPixels = fixture["output_pixels"] as! [Int]
        let filters = fixture["filters"] as! [String: Any]

        let frame = RGBFrame(width: inputWidth, height: inputHeight, pixels: inputPixels.map(UInt8.init))
        let config = FilterConfig(
            sharpen: (filters["sharpen"] as! NSNumber).floatValue,
            saturation: (filters["saturation"] as! NSNumber).floatValue,
            brightness: (filters["brightness"] as! NSNumber).floatValue,
            contrast: (filters["contrast"] as! NSNumber).floatValue,
            balanceR: (filters["balance_r"] as! NSNumber).floatValue,
            balanceG: (filters["balance_g"] as! NSNumber).floatValue,
            balanceB: (filters["balance_b"] as! NSNumber).floatValue
        )

        let processed = FramePipeline.process(
            frame: frame,
            output: OutputResolution(width: outputWidth, height: outputHeight),
            filters: config
        )

        let expected = outputPixels.map(UInt8.init)
        XCTAssertEqual(processed.pixels.count, expected.count)
        let maxDelta = zip(processed.pixels, expected).map { abs(Int($0) - Int($1)) }.max() ?? 0
        XCTAssertLessThanOrEqual(maxDelta, 80)
    }

    func testResizeIncludesBottomEdgeContribution() {
        let sourceWidth = 6
        let sourceHeight = 7
        var pixels = [UInt8](repeating: 0, count: sourceWidth * sourceHeight * 3)
        for x in 0..<sourceWidth {
            let i = ((sourceHeight - 1) * sourceWidth + x) * 3
            pixels[i] = 255
        }

        let frame = RGBFrame(width: sourceWidth, height: sourceHeight, pixels: pixels)
        let processed = FramePipeline.process(
            frame: frame,
            output: OutputResolution(width: 3, height: 3),
            filters: neutralFilters
        )

        let bottomLeftRed = processed.pixels[((2 * 3) + 0) * 3]
        let bottomCenterRed = processed.pixels[((2 * 3) + 1) * 3]
        let bottomRightRed = processed.pixels[((2 * 3) + 2) * 3]
        XCTAssertGreaterThan(bottomLeftRed, 0)
        XCTAssertGreaterThan(bottomCenterRed, 0)
        XCTAssertGreaterThan(bottomRightRed, 0)
    }

    func testResizeIsDeterministicAcrossRepeatedCalls() {
        let sourceWidth = 436
        let sourceHeight = 132
        var pixels = [UInt8](repeating: 0, count: sourceWidth * sourceHeight * 3)
        for y in 0..<sourceHeight {
            for x in 0..<sourceWidth {
                let i = (y * sourceWidth + x) * 3
                pixels[i] = UInt8((x * 7 + y * 3) % 256)
                pixels[i + 1] = UInt8((x * 5 + y * 11) % 256)
                pixels[i + 2] = UInt8((x * 13 + y * 2) % 256)
            }
        }

        let frame = RGBFrame(width: sourceWidth, height: sourceHeight, pixels: pixels)
        let output = OutputResolution(width: 60, height: 18)
        let first = FramePipeline.process(frame: frame, output: output, filters: neutralFilters)

        for _ in 0..<20 {
            let next = FramePipeline.process(frame: frame, output: output, filters: neutralFilters)
            XCTAssertEqual(next.pixels, first.pixels)
        }
    }

    private var neutralFilters: FilterConfig {
        FilterConfig(
            sharpen: 0,
            saturation: 1,
            brightness: 1,
            contrast: 1,
            balanceR: 1,
            balanceG: 1,
            balanceB: 1
        )
    }
}
