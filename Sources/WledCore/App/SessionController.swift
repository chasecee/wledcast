import Foundation

public final class SessionController: @unchecked Sendable {
    private let sender: DDPSender
    private let outputResolution: OutputResolution
    private let filterLock = NSLock()
    private var filterConfig: FilterConfig

    public var onFrameProcessed: ((RGBFrame) -> Void)?

    public init(
        sender: DDPSender,
        outputResolution: OutputResolution,
        filterConfig: FilterConfig
    ) {
        self.sender = sender
        self.outputResolution = outputResolution
        self.filterConfig = filterConfig
    }

    public func updateFilters(_ config: FilterConfig) {
        filterLock.lock(); filterConfig = config; filterLock.unlock()
    }

    public func process(frame: RGBFrame) {
        filterLock.lock()
        let cfg = filterConfig
        filterLock.unlock()
        let processed = FramePipeline.process(frame: frame, output: outputResolution, filters: cfg)
        onFrameProcessed?(processed)
        sender.send(frame: processed)
    }

    public func stop() {
        sender.stop()
    }
}
