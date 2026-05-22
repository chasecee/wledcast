import Accelerate
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

    public var onFrameBGRA: ((vImage_Buffer) -> Void)?
    public var onDiagnostics: ((Diagnostics) -> Void)?

    private let boxRef: CaptureBoxRef
    private let outputResolution: OutputResolution
    private let fps: Int
    private let captureSelection: CaptureSelection
    private let excludedWindowIDs: [CGWindowID]
    private let streamOutput = StreamOutput()
    private var stream: SCStream?
    private var streamConfiguration: SCStreamConfiguration?
    private let queue = DispatchQueue(label: "wledcast.capture.output", qos: .userInitiated)
    private var activeDisplayID: CGDirectDisplayID = 0
    private var activeSourcePixels: (width: Int, height: Int) = (1, 1)
    private var deliveredFrames = 0
    private var lastDeliveredFrames = 0
    private var lastDiagnosticsAt = Date.distantPast

    public init(
        boxRef: CaptureBoxRef,
        outputResolution: OutputResolution,
        fps: Int,
        captureSelection: CaptureSelection,
        excludedWindowIDs: [CGWindowID] = []
    ) {
        self.boxRef = boxRef
        self.outputResolution = outputResolution
        self.fps = max(1, fps)
        self.captureSelection = captureSelection
        self.excludedWindowIDs = excludedWindowIDs
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
        let scale = backingScale(for: activeDisplayID)
        let sourcePixels = (
            width: max(1, Int((CGFloat(max(1, box.width)) * scale).rounded())),
            height: max(1, Int((CGFloat(max(1, box.height)) * scale).rounded()))
        )
        activeSourcePixels = sourcePixels
        configuration.sourceRect = sourceRect(for: box)
        let target = captureSize(sourcePixels: sourcePixels)
        configuration.width = target.width
        configuration.height = target.height
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
        let scale = backingScale(for: displayID)
        let box = boxRef.box
        let sourcePixels = (
            width: max(1, Int((CGFloat(max(1, box.width)) * scale).rounded())),
            height: max(1, Int((CGFloat(max(1, box.height)) * scale).rounded()))
        )
        activeSourcePixels = sourcePixels
        let target = captureSize(sourcePixels: sourcePixels)

        let configuration = SCStreamConfiguration()
        configuration.width = target.width
        configuration.height = target.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.scalesToFit = false
        configuration.showsCursor = false
        configuration.queueDepth = 3
        configuration.sourceRect = sourceRect(for: box)

        activeDisplayID = displayID
        Log.capture.notice(
            "stream display=\(displayID) src=\(configuration.sourceRect) sourcePx=\(sourcePixels.width)x\(sourcePixels.height) out=\(target.width)x\(target.height) target=\(outputResolution.width)x\(outputResolution.height) fps=\(fps)"
        )

        let newStream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try newStream.addStreamOutput(streamOutput, type: .screen, sampleHandlerQueue: queue)
        try await newStream.startCapture()
        stream = newStream
        streamConfiguration = configuration
    }

    private func buildFilter(content: SCShareableContent) throws -> (SCContentFilter, CGDirectDisplayID) {
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
        let excluded = content.windows.filter { excludedWindowIDs.contains($0.windowID) }
        return (SCContentFilter(display: display, excludingWindows: excluded), display.displayID)
    }

    private func captureSize(sourcePixels: (width: Int, height: Int)) -> (width: Int, height: Int) {
        let oversample = pickOversample(sourcePixels: sourcePixels)
        let width = max(outputResolution.width, outputResolution.width * oversample)
        let height = max(outputResolution.height, outputResolution.height * oversample)
        return (
            width: min(sourcePixels.width, width),
            height: min(sourcePixels.height, height)
        )
    }

    private func pickOversample(sourcePixels: (width: Int, height: Int)) -> Int {
        let xCap = sourcePixels.width / max(1, outputResolution.width)
        let yCap = sourcePixels.height / max(1, outputResolution.height)
        let cap = max(1, min(xCap, yCap))
        return min(3, cap)
    }

    private func backingScale(for displayID: CGDirectDisplayID) -> CGFloat {
        NSScreen.screen(for: displayID)?.backingScaleFactor ?? 2.0
    }

    private func consume(sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        let buffer = vImage_Buffer(
            data: baseAddress,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: bytesPerRow
        )
        onFrameBGRA?(buffer)
        deliveredFrames += 1
        emitDiagnosticsIfDue(framePixels: CGSize(width: width, height: height))
    }

    private func emitDiagnosticsIfDue(framePixels: CGSize) {
        let now = Date()
        guard now.timeIntervalSince(lastDiagnosticsAt) > 0.5 else { return }
        let elapsed = now.timeIntervalSince(lastDiagnosticsAt)
        let deltaFrames = deliveredFrames - lastDeliveredFrames
        lastDeliveredFrames = deliveredFrames
        lastDiagnosticsAt = now
        let sourceRect = streamConfiguration?.sourceRect ?? .zero
        let streamFps = elapsed > 0 ? Double(deltaFrames) / elapsed : 0
        PerfLog.noteCapture(
            frameWidth: Int(framePixels.width),
            frameHeight: Int(framePixels.height),
            sourceRect: sourceRect,
            output: outputResolution,
            streamFps: streamFps
        )
        let diag = Diagnostics(
            displayID: activeDisplayID,
            framePixels: framePixels,
            sourceRect: sourceRect,
            deliveredFrames: deliveredFrames
        )
        onDiagnostics?(diag)
        Log.capture.notice(
            "tick display=\(diag.displayID) frame=\(Int(framePixels.width))x\(Int(framePixels.height)) src=\(sourceRect) delivered=\(deliveredFrames) fps=\(String(format: "%.1f", streamFps))"
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
