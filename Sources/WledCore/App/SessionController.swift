import Foundation

public final class SessionController {
    private let frameSource: FrameSource
    private let sender: DDPSender
    private let outputResolution: OutputResolution
    private var filterConfig: FilterConfig
    private let fps: Int
    private var running = false
    public var onFrameProcessed: ((RGBFrame) -> Void)?

    public init(
        frameSource: FrameSource,
        sender: DDPSender,
        outputResolution: OutputResolution,
        filterConfig: FilterConfig,
        fps: Int
    ) {
        self.frameSource = frameSource
        self.sender = sender
        self.outputResolution = outputResolution
        self.filterConfig = filterConfig
        self.fps = max(1, fps)
    }

    public func updateFilters(_ config: FilterConfig) {
        filterConfig = config
    }

    public func start() async {
        running = true
        let period = UInt64(1_000_000_000 / fps)
        while running, !Task.isCancelled {
            let start = DispatchTime.now().uptimeNanoseconds
            if let frame = try? frameSource.capture() {
                let processed = FramePipeline.process(
                    frame: frame,
                    output: outputResolution,
                    filters: filterConfig
                )
                onFrameProcessed?(processed)
                sender.send(frame: processed)
            }
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            if elapsed < period {
                try? await Task.sleep(nanoseconds: period - elapsed)
            }
        }
    }

    public func stop() {
        running = false
        frameSource.stop()
        sender.stop()
    }
}
