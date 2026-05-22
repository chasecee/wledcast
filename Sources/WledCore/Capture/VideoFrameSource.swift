import Accelerate
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

public final class VideoFrameSource: @unchecked Sendable {
    public var onFrameBGRA: ((vImage_Buffer) -> Void)?
    public var onPreviewBuffer: ((CVPixelBuffer) -> Void)?

    public private(set) var videoSize: CGSize = .zero

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "wledcast.video.source", qos: .userInteractive)
    private let queueKey = DispatchSpecificKey<Void>()
    private var timer: DispatchSourceTimer?
    private var outputFps: Int
    private var crop: VideoCropBox
    private let loop: Bool
    private var loopRange: LoopRange
    private let asset: AVAsset
    private var assetDuration: CMTime = .zero
    private var track: AVAssetTrack?
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?

    public init(url: URL, fps: Int, crop: VideoCropBox, loop: Bool, loopRange: LoopRange = .full) throws {
        self.asset = AVAsset(url: url)
        self.outputFps = max(1, fps)
        self.crop = crop
        self.loop = loop
        self.loopRange = loopRange.clamped()
        queue.setSpecific(key: queueKey, value: ())
        try setupTrack()
        try startReader()
        scheduleTimer()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            teardownReader()
        } else {
            queue.sync { self.teardownReader() }
        }
    }

    private func teardownReader() {
        lock.lock()
        reader?.cancelReading()
        reader = nil
        output = nil
        lock.unlock()
    }

    public func setOutputFps(_ fps: Int) {
        outputFps = max(1, fps)
        scheduleTimer()
    }

    public func updateCrop(_ crop: VideoCropBox) {
        lock.lock()
        self.crop = crop
        lock.unlock()
    }

    public func updateLoopRange(_ range: LoopRange) {
        let next = range.clamped()
        let apply: () -> Void = { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let changed = self.loopRange != next
            self.loopRange = next
            self.lock.unlock()
            guard changed else { return }
            do {
                try self.startReader()
            } catch {
                Log.capture.error("video reader loop range restart failed: \(error.localizedDescription)")
            }
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            apply()
        } else {
            queue.async(execute: apply)
        }
    }

    private func setupTrack() throws {
        let semaphore = DispatchSemaphore(value: 0)
        var loadedTrack: AVAssetTrack?
        var loadedSize: CGSize?
        var loadedDuration: CMTime?
        var loadError: Error?
        Task {
            do {
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard let first = tracks.first else {
                    throw NSError(domain: "VideoFrameSource", code: 2)
                }
                let size = try await first.load(.naturalSize)
                let transform = try await first.load(.preferredTransform)
                let duration = try await asset.load(.duration)
                loadedTrack = first
                loadedSize = size.applying(transform).absSize
                loadedDuration = duration
            } catch {
                loadError = error
            }
            semaphore.signal()
        }
        semaphore.wait()
        if let loadError {
            throw loadError
        }
        guard let loadedTrack, let loadedSize else {
            throw NSError(domain: "VideoFrameSource", code: 1)
        }
        self.track = loadedTrack
        self.videoSize = loadedSize
        self.assetDuration = loadedDuration ?? .zero
        if videoSize.width <= 0 || videoSize.height <= 0 {
            throw NSError(domain: "VideoFrameSource", code: 3)
        }
    }

    private func startReader() throws {
        guard let track else {
            throw NSError(domain: "VideoFrameSource", code: 4)
        }
        lock.lock()
        let activeRange = loopRange
        lock.unlock()
        let reader = try AVAssetReader(asset: asset)
        let totalSec = CMTimeGetSeconds(assetDuration)
        if totalSec.isFinite, totalSec > 0 {
            let timescale = assetDuration.timescale > 0 ? assetDuration.timescale : 600
            let startTime = CMTime(seconds: totalSec * activeRange.start, preferredTimescale: timescale)
            let span = CMTime(seconds: max(0.001, totalSec * (activeRange.end - activeRange.start)), preferredTimescale: timescale)
            reader.timeRange = CMTimeRange(start: startTime, duration: span)
        }
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw NSError(domain: "VideoFrameSource", code: 5)
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? NSError(domain: "VideoFrameSource", code: 6)
        }
        lock.lock()
        self.reader?.cancelReading()
        self.reader = reader
        self.output = output
        lock.unlock()
    }

    private func restartReaderIfNeeded() -> Bool {
        guard loop else { return false }
        do {
            try startReader()
            return true
        } catch {
            Log.capture.error("video reader restart failed: \(error.localizedDescription)")
            return false
        }
    }

    private func scheduleTimer() {
        timer?.cancel()
        let intervalNs = max(1, Int(1_000_000_000 / Double(outputFps)))
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: .nanoseconds(intervalNs), leeway: .nanoseconds(intervalNs / 10))
        source.setEventHandler { [weak self] in
            self?.tick()
        }
        timer = source
        source.resume()
    }

    private func tick() {
        guard let sampleBuffer = nextSampleBuffer() else {
            stop()
            return
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onPreviewBuffer?(pixelBuffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let crop = normalizedCrop(forWidth: width, height: height)
        let cropped = baseAddress.advanced(by: crop.y * bytesPerRow + crop.x * 4)
        let buffer = vImage_Buffer(
            data: cropped,
            height: vImagePixelCount(crop.height),
            width: vImagePixelCount(crop.width),
            rowBytes: bytesPerRow
        )
        onFrameBGRA?(buffer)
    }

    private func nextSampleBuffer() -> CMSampleBuffer? {
        lock.lock()
        let output = self.output
        lock.unlock()
        if let sample = output?.copyNextSampleBuffer() {
            return sample
        }
        guard restartReaderIfNeeded() else {
            return nil
        }
        lock.lock()
        let restartedOutput = self.output
        lock.unlock()
        return restartedOutput?.copyNextSampleBuffer()
    }

    private func normalizedCrop(forWidth width: Int, height: Int) -> (x: Int, y: Int, width: Int, height: Int) {
        lock.lock()
        let crop = self.crop
        lock.unlock()

        let x = max(0, min(1, crop.x))
        let y = max(0, min(1, crop.y))
        let w = max(0.01, min(1, crop.width))
        let h = max(0.01, min(1, crop.height))

        let left = min(width - 1, max(0, Int((Double(width) * x).rounded(.down))))
        let top = min(height - 1, max(0, Int((Double(height) * y).rounded(.down))))
        let cropWidth = max(1, min(width - left, Int((Double(width) * w).rounded(.down))))
        let cropHeight = max(1, min(height - top, Int((Double(height) * h).rounded(.down))))
        return (left, top, cropWidth, cropHeight)
    }
}

private extension CGSize {
    var absSize: CGSize {
        CGSize(width: abs(width), height: abs(height))
    }
}
