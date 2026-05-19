import Foundation

public final class TemporalSmoother: @unchecked Sendable {
    private let lock = NSLock()
    private var previousPixels: [UInt8] = []

    public init() {}

    public func apply(frame: RGBFrame, strength: Float) -> RGBFrame {
        let clampedStrength = max(0, min(1, strength))
        if clampedStrength <= 0 {
            lock.lock()
            previousPixels = frame.pixels
            lock.unlock()
            return frame
        }

        let deadband = Int((clampedStrength * clampedStrength) * 24)
        let alpha = max(0, min(1, 1 - clampedStrength))

        lock.lock()
        defer { lock.unlock() }

        if previousPixels.count != frame.pixels.count {
            previousPixels = frame.pixels
            return frame
        }

        var out = previousPixels
        for i in 0..<out.count {
            let prev = Int(previousPixels[i])
            let current = Int(frame.pixels[i])
            let delta = current - prev
            if abs(delta) <= deadband {
                out[i] = UInt8(prev)
                continue
            }
            let blended = Float(prev) + (Float(delta) * alpha)
            out[i] = UInt8(max(0, min(255, Int(blended.rounded()))))
        }

        previousPixels = out
        return RGBFrame(width: frame.width, height: frame.height, pixels: out)
    }
}
