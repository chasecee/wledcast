import Accelerate
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

public final class VideoFrameSource: @unchecked Sendable {
    public var onFrameBGRA: ((vImage_Buffer) -> Void)?
    public var onPreviewBuffer: ((CVPixelBuffer) -> Void)?
    public var shouldEmitPreview: (() -> Bool)?

    public private(set) var videoSize: CGSize = .zero
    public private(set) var sourceFps: Float = 30

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "wledcast.video.source", qos: .userInitiated)
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
    private var lastTargetTime: CMTime = .invalid
    private var lastEmitSample: CMSampleBuffer?
    private var lastPlaybackClockSec: Double?
    private var forceReaderReset = false
    private var deliveredFrames = 0
    private var lastPerfFrames = 0
    private var lastPerfAt = CFAbsoluteTimeGetCurrent()

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
        let desired = max(64, min(512, Int((Double(ledMax) * 1.5).rounded())))
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
        self.lastTargetTime = .invalid
        lock.unlock()
        if let first = output.copyNextSampleBuffer() {
            lock.lock()
            self.heldSample = first
            lock.unlock()
        }
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
        let target = currentMediaTimeOnQueue()
        if let sampleBuffer = sampleForCurrentTime(for: target) {
            lastEmitSample = sampleBuffer
            if onPreviewBuffer != nil,
               shouldEmitPreview?() != false,
               let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                onPreviewBuffer?(pixelBuffer)
            }
        }
        guard let sample = lastEmitSample else {
            guard loop else {
                stop()
                return
            }
            return
        }
        emit(sample)
        deliveredFrames += 1
        emitPerfIfDue()
    }

    private func emitPerfIfDue() {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastPerfAt >= 0.5 else { return }
        let elapsed = now - lastPerfAt
        let deltaFrames = deliveredFrames - lastPerfFrames
        lastPerfFrames = deliveredFrames
        lastPerfAt = now
        guard let sample = lastEmitSample,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let output = decodeTarget ?? OutputResolution(width: width, height: height)
        PerfLog.noteCapture(
            frameWidth: width,
            frameHeight: height,
            sourceRect: .zero,
            output: output,
            streamFps: elapsed > 0 ? Double(deltaFrames) / elapsed : 0
        )
    }

    private func sampleForCurrentTime(for target: CMTime) -> CMSampleBuffer? {
        if needsReaderReset(for: target) {
            do {
                try startReader(at: target)
            } catch {
                Log.capture.error("video reader reset failed: \(error.localizedDescription)")
                lock.lock()
                lastTargetTime = target
                let sample = heldSample
                lock.unlock()
                return sample
            }
        }
        lock.lock()
        lastTargetTime = target
        let output = self.output
        let reader = self.reader
        var best = heldSample
        lock.unlock()
        guard let output, let reader, reader.status == .reading else { return best }

        while true {
            let sample: CMSampleBuffer?
            lock.lock()
            if let pending = pendingSample {
                pendingSample = nil
                sample = pending
            } else if reader.status == .reading {
                sample = output.copyNextSampleBuffer()
            } else {
                sample = nil
            }
            lock.unlock()

            guard let sample else {
                lock.lock()
                heldSample = nil
                pendingSample = nil
                lock.unlock()
                if best != nil { return best }
                guard restartReaderIfNeeded() else { return nil }
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
        if forceReaderReset {
            forceReaderReset = false
            return true
        }
        if CMTIME_IS_VALID(lastTargetTime), CMTimeCompare(target, lastTargetTime) < 0 {
            return true
        }
        guard let heldSample else { return false }
        let heldPTS = CMSampleBufferGetPresentationTimeStamp(heldSample)
        return CMTimeCompare(target, heldPTS) < 0
    }

    private func notePlaybackClockJump(_ raw: CMTime) {
        let sec = CMTimeGetSeconds(raw)
        guard sec.isFinite else { return }
        lock.lock()
        defer { lock.unlock() }
        if let last = lastPlaybackClockSec, sec + 0.15 < last {
            forceReaderReset = true
        }
        lastPlaybackClockSec = sec
    }

    private func currentMediaTimeOnQueue() -> CMTime {
        lock.lock()
        let muted = mutedPlayback
        let anchor = wallClockAnchor
        let rate = playbackRate
        let start = wallClockStart
        let rangeStart = rangeStartSeconds
        let activeLoop = loop
        lock.unlock()

        let raw: CMTime
        if muted, let anchor {
            let elapsed = max(0, CFAbsoluteTimeGetCurrent() - anchor.wall)
            let seconds = CMTimeGetSeconds(anchor.media) + Double(rate) * elapsed
            raw = CMTime(seconds: seconds, preferredTimescale: 600)
        } else if let playbackClock {
            raw = playbackClock()
            notePlaybackClockJump(raw)
            return clampToLoopRange(raw)
        } else if let start {
            let elapsed = max(0, CFAbsoluteTimeGetCurrent() - start)
            raw = CMTime(seconds: rangeStart + Double(rate) * elapsed, preferredTimescale: 600)
        } else {
            return .zero
        }
        guard activeLoop else { return clampToLoopRange(raw) }
        return loopMediaTime(from: raw)
    }

    private func clampToLoopRange(_ time: CMTime) -> CMTime {
        lock.lock()
        let activeRange = loopRange
        lock.unlock()
        let totalSec = CMTimeGetSeconds(assetDuration)
        guard totalSec.isFinite, totalSec > 0 else { return time }
        let timescale = assetDuration.timescale > 0 ? assetDuration.timescale : CMTimeScale(600)
        let rangeStartSec = totalSec * activeRange.start
        let rangeEndSec = totalSec * activeRange.end
        var sec = CMTimeGetSeconds(time)
        sec = max(rangeStartSec, min(rangeEndSec, sec))
        return CMTime(seconds: sec, preferredTimescale: timescale)
    }

    private func loopMediaTime(from raw: CMTime) -> CMTime {
        lock.lock()
        let activeRange = loopRange
        lock.unlock()
        let totalSec = CMTimeGetSeconds(assetDuration)
        guard totalSec.isFinite, totalSec > 0 else { return raw }
        let timescale = assetDuration.timescale > 0 ? assetDuration.timescale : CMTimeScale(600)
        let rangeStartSec = totalSec * activeRange.start
        let rangeEndSec = totalSec * activeRange.end
        let spanSec = max(0.001, rangeEndSec - rangeStartSec)
        var sec = CMTimeGetSeconds(raw)
        if sec < rangeStartSec {
            sec = rangeStartSec
        } else if sec > rangeEndSec {
            sec = rangeStartSec + (sec - rangeStartSec).truncatingRemainder(dividingBy: spanSec)
        }
        return CMTime(seconds: sec, preferredTimescale: timescale)
    }

    private func loopRangeStartTime() -> CMTime {
        lock.lock()
        let activeRange = loopRange
        lock.unlock()
        let totalSec = CMTimeGetSeconds(assetDuration)
        let timescale = assetDuration.timescale > 0 ? assetDuration.timescale : CMTimeScale(600)
        return CMTime(seconds: totalSec * activeRange.start, preferredTimescale: timescale)
    }

    private func loopRangeEndTime() -> CMTime {
        lock.lock()
        let activeRange = loopRange
        lock.unlock()
        let totalSec = CMTimeGetSeconds(assetDuration)
        let timescale = assetDuration.timescale > 0 ? assetDuration.timescale : CMTimeScale(600)
        return CMTime(seconds: totalSec * activeRange.end, preferredTimescale: timescale)
    }

    private func emit(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let crop = normalizedCrop(forWidth: width, height: height)
        let buffer = vImage_Buffer(
            data: baseAddress.advanced(by: crop.y * bytesPerRow + crop.x * 4),
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
