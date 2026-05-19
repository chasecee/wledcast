import Foundation
import XCTest
@testable import WledCore

final class WLEDStateParserTests: XCTestCase {
    func testWLEDStateParserMatchesFixtures() throws {
        let fixture = try FixtureLoader.loadJSON(name: "wled_state_fixtures")
        for key in ["matrix_2d", "matrix_1d", "matrix_multi_segment_bounds"] {
            let testCase = fixture[key] as! [String: Any]
            let input = testCase["input"] as! [String: Any]
            let expected = testCase["expected"] as! [String: Any]
            let data = try JSONSerialization.data(withJSONObject: input)
            let parsed = try WLEDStateParser.outputResolution(from: data)
            XCTAssertEqual(parsed.width, expected["width"] as! Int)
            XCTAssertEqual(parsed.height, expected["height"] as! Int)
        }
    }
}
