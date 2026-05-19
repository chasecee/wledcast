import AppKit
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

public final class CaptureBoxRef: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CaptureBox

    public init(_ box: CaptureBox) {
        self.value = box
    }

    public var box: CaptureBox {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    public func update(_ box: CaptureBox) {
        lock.lock(); defer { lock.unlock() }
        value = box
    }
}

public final class DisplayFrameSource {
    public struct Diagnostics: Equatable, Sendable {
        public var displayID: UInt32
        public var framePixels: CGSize
        public var sourceRect: CGRect
        public var deliveredFrames: Int
    }

    public var onFrame: ((RGBFrame) -> Void)?
    public var onDiagnostics: ((Diagnostics) -> Void)?

    private let boxRef: CaptureBoxRef
    private let outputResolution: OutputResolution
    private let fps: Int
    private let captureSelection: CaptureSelection
    private let streamOutput = StreamOutput()
    private var stream: SCStream?
    private var streamConfiguration: SCStreamConfiguration?
    private let queue = DispatchQueue(label: "wledcast.capture.output", qos: .userInteractive)
    private var activeDisplayID: CGDirectDisplayID = 0
    private var rgbScratch: [UInt8]
    private var deliveredFrames = 0
    private var lastDiagnosticsAt = Date.distantPast

    public init(
        boxRef: CaptureBoxRef,
        outputResolution: OutputResolution,
        fps: Int,
        captureSelection: CaptureSelection
    ) {
        self.boxRef = boxRef
        self.outputResolution = outputResolution
        self.fps = max(1, fps)
        self.captureSelection = captureSelection
        self.rgbScratch = [UInt8](repeating: 0, count: max(1, outputResolution.width * outputResolution.height * 3))
        streamOutput.onSampleBuffer = { [weak self] sampleBuffer in
            self?.consume(sampleBuffer: sampleBuffer)
        }
        Task { [weak self] in
            try? await self?.startStream()
        }
    }

    public func stop() {
        Task { [stream] in
            try? await stream?.stopCapture()
        }
    }

    public func updateRegion(box: CaptureBox) {
        guard captureSelection.mode == .region else { return }
        guard box.displayID == activeDisplayID else { return }
        guard let stream, let configuration = streamConfiguration else { return }
        configuration.sourceRect = sourceRect(for: box)
        Task {
            try? await stream.updateConfiguration(configuration)
        }
    }

    private func sourceRect(for box: CaptureBox) -> CGRect {
        CGRect(
            x: CGFloat(box.left),
            y: CGFloat(box.top),
            width: CGFloat(max(1, box.width)),
            height: CGFloat(max(1, box.height))
        )
    }

    private func startStream() async throws {
        let content = try await SCShareableContent.current
        let (filter, displayID) = try buildFilter(content: content)

        let configuration = SCStreamConfiguration()
        configuration.width = max(1, outputResolution.width)
        configuration.height = max(1, outputResolution.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.scalesToFit = false
        configuration.showsCursor = false
        configuration.queueDepth = 3
        if captureSelection.mode == .region {
            configuration.sourceRect = sourceRect(for: boxRef.box)
        }

        activeDisplayID = displayID
        Log.capture.notice(
            "stream display=\(displayID) src=\(configuration.sourceRect) out=\(configuration.width)x\(configuration.height) fps=\(fps)"
        )

        let newStream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try newStream.addStreamOutput(streamOutput, type: .screen, sampleHandlerQueue: queue)
        try await newStream.startCapture()
        stream = newStream
        streamConfiguration = configuration
    }

    private func buildFilter(content: SCShareableContent) throws -> (SCContentFilter, CGDirectDisplayID) {
        switch captureSelection.mode {
        case .window:
            guard
                let windowID = captureSelection.windowID,
                let window = content.windows.first(where: { $0.windowID == windowID })
            else {
                throw NSError(domain: "DisplayFrameSource", code: 2)
            }
            let fallbackDisplayID = content.displays.first?.displayID ?? CGMainDisplayID()
            return (SCContentFilter(desktopIndependentWindow: window), fallbackDisplayID)
        case .display, .region:
            let display: SCDisplay?
            if let displayID = captureSelection.displayID {
                display = content.displays.first(where: { $0.displayID == displayID })
            } else {
                let mainID = CGMainDisplayID()
                display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first
            }
            guard let display else {
                throw NSError(domain: "DisplayFrameSource", code: 3)
            }
            return (SCContentFilter(display: display, excludingWindows: []), display.displayID)
        }
    }

    private func consume(sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)

        let rgbCount = width * height * 3
        if rgbScratch.count != rgbCount {
            rgbScratch = [UInt8](repeating: 0, count: rgbCount)
        }
        rgbScratch.withUnsafeMutableBufferPointer { rgbPtr in
            guard let dst = rgbPtr.baseAddress else { return }
            for y in 0..<height {
                let row = buffer.advanced(by: y * stride)
                let outRow = dst.advanced(by: y * width * 3)
                for x in 0..<width {
                    let s = x * 4
                    let d = x * 3
                    outRow[d] = row[s + 2]
                    outRow[d + 1] = row[s + 1]
                    outRow[d + 2] = row[s]
                }
            }
        }

        deliveredFrames += 1
        let frame = RGBFrame(width: width, height: height, pixels: rgbScratch)
        onFrame?(frame)
        emitDiagnosticsIfDue(framePixels: CGSize(width: width, height: height))
    }

    private func emitDiagnosticsIfDue(framePixels: CGSize) {
        let now = Date()
        guard now.timeIntervalSince(lastDiagnosticsAt) > 0.5 else { return }
        lastDiagnosticsAt = now
        let diag = Diagnostics(
            displayID: activeDisplayID,
            framePixels: framePixels,
            sourceRect: streamConfiguration?.sourceRect ?? .zero,
            deliveredFrames: deliveredFrames
        )
        onDiagnostics?(diag)
        Log.capture.notice(
            "tick display=\(diag.displayID) frame=\(Int(framePixels.width))x\(Int(framePixels.height)) src=\(diag.sourceRect) delivered=\(deliveredFrames)"
        )
    }
}

private final class StreamOutput: NSObject, SCStreamOutput {
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen else { return }
        onSampleBuffer?(sampleBuffer)
    }
}
