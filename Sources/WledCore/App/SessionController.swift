import Accelerate
import Foundation

public final class SessionController: @unchecked Sendable {
    private let sender: DDPSender
    private let outputResolution: OutputResolution
    private let pipeline: FramePipeline
    private let temporalSmoother = TemporalSmoother()
    private let filterLock = NSLock()
    private var filterConfig: FilterConfig
    private var flickerFighter: Float

    public var onFrameProcessed: ((RGBFrame) -> Void)?

    public init(
        sender: DDPSender,
        outputResolution: OutputResolution,
        filterConfig: FilterConfig,
        flickerFighter: Float
    ) {
        self.sender = sender
        self.outputResolution = outputResolution
        self.pipeline = FramePipeline(output: outputResolution)
        self.filterConfig = filterConfig
        self.flickerFighter = max(0, min(1, flickerFighter))
    }

    public func updateFilters(_ config: FilterConfig) {
        filterLock.lock(); filterConfig = config; filterLock.unlock()
    }

    public func updateFlickerFighter(_ value: Float) {
        filterLock.lock(); flickerFighter = max(0, min(1, value)); filterLock.unlock()
    }

    public func process(bgra: vImage_Buffer) {
        filterLock.lock()
        let cfg = filterConfig
        let flicker = flickerFighter
        filterLock.unlock()
        let processed = pipeline.process(bgra: bgra, filters: cfg)
        let smoothed = temporalSmoother.apply(frame: processed, strength: flicker)
        onFrameProcessed?(smoothed)
        sender.send(frame: smoothed)
    }

    public func blackout() {
        sender.sendBlackout(pixelCount: outputResolution.width * outputResolution.height)
    }

    public func stop() {
        sender.stop()
    }
}
