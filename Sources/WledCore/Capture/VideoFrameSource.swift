import Accelerate
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

public final class VideoFrameSource: @unchecked Sendable {
    public var onFrameBGRA: ((vImage_Buffer) -> Void)?
    public var onPreviewBuffer: ((CVPixelBuffer) -> Void)?

    public private(set) var videoSize: CGSize = .zero
    public private(set) var sourceFps: Float = 30

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "wledcast.video.source", qos: .userInteractive)
    private let queueKey = DispatchSpecificKey<Void>()
    private var timer: DispatchSourceTimer?
    private var outputFps: Int
    private var playbackRate: Float = 1
    private var crop: VideoCropBox
    private let loop: Bool
    private var loopRange: LoopRange
    private let asset: AVAsset
    private let decodeTarget: OutputResolution?
    private let playbackClock: (() -> CMTime)?
    private var assetDuration: CMTime = .zero
    private var track: AVAssetTrack?
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var decodeSize: CGSize = .zero
    private var heldSample: CMSampleBuffer?
    private var pendingSample: CMSampleBuffer?
    private var wallClockStart: CFAbsoluteTime?
    private var rangeStartSeconds: Double = 0
    private var mutedPlayback = false
    private var wallClockAnchor: (media: CMTime, wall: CFAbsoluteTime)?

    public init(
        url: URL,
        fps: Int,
        crop: VideoCropBox,
        loop: Bool,
        loopRange: LoopRange = .full,
        decodeTarget: OutputResolution? = nil,
        playbackClock: (() -> CMTime)? = nil
    ) throws {
        self.asset = AVAsset(url: url)
        self.outputFps = max(1, fps)
        self.crop = crop
        self.loop = loop
        self.loopRange = loopRange.clamped()
        self.decodeTarget = decodeTarget
        self.playbackClock = playbackClock
        queue.setSpecific(key: queueKey, value: ())
        try setupTrack()
        try startReader()
        scheduleTimer()
    }

    public static func loadSourceFps(url: URL) -> Float {
        let asset = AVAsset(url: url)
        let semaphore = DispatchSemaphore(value: 0)
        var fps: Float = 30
        Task {
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let rate = try? await track.load(.nominalFrameRate), rate > 1 {
                fps = rate
            }
            semaphore.signal()
        }
        semaphore.wait()
        return fps
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
        heldSample = nil
        pendingSample = nil
        lock.unlock()
    }

    public func setOutputFps(_ fps: Int) {
        outputFps = max(1, fps)
        scheduleTimer()
    }

    public func setPlaybackRate(_ rate: Float) {
        lock.lock()
        playbackRate = max(0.01, min(1, rate))
        lock.unlock()
    }

    public func beginMutedPlayback(at time: CMTime) {
        let work = { [weak self] in
            guard let self else { return }
            self.mutedPlayback = true
            self.wallClockAnchor = (time, CFAbsoluteTimeGetCurrent())
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            work()
        } else {
            queue.async(execute: work)
        }
    }

    public func endMutedPlayback() {
        let work = { [weak self] in
            guard let self else { return }
            self.mutedPlayback = false
            self.wallClockAnchor = nil
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            work()
        } else {
            queue.async(execute: work)
        }
    }

    public var currentMediaTime: CMTime {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return currentMediaTimeOnQueue()
        }
        return queue.sync { currentMediaTimeOnQueue() }
    }

    public func seekMediaTime(_ time: CMTime) {
        let work = { [weak self] in
            guard let self else { return }
            do {
                try self.startReader(at: time)
            } catch {
                Log.capture.error("video seek failed: \(error.localizedDescription)")
            }
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            work()
        } else {
            queue.async(execute: work)
        }
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
        var loadedSourceFps: Float = 30
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
                let nominalFps = try await first.load(.nominalFrameRate)
                loadedTrack = first
                loadedSize = size.applying(transform).absSize
                loadedDuration = duration
                if nominalFps > 1 {
                    loadedSourceFps = nominalFps
                }
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
        self.sourceFps = loadedSourceFps
        if videoSize.width <= 0 || videoSize.height <= 0 {
            throw NSError(domain: "VideoFrameSource", code: 3)
        }
        self.decodeSize = computeDecodeSize(videoSize: loadedSize, target: decodeTarget)
    }

    private func computeDecodeSize(videoSize: CGSize, target: OutputResolution?) -> CGSize {
        guard let target else { return videoSize }
        let ledMax = max(target.width, target.height)
        let desired = max(64, min(720, ledMax * 4))
        let longEdge = max(videoSize.width, videoSize.height)
        if longEdge <= CGFloat(desired) { return videoSize }
        let scale = CGFloat(desired) / longEdge
        let w = max(2, Int((videoSize.width * scale).rounded()))
        let h = max(2, Int((videoSize.height * scale).rounded()))
        return CGSize(width: w & ~1, height: h & ~1)
    }

    private func startReader(at mediaTime: CMTime? = nil) throws {
        guard let track else {
            throw NSError(domain: "VideoFrameSource", code: 4)
        }
        lock.lock()
        let activeRange = loopRange
        lock.unlock()
        let reader = try AVAssetReader(asset: asset)
        let totalSec = CMTimeGetSeconds(assetDuration)
        let timescale = assetDuration.timescale > 0 ? assetDuration.timescale : 600
        let rangeStart = CMTime(seconds: totalSec * activeRange.start, preferredTimescale: timescale)
        let rangeEnd = CMTime(seconds: totalSec * activeRange.end, preferredTimescale: timescale)
        let startTime = mediaTime ?? rangeStart
        let clampedStart = CMTimeMaximum(rangeStart, CMTimeMinimum(startTime, rangeEnd))
        rangeStartSeconds = CMTimeGetSeconds(clampedStart)
        if totalSec.isFinite, totalSec > 0 {
            let span = CMTimeSubtract(rangeEnd, clampedStart)
            reader.timeRange = CMTimeRange(
                start: clampedStart,
                duration: CMTime(seconds: max(0.001, CMTimeGetSeconds(span)), preferredTimescale: timescale)
            )
        }
        var settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        if decodeSize.width > 0, decodeSize.height > 0,
           decodeSize != videoSize {
            settings[kCVPixelBufferWidthKey as String] = Int(decodeSize.width)
            settings[kCVPixelBufferHeightKey as String] = Int(decodeSize.height)
        }
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
        self.heldSample = nil
        self.pendingSample = nil
        self.wallClockStart = CFAbsoluteTimeGetCurrent()
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
        guard let sampleBuffer = sampleForCurrentTime() else {
            if loop, restartReaderIfNeeded(), let retry = sampleForCurrentTime() {
                emit(retry)
                return
            }
            stop()
            return
        }
        emit(sampleBuffer)
    }

    private func sampleForCurrentTime() -> CMSampleBuffer? {
        let target = currentMediaTimeOnQueue()
        if needsReaderReset(for: target) {
            do {
                try startReader(at: target)
            } catch {
                return heldSample
            }
        }
        lock.lock()
        let output = self.output
        var best = heldSample
        lock.unlock()
        guard let output else { return best }

        while true {
            let sample: CMSampleBuffer?
            lock.lock()
            if let pending = pendingSample {
                pendingSample = nil
                sample = pending
            } else {
                sample = output.copyNextSampleBuffer()
            }
            lock.unlock()

            guard let sample else {
                lock.lock()
                heldSample = nil
                pendingSample = nil
                lock.unlock()
                guard restartReaderIfNeeded() else { return best }
                lock.lock()
                best = heldSample
                lock.unlock()
                continue
            }

            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            if CMTimeCompare(pts, target) <= 0 {
                best = sample
                lock.lock()
                heldSample = sample
                lock.unlock()
                continue
            }
            lock.lock()
            pendingSample = sample
            lock.unlock()
            return best ?? sample
        }
    }

    private func needsReaderReset(for target: CMTime) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let heldSample else { return false }
        let heldPTS = CMSampleBufferGetPresentationTimeStamp(heldSample)
        return CMTimeCompare(target, heldPTS) < 0
    }

    private func currentMediaTimeOnQueue() -> CMTime {
        lock.lock()
        let muted = mutedPlayback
        let anchor = wallClockAnchor
        let rate = playbackRate
        let start = wallClockStart
        let rangeStart = rangeStartSeconds
        lock.unlock()

        if muted, let anchor {
            let elapsed = max(0, CFAbsoluteTimeGetCurrent() - anchor.wall)
            let seconds = CMTimeGetSeconds(anchor.media) + Double(rate) * elapsed
            return CMTime(seconds: seconds, preferredTimescale: 600)
        }
        if let playbackClock {
            return playbackClock()
        }
        guard let start else { return .zero }
        let elapsed = max(0, CFAbsoluteTimeGetCurrent() - start)
        return CMTime(seconds: rangeStart + Double(rate) * elapsed, preferredTimescale: 600)
    }

    private func emit(_ sampleBuffer: CMSampleBuffer) {
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
