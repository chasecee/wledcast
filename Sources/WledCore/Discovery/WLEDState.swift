import Foundation

public enum WLEDStateParser {
    public struct Segment: Decodable, Sendable {
        public let on: Bool?
        public let start: Int?
        public let stop: Int?
        public let startY: Int?
        public let stopY: Int?
    }

    public struct Response: Decodable, Sendable {
        public let seg: [Segment]?
    }

    public static func outputResolution(from data: Data) throws -> OutputResolution {
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard let segments = response.seg, !segments.isEmpty else {
            throw NSError(domain: "WLEDStateParser", code: 1)
        }

        let candidates = segments.filter { $0.start != nil && $0.stop != nil }
        guard !candidates.isEmpty else {
            throw NSError(domain: "WLEDStateParser", code: 2)
        }

        let minStart = candidates.compactMap(\.start).min() ?? 0
        let maxStop = candidates.compactMap(\.stop).max() ?? 0
        let width = max(1, maxStop - minStart)

        let yCandidates = candidates.filter { $0.startY != nil && $0.stopY != nil }
        let height: Int
        if !yCandidates.isEmpty {
            let minStartY = yCandidates.compactMap(\.startY).min() ?? 0
            let maxStopY = yCandidates.compactMap(\.stopY).max() ?? 0
            height = max(1, maxStopY - minStartY)
        } else {
            height = 1
        }

        return OutputResolution(width: width, height: height)
    }
}
