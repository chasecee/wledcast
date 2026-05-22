import AVFoundation
import Foundation

public final class VideoAudioPlayer {
    private let player: AVPlayer
    private let duration: CMTime
    private var loop: Bool
    private var loopRange: LoopRange
    private var endObserver: NSObjectProtocol?
    private var rangeEndObserver: Any?
    private var isLoopingSeek = false
    private var playbackRate: Float = 1
    private var isMuted = false
    private let timeLock = NSLock()
    private var cachedPlaybackTime: CMTime = .zero
    private var timeObserver: Any?

    public init(
        url: URL,
        loop: Bool,
        loopRange: LoopRange,
        volume: Float,
        muted: Bool,
        sourceFps: Float,
        outputFps: Int
    ) throws {
        let asset = AVAsset(url: url)
        let semaphore = DispatchSemaphore(value: 0)
        var loadedDuration: CMTime = .zero
        var playbackAsset: AVAsset = asset
        Task {
            loadedDuration = (try? await asset.load(.duration)) ?? .zero
            if let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first,
               let composition = try? Self.audioOnlyComposition(from: audioTrack, duration: loadedDuration) {
                playbackAsset = composition
            }
            semaphore.signal()
        }
        semaphore.wait()

        let item = AVPlayerItem(asset: playbackAsset)
        item.audioTimePitchAlgorithm = .timeDomain
        let player = AVPlayer(playerItem: item)
        player.volume = max(0, min(1, volume))
        player.automaticallyWaitsToMinimizeStalling = false
        self.player = player
        self.duration = loadedDuration
        self.loop = loop
        self.loopRange = loopRange.clamped()
        self.isMuted = muted

        applyRate(sourceFps: sourceFps, outputFps: outputFps)
        applyPlaybackLimits()
        installObservers()
        installTimeObserver()
        seekToRangeStart {
            player.isMuted = muted
            if muted {
                player.pause()
            } else {
                player.rate = self.playbackRate
                player.play()
            }
        }
    }

    public var playbackTime: CMTime {
        timeLock.lock()
        defer { timeLock.unlock() }
        return cachedPlaybackTime
    }

    public var playbackRateValue: Float {
        playbackRate
    }

    public static func playbackRate(sourceFps: Float, outputFps: Int) -> Float {
        let source = sourceFps > 1 ? sourceFps : 30
        let output = Float(max(1, outputFps))
        guard output < source else { return 1 }
        return output / source
    }

    public func updateOutputFps(_ outputFps: Int, sourceFps: Float) {
        applyRate(sourceFps: sourceFps, outputFps: outputFps)
        guard !isMuted else { return }
        player.rate = playbackRate
    }

    public func updateLoopRange(_ range: LoopRange) {
        loopRange = range.clamped()
        applyPlaybackLimits()
        seekToRangeStart { [weak self] in
            guard let self else { return }
            if self.isMuted {
                self.player.pause()
            } else {
                self.player.rate = self.playbackRate
                self.player.play()
            }
        }
    }

    public func stop() {
        player.pause()
        removeTimeObserver()
        removeObservers()
    }

    public func setVolume(_ value: Float) {
        player.volume = max(0, min(1, value))
    }

    public func setMuted(_ value: Bool) {
        isMuted = value
        player.isMuted = value
        if value {
            player.pause()
        } else {
            player.rate = playbackRate
            player.play()
        }
    }

    public func pauseForScrub() {
        player.pause()
    }

    public func pauseForMute() {
        player.pause()
    }

    public func syncTo(time: CMTime) {
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard finished, let self else { return }
            self.timeLock.lock()
            self.cachedPlaybackTime = time
            self.timeLock.unlock()
            self.player.isMuted = self.isMuted
            if self.isMuted {
                self.player.pause()
            } else {
                self.player.rate = self.playbackRate
                self.player.play()
            }
        }
    }

    private func applyRate(sourceFps: Float, outputFps: Int) {
        playbackRate = Self.playbackRate(sourceFps: sourceFps, outputFps: outputFps)
    }

    private func rangeStartTime() -> CMTime {
        let totalSec = CMTimeGetSeconds(duration)
        guard totalSec.isFinite, totalSec > 0 else { return .zero }
        let timescale = max(CMTimeScale(600), duration.timescale)
        return CMTime(seconds: totalSec * loopRange.start, preferredTimescale: timescale)
    }

    private func rangeEndTime() -> CMTime {
        let totalSec = CMTimeGetSeconds(duration)
        guard totalSec.isFinite, totalSec > 0 else { return duration }
        let timescale = max(CMTimeScale(600), duration.timescale)
        return CMTime(seconds: totalSec * loopRange.end, preferredTimescale: timescale)
    }

    private func seekToRangeStart(then: (() -> Void)? = nil) {
        let start = rangeStartTime()
        player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard finished, let self else { return }
            self.timeLock.lock()
            self.cachedPlaybackTime = start
            self.timeLock.unlock()
            then?()
        }
    }

    private func applyPlaybackLimits() {
        if loop {
            player.currentItem?.forwardPlaybackEndTime = .invalid
        } else {
            player.currentItem?.forwardPlaybackEndTime = rangeEndTime()
        }
        installRangeEndObserver()
    }

    private func installTimeObserver() {
        let interval = CMTime(value: 1, timescale: 30)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            self.timeLock.lock()
            self.cachedPlaybackTime = time
            self.timeLock.unlock()
            guard self.loop, !self.isLoopingSeek else { return }
            let end = self.rangeEndTime()
            let lead = CMTime(value: 1, timescale: 30)
            let trigger = CMTimeSubtract(end, lead)
            if CMTimeCompare(time, trigger) >= 0 {
                self.handleReachedEnd()
            }
        }
    }

    private func removeTimeObserver() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }

    private func installObservers() {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            self?.handleReachedEnd()
        }
        installRangeEndObserver()
    }

    private func installRangeEndObserver() {
        removeRangeEndObserver()
        guard loop else { return }
        let end = rangeEndTime()
        let trigger = CMTimeSubtract(end, CMTime(value: 1, timescale: 30))
        rangeEndObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: trigger)],
            queue: .main
        ) { [weak self] in
            self?.handleReachedEnd()
        }
    }

    private func removeRangeEndObserver() {
        if let rangeEndObserver {
            player.removeTimeObserver(rangeEndObserver)
            self.rangeEndObserver = nil
        }
    }

    private func handleReachedEnd() {
        guard loop else {
            player.pause()
            return
        }
        guard !isLoopingSeek else { return }
        isLoopingSeek = true
        seekToRangeStart { [weak self] in
            guard let self else { return }
            self.isLoopingSeek = false
            self.applyPlaybackLimits()
            if self.isMuted {
                self.player.pause()
            } else {
                self.player.rate = self.playbackRate
                self.player.play()
            }
        }
    }

    private func removeObservers() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        removeRangeEndObserver()
    }

    private static func audioOnlyComposition(from audioTrack: AVAssetTrack, duration: CMTime) throws -> AVAsset {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw NSError(domain: "VideoAudioPlayer", code: 1)
        }
        let range = CMTimeRange(start: .zero, duration: duration)
        try track.insertTimeRange(range, of: audioTrack, at: .zero)
        return composition
    }
}
