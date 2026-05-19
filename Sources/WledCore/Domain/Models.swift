import Foundation

public struct CaptureBox: Codable, Equatable, Sendable {
    public var left: Int
    public var top: Int
    public var width: Int
    public var height: Int

    public init(left: Int, top: Int, width: Int, height: Int) {
        self.left = left
        self.top = top
        self.width = width
        self.height = height
    }
}

public struct OutputResolution: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct FilterConfig: Codable, Equatable, Sendable {
    public var sharpen: Float
    public var saturation: Float
    public var brightness: Float
    public var contrast: Float
    public var balanceR: Float
    public var balanceG: Float
    public var balanceB: Float

    public init(
        sharpen: Float,
        saturation: Float,
        brightness: Float,
        contrast: Float,
        balanceR: Float,
        balanceG: Float,
        balanceB: Float
    ) {
        self.sharpen = sharpen
        self.saturation = saturation
        self.brightness = brightness
        self.contrast = contrast
        self.balanceR = balanceR
        self.balanceG = balanceG
        self.balanceB = balanceB
    }

    public static let `default` = FilterConfig(
        sharpen: 0.1,
        saturation: 1.0,
        brightness: 0.3,
        contrast: 1.0,
        balanceR: 1.0,
        balanceG: 0.7,
        balanceB: 0.45
    )
}

public struct AppOptions: Equatable, Sendable {
    public var host: String?
    public var title: String?
    public var monitor: Int?
    public var outputResolution: OutputResolution?
    public var fps: Int
    public var searchTimeout: TimeInterval
    public var livePreview: Bool

    public init(
        host: String? = nil,
        title: String? = nil,
        monitor: Int? = nil,
        outputResolution: OutputResolution? = nil,
        fps: Int = 30,
        searchTimeout: TimeInterval = 3,
        livePreview: Bool = false
    ) {
        self.host = host
        self.title = title
        self.monitor = monitor
        self.outputResolution = outputResolution
        self.fps = fps
        self.searchTimeout = searchTimeout
        self.livePreview = livePreview
    }
}

public enum CaptureMode: String, Codable, CaseIterable, Sendable {
    case region
    case display
    case window
}

public struct CaptureSelection: Codable, Equatable, Sendable {
    public var mode: CaptureMode
    public var displayID: UInt32?
    public var windowID: UInt32?

    public init(mode: CaptureMode = .region, displayID: UInt32? = nil, windowID: UInt32? = nil) {
        self.mode = mode
        self.displayID = displayID
        self.windowID = windowID
    }
}

public struct WLEDHost: Codable, Equatable, Sendable, Identifiable {
    public let host: String
    public let resolution: OutputResolution

    public var id: String { host }

    public init(host: String, resolution: OutputResolution) {
        self.host = host
        self.resolution = resolution
    }
}
