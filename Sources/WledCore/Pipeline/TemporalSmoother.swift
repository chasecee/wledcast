import Foundation

public final class TemporalSmoother: @unchecked Sendable {
    private let lock = NSLock()
    private var previous: [UInt8] = []

    public init() {}

    public func apply(frame: RGBFrame, strength: Float) -> RGBFrame {
        let clamped = max(0, min(1, strength))
        if clamped <= 0 {
            lock.lock(); previous = frame.pixels; lock.unlock()
            return frame
        }

        let deadband = Int((clamped * clamped) * 24)
        let alpha = 1 - clamped

        lock.lock(); defer { lock.unlock() }
        if previous.count != frame.pixels.count {
            previous = frame.pixels
            return frame
        }

        var out = previous
        out.withUnsafeMutableBufferPointer { outPtr in
            previous.withUnsafeBufferPointer { prevPtr in
                frame.pixels.withUnsafeBufferPointer { curPtr in
                    let n = outPtr.count
                    for i in 0..<n {
                        let prev = Int(prevPtr[i])
                        let delta = Int(curPtr[i]) - prev
                        if delta >= -deadband, delta <= deadband {
                            outPtr[i] = UInt8(prev)
                            continue
                        }
                        let blended = Float(prev) + Float(delta) * alpha
                        if blended <= 0 {
                            outPtr[i] = 0
                        } else if blended >= 255 {
                            outPtr[i] = 255
                        } else {
                            outPtr[i] = UInt8(blended.rounded())
                        }
                    }
                }
            }
        }
        previous = out
        return RGBFrame(width: frame.width, height: frame.height, pixels: out)
    }
}
