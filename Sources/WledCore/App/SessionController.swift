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
    private var workPixels: [UInt8] = []

    public var onFrameProcessed: (([UInt8], Int, Int) -> Void)?
    public var shouldProcessPreview: (() -> Bool)?

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
        let preview = shouldProcessPreview?() == true
        let t0 = CFAbsoluteTimeGetCurrent()
        pipeline.process(bgra: bgra, filters: cfg, rgbOut: &workPixels)
        temporalSmoother.apply(
            pixels: &workPixels,
            width: outputResolution.width,
            height: outputResolution.height,
            strength: flicker
        )
        let processMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        PerfLog.recordFrame(
            sourceWidth: Int(bgra.width),
            sourceHeight: Int(bgra.height),
            processMs: processMs,
            preview: preview
        )
        if preview, let onFrameProcessed {
            onFrameProcessed(
                workPixels,
                outputResolution.width,
                outputResolution.height
            )
        }
        sender.send(pixels: workPixels)
    }

    public func blackout() {
        sender.sendBlackout(pixelCount: outputResolution.width * outputResolution.height)
    }

    public func stop() {
        sender.stop()
    }
}
