import AppKit
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

public protocol FrameSource {
    func capture() throws -> RGBFrame
    func stop()
}

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

private final class LatestFrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: RGBFrame?

    func write(_ frame: RGBFrame) {
        lock.lock()
        self.frame = frame
        lock.unlock()
    }

    func read() -> RGBFrame? {
        lock.lock()
        let value = frame
        lock.unlock()
        return value
    }
}

public final class DisplayFrameSource: FrameSource {
    private let boxRef: CaptureBoxRef
    private let outputResolution: OutputResolution
    private let fps: Int
    private let captureSelection: CaptureSelection
    private let store = LatestFrameStore()
    private let streamOutput = StreamOutput()
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "wledcast.capture.output")
    private var activeDisplayBounds = CGRect.zero

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
        streamOutput.onSampleBuffer = { [weak self] sampleBuffer in
            self?.consume(sampleBuffer: sampleBuffer)
        }
        Task { [weak self] in
            try? await self?.startStream()
        }
    }

    public func capture() throws -> RGBFrame {
        guard let frame = store.read() else {
            throw NSError(domain: "DisplayFrameSource", code: 1)
        }
        return frame
    }

    public func stop() {
        Task { [stream] in
            try? await stream?.stopCapture()
        }
    }

    private func startStream() async throws {
        let content = try await SCShareableContent.current
        let (filter, displayID) = try buildFilter(content: content)

        let configuration = SCStreamConfiguration()
        if captureSelection.mode == .region {
            let fullWidth = max(1, Int(CGDisplayPixelsWide(displayID)))
            let fullHeight = max(1, Int(CGDisplayPixelsHigh(displayID)))
            configuration.width = fullWidth
            configuration.height = fullHeight
        } else {
            configuration.width = outputResolution.width
            configuration.height = outputResolution.height
        }
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        activeDisplayBounds = CGDisplayBounds(displayID)

        let newStream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try newStream.addStreamOutput(streamOutput, type: .screen, sampleHandlerQueue: queue)
        try await newStream.startCapture()
        stream = newStream
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
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)

        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            let row = buffer + (y * bytesPerRow)
            for x in 0..<width {
                let source = row + (x * 4)
                let target = (y * width + x) * 3
                rgb[target] = source[2]
                rgb[target + 1] = source[1]
                rgb[target + 2] = source[0]
            }
        }
        var frame = RGBFrame(width: width, height: height, pixels: rgb)
        if captureSelection.mode == .region {
            frame = cropRegion(frame: frame, box: boxRef.box)
        }
        store.write(frame)
    }

    private func cropRegion(frame: RGBFrame, box: CaptureBox) -> RGBFrame {
        let bounds = activeDisplayBounds
        guard bounds.width > 0, bounds.height > 0 else {
            return frame
        }

        let scaleX = Double(frame.width) / Double(bounds.width)
        let scaleY = Double(frame.height) / Double(bounds.height)

        let x0 = Int((Double(box.left) - bounds.minX) * scaleX)
        let y0FromBottom = Int((Double(box.top) - bounds.minY) * scaleY)
        let width = max(1, Int(Double(box.width) * scaleX))
        let height = max(1, Int(Double(box.height) * scaleY))

        let x = max(0, min(frame.width - 1, x0))
        var y = frame.height - y0FromBottom - height
        y = max(0, min(frame.height - 1, y))

        var cropWidth = min(width, frame.width - x)
        var cropHeight = min(height, frame.height - y)
        cropWidth = max(1, cropWidth)
        cropHeight = max(1, cropHeight)

        var cropped = [UInt8](repeating: 0, count: cropWidth * cropHeight * 3)
        for row in 0..<cropHeight {
            let sourceStart = ((y + row) * frame.width + x) * 3
            let sourceEnd = sourceStart + (cropWidth * 3)
            let targetStart = row * cropWidth * 3
            cropped.replaceSubrange(targetStart..<(targetStart + (cropWidth * 3)), with: frame.pixels[sourceStart..<sourceEnd])
        }

        let out = RGBFrame(width: cropWidth, height: cropHeight, pixels: cropped)
        if out.width == outputResolution.width, out.height == outputResolution.height {
            return out
        }
        return resizeNearest(frame: out, targetWidth: outputResolution.width, targetHeight: outputResolution.height)
    }

    private func resizeNearest(frame: RGBFrame, targetWidth: Int, targetHeight: Int) -> RGBFrame {
        if frame.width == targetWidth, frame.height == targetHeight {
            return frame
        }
        var targetPixels = [UInt8](repeating: 0, count: targetWidth * targetHeight * 3)
        for y in 0..<targetHeight {
            let sourceY = min(frame.height - 1, y * frame.height / targetHeight)
            for x in 0..<targetWidth {
                let sourceX = min(frame.width - 1, x * frame.width / targetWidth)
                let sourceIndex = (sourceY * frame.width + sourceX) * 3
                let targetIndex = (y * targetWidth + x) * 3
                targetPixels[targetIndex] = frame.pixels[sourceIndex]
                targetPixels[targetIndex + 1] = frame.pixels[sourceIndex + 1]
                targetPixels[targetIndex + 2] = frame.pixels[sourceIndex + 2]
            }
        }
        return RGBFrame(width: targetWidth, height: targetHeight, pixels: targetPixels)
    }
}

private final class StreamOutput: NSObject, SCStreamOutput {
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen else { return }
        onSampleBuffer?(sampleBuffer)
    }
}

public struct SyntheticFrameSource: FrameSource {
    private let frame: RGBFrame

    public init(frame: RGBFrame) {
        self.frame = frame
    }

    public func capture() throws -> RGBFrame {
        frame
    }

    public func stop() {}
}
