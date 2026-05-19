import Foundation

public enum WLEDInfoError: Error {
    case notAMatrix
}

public enum WLEDInfoParser {
    public struct Matrix: Decodable, Sendable {
        public let w: Int
        public let h: Int
    }

    public struct LEDs: Decodable, Sendable {
        public let matrix: Matrix?
    }

    public struct Response: Decodable, Sendable {
        public let leds: LEDs?
    }

    public static func matrixResolution(from data: Data) throws -> OutputResolution {
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard let matrix = response.leds?.matrix, matrix.w > 0, matrix.h > 0 else {
            throw WLEDInfoError.notAMatrix
        }
        return OutputResolution(width: matrix.w, height: matrix.h)
    }
}
