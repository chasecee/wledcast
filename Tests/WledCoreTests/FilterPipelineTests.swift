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
}
