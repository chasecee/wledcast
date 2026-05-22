import Accelerate
import Foundation
import XCTest
@testable import WledCore

final class FilterPipelineTests: XCTestCase {
    func testNeutralFiltersPreserveSolidColor() {
        let width = 32
        let height = 32
        let bgra = solidBGRA(width: width, height: height, b: 80, g: 160, r: 200)
        let pipeline = FramePipeline(output: OutputResolution(width: 4, height: 4))
        let frame = withBuffer(bgra: bgra, width: width, height: height) { buffer in
            pipeline.process(bgra: buffer, filters: neutralFilters)
        }
        XCTAssertEqual(frame.width, 4)
        XCTAssertEqual(frame.height, 4)
        for i in stride(from: 0, to: frame.pixels.count, by: 3) {
            XCTAssertEqual(Int(frame.pixels[i]), 200, accuracy: 2)
            XCTAssertEqual(Int(frame.pixels[i + 1]), 160, accuracy: 2)
            XCTAssertEqual(Int(frame.pixels[i + 2]), 80, accuracy: 2)
        }
    }

    func testScaleEdgeExtendDoesNotBleed() {
        let width = 16
        let height = 16
        var bgra = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                bgra[i] = 0
                bgra[i + 1] = 0
                bgra[i + 2] = 255
                bgra[i + 3] = 255
            }
        }
        let pipeline = FramePipeline(output: OutputResolution(width: 4, height: 4))
        let frame = withBuffer(bgra: bgra, width: width, height: height) { buffer in
            pipeline.process(bgra: buffer, filters: neutralFilters)
        }
        for i in stride(from: 0, to: frame.pixels.count, by: 3) {
            XCTAssertEqual(Int(frame.pixels[i]), 255, accuracy: 3)
            XCTAssertEqual(Int(frame.pixels[i + 1]), 0, accuracy: 3)
            XCTAssertEqual(Int(frame.pixels[i + 2]), 0, accuracy: 3)
        }
    }

    func testBrightnessScalesLuminance() {
        let bgra = solidBGRA(width: 8, height: 8, b: 100, g: 100, r: 100)
        let pipeline = FramePipeline(output: OutputResolution(width: 2, height: 2))
        var filters = neutralFilters
        filters.brightness = 0.5
        let frame = withBuffer(bgra: bgra, width: 8, height: 8) { buffer in
            pipeline.process(bgra: buffer, filters: filters)
        }
        for v in frame.pixels {
            XCTAssertEqual(Int(v), 50, accuracy: 2)
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

    private func solidBGRA(width: Int, height: Int, b: UInt8, g: UInt8, r: UInt8) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = b
            pixels[i + 1] = g
            pixels[i + 2] = r
            pixels[i + 3] = 255
        }
        return pixels
    }

    private func withBuffer<T>(
        bgra: [UInt8],
        width: Int,
        height: Int,
        _ block: (vImage_Buffer) -> T
    ) -> T {
        var pixels = bgra
        return pixels.withUnsafeMutableBufferPointer { ptr in
            let buffer = vImage_Buffer(
                data: ptr.baseAddress,
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: width * 4
            )
            return block(buffer)
        }
    }
}
