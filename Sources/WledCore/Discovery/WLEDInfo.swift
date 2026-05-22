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
        public let fps: Int?
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

    public static func measuredFps(from data: Data) -> Int? {
        if let response = try? JSONDecoder().decode(Response.self, from: data),
           let fps = response.leds?.fps, fps > 0 {
            return fps
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let leds = json["leds"] as? [String: Any],
              let raw = leds["fps"] else {
            return nil
        }
        return parseFpsValue(raw)
    }
}

public enum WLEDCfgParser {
    public static func parseTargetFps(from data: Data) -> Int? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hw = json["hw"] as? [String: Any],
              let led = hw["led"] as? [String: Any],
              led.keys.contains("fps") else {
            return nil
        }
        return parseFpsValue(led["fps"])
    }

    public static func resolveTargetFps(infoData: Data, cfgData: Data?) -> Int {
        if let cfgData, let target = parseTargetFps(from: cfgData) {
            return target
        }
        return WLEDHost.defaultFps
    }
}

private func parseFpsValue(_ raw: Any?) -> Int? {
    switch raw {
    case let value as Int:
        return value
    case let value as Double:
        return Int(value.rounded())
    case let value as NSNumber:
        return value.intValue
    case let value as String:
        return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
    default:
        return nil
    }
}
