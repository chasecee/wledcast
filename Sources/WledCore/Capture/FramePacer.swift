import Foundation

public final class FramePacer: @unchecked Sendable {
    public var onTick: ((RGBFrame) -> Void)?

    private let queue = DispatchQueue(label: "wledcast.pacer", qos: .userInteractive)
    private let lock = NSLock()
    private var latestFrame: RGBFrame?
    private var timer: DispatchSourceTimer?

    public init() {}

    public func ingest(_ frame: RGBFrame) {
        lock.lock()
        latestFrame = frame
        lock.unlock()
    }

    public func start(fps: Int) {
        stop()
        let clamped = max(1, fps)
        let intervalNs = max(1, Int(1_000_000_000 / Double(clamped)))
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(
            deadline: .now() + .nanoseconds(intervalNs),
            repeating: .nanoseconds(intervalNs),
            leeway: .nanoseconds(intervalNs / 10)
        )
        source.setEventHandler { [weak self] in
            self?.tick()
        }
        timer = source
        source.resume()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        lock.lock()
        latestFrame = nil
        lock.unlock()
    }

    private func tick() {
        lock.lock()
        let frame = latestFrame
        lock.unlock()
        guard let frame else { return }
        onTick?(frame)
    }
}
