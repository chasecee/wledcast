import Foundation

enum FixtureLoader {
    static func loadJSON(name: String, file: StaticString = #filePath) throws -> [String: Any] {
        let testFileURL = URL(fileURLWithPath: "\(file)")
        let directory = testFileURL.deletingLastPathComponent()
        let fixtureURL = directory.appendingPathComponent("Fixtures").appendingPathComponent("\(name).json")
        let data = try Data(contentsOf: fixtureURL)
        let object = try JSONSerialization.jsonObject(with: data)
        return object as! [String: Any]
    }
}
