import Foundation
import XCTest
@testable import WledCore

final class WLEDInfoParserTests: XCTestCase {
    func testMatrixResolutionMatchesFixtures() throws {
        let fixture = try FixtureLoader.loadJSON(name: "wled_info_fixtures")
        for key in ["matrix_2d", "matrix_wide"] {
            let testCase = fixture[key] as! [String: Any]
            let input = testCase["input"] as! [String: Any]
            let expected = testCase["expected"] as! [String: Any]
            let data = try JSONSerialization.data(withJSONObject: input)
            let parsed = try WLEDInfoParser.matrixResolution(from: data)
            XCTAssertEqual(parsed.width, expected["width"] as! Int)
            XCTAssertEqual(parsed.height, expected["height"] as! Int)
        }
    }

    func testStripWithoutMatrixIsRejected() throws {
        let payload: [String: Any] = [
            "ver": "0.14.4",
            "leds": [
                "count": 150
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        XCTAssertThrowsError(try WLEDInfoParser.matrixResolution(from: data)) { error in
            guard case WLEDInfoError.notAMatrix = error else {
                XCTFail("expected .notAMatrix, got \(error)")
                return
            }
        }
    }

    func testZeroDimensionsRejected() throws {
        let payload: [String: Any] = [
            "leds": [
                "matrix": ["w": 0, "h": 16]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        XCTAssertThrowsError(try WLEDInfoParser.matrixResolution(from: data))
    }
}
