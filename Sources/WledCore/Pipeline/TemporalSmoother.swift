import Foundation

public final class TemporalSmoother: @unchecked Sendable {
    private let lock = NSLock()
    private var previous: [UInt8] = []

    public init() {}

    public func apply(frame: RGBFrame, strength: Float) -> RGBFrame {
        var pixels = frame.pixels
        apply(pixels: &pixels, width: frame.width, height: frame.height, strength: strength)
        return RGBFrame(width: frame.width, height: frame.height, pixels: pixels)
    }

    public func apply(pixels: inout [UInt8], width: Int, height: Int, strength: Float) {
        let clamped = max(0, min(1, strength))
        if clamped <= 0 { return }

        let deadband = Int((clamped * clamped) * 24)
        let alpha = 1 - clamped

        lock.lock()
        defer { lock.unlock() }
        if previous.count != pixels.count {
            previous = pixels
            return
        }

        for i in 0..<pixels.count {
            let prev = Int(previous[i])
            let delta = Int(pixels[i]) - prev
            if delta >= -deadband, delta <= deadband {
                pixels[i] = UInt8(prev)
                continue
            }
            let blended = Float(prev) + Float(delta) * alpha
            if blended <= 0 {
                pixels[i] = 0
            } else if blended >= 255 {
                pixels[i] = 255
            } else {
                pixels[i] = UInt8(blended.rounded())
            }
        }
        previous = pixels
    }
}
