import ApplicationServices
import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import SwiftUI
import WledCore

enum FetchState: Equatable {
    case idle
    case running
    case failed(String)
}

@MainActor
final class AppModel: ObservableObject {
    @Published var hosts: [WLEDHost] = []
    @Published var selectedHost: String = ""
    @Published var outputResolution: OutputResolution?
    @Published var filters: FilterConfig = .default
    @Published var flickerFighter: Double = 0
    @Published var captureBox: CaptureBox = .centered(on: NSScreen.main ?? NSScreen.screens.first!)
    @Published var captureMode: CaptureMode = .region
    @Published var videoLibrary: [URL] = []
    @Published var selectedVideo: URL?
    @Published var youtubeURLInput: String = ""
    @Published var fetchState: FetchState = .idle
    @Published var videoCropBox: VideoCropBox = .full
    @Published var loopVideo = true
    @Published var loopRange: LoopRange = .full
    @Published var overlayMosaicEnabled = true
    @Published private(set) var fps: Int = WLEDHost.defaultFps
    @Published private(set) var targetFps: Int = WLEDHost.defaultFps
    @Published var aspectLock = true
    @Published var isStreaming = false
    @Published var senderState: DDPSenderState = .stopped
    @Published var audioVolume: Double = 1.0
    @Published var audioMuted: Bool = false

    private let discovery = WLEDDiscoveryClient()
    private var discoveryTask: Task<Void, Never>?
    private var session: SessionController?
    private var sender: DDPSender?
    private var source: DisplayFrameSource?
    private var videoSource: VideoFrameSource?
    private var videoPreviewSource: VideoFrameSource?
    private var audioPlayer: VideoAudioPlayer?
    private var overlay: OverlayWindowController?
    private var boxRef: CaptureBoxRef?
    private var lastMosaicImage: CGImage?
    private let mosaicPreviewGate = PreviewGate()
    private let videoPreviewGate = PreviewGate()
    private var scrubGenerator: AVAssetImageGenerator?
    private var scrubAssetURL: URL?
    private var scrubAssetDuration: CMTime = .zero
    private var streamingSourceFps: Float = 30
    private var isLoopScrubbing = false
    private var savedHostReachabilityChecked = false

    private let defaults = UserDefaults.standard
    private let videoSettingsStore = VideoSettingsStore()
    private let youtubeDownloader = YouTubeDownloader()
    private var fetchTask: Task<Void, Never>?

    init() {
        restore()
        migrateLegacyVideoSettings()
        refreshVideoLibrary()
        applyVideoSettings(for: selectedVideo)
        startDiscovery()
        if !selectedHost.isEmpty {
            refreshSelectedHostProfile()
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if !self.selectedHost.isEmpty {
                await self.discovery.verify(host: self.selectedHost)
            }
            self.autoStart()
        }
        AgentControlServer.shared.start { [weak self] request in
            await self?.handleAgent(request) ?? .failure("app stopped")
        }
        syncPreviewGates()
    }

    var wledFpsLabel: String {
        if targetFps == 0 {
            return "Unlimited"
        }
        return "\(fps) fps"
    }

    private func autoStart() {
        guard !isStreaming, canStartStreaming else { return }
        startStreaming()
    }

    private var isOverlayVisible: Bool {
        overlay?.window?.isVisible == true
    }

    var isWindowVisible: Bool {
        isOverlayVisible
    }

    var canStartStreaming: Bool {
        guard !selectedHost.isEmpty, outputResolution != nil else { return false }
        if captureMode == .video {
            return selectedVideo != nil
        }
        return true
    }

    private var isSelectedHostConnected: Bool {
        hosts.contains { $0.host.caseInsensitiveCompare(selectedHost) == .orderedSame }
    }

    private func reconcileSelectedHostIfNeeded(with discovered: [WLEDHost]) {
        guard !selectedHost.isEmpty, !discovered.isEmpty else { return }
        guard !isSelectedHostConnected else { return }
        guard !savedHostReachabilityChecked else { return }
        savedHostReachabilityChecked = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            let saved = self.selectedHost
            do {
                let profile = try await self.discovery.fetchHostProfile(host: saved)
                guard self.selectedHost == saved else { return }
                await self.discovery.inject(host: saved, profile: profile)
                self.applyHostProfile(profile, restartIfStreaming: false)
                return
            } catch {
                Log.app.info("saved host \(saved) unreachable, reconciling with discovery")
            }
            guard self.selectedHost == saved,
                  let replacement = self.replacementHost(for: discovered) else { return }
            self.setHost(replacement.host)
        }
    }

    private func replacementHost(for discovered: [WLEDHost]) -> WLEDHost? {
        if discovered.count == 1 { return discovered[0] }
        guard let resolution = outputResolution else { return nil }
        let matches = discovered.filter { $0.resolution == resolution }
        return matches.count == 1 ? matches[0] : nil
    }

    private func refreshSelectedHostProfile() {
        let host = selectedHost
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let profile = try await self.discovery.fetchHostProfile(host: host)
                guard self.selectedHost == host else { return }
                await self.discovery.inject(host: host, profile: profile)
                self.applyHostProfile(profile, restartIfStreaming: true)
            } catch {
                Log.app.warning("failed to fetch WLED profile for \(host): \(error.localizedDescription)")
            }
        }
    }

    private func applyHostProfile(_ profile: WLEDHostProfile, restartIfStreaming: Bool) {
        let previousResolution = outputResolution
        let previousFps = fps
        targetFps = profile.targetFps
        outputResolution = profile.resolution
        overlay?.outputResolution = profile.resolution
        applyEffectiveFps(profile.effectiveFps)
        persist()
        if isStreaming {
            if outputResolution != previousResolution && fps == previousFps {
                restartStreaming()
            }
            return
        }
        guard restartIfStreaming || outputResolution != previousResolution || fps != previousFps else { return }
        autoStart()
    }

    private func applyEffectiveFps(_ value: Int) {
        let next = max(1, value)
        guard fps != next else {
            syncPreviewGates()
            return
        }
        fps = next
        syncPreviewGates()
        if isStreaming {
            restartStreaming()
            return
        }
        if captureMode == .video {
            let rate = VideoAudioPlayer.playbackRate(sourceFps: streamingSourceFps, outputFps: next)
            videoSource?.setPlaybackRate(rate)
            videoPreviewSource?.setPlaybackRate(rate)
            audioPlayer?.updateOutputFps(next, sourceFps: streamingSourceFps)
            videoSource?.setOutputFps(next)
            videoPreviewSource?.setOutputFps(next)
        }
    }

    private func syncFpsFromSelectedHost() {
        guard let host = hosts.first(where: { $0.host.caseInsensitiveCompare(selectedHost) == .orderedSame }) else {
            return
        }
        targetFps = host.targetFps
        applyEffectiveFps(host.effectiveFps)
    }

    func quit() {
        stopStreaming()
        NSApp.terminate(nil)
    }

    func setHost(_ host: String) {
        let hostChanged = host != selectedHost
        selectedHost = host
        savedHostReachabilityChecked = false
        if let info = hosts.first(where: { $0.host.caseInsensitiveCompare(host) == .orderedSame }) {
            applyHostProfile(
                WLEDHostProfile(resolution: info.resolution, targetFps: info.targetFps),
                restartIfStreaming: hostChanged
            )
        } else {
            outputResolution = nil
            persist()
            guard hostChanged else { return }
            if isStreaming {
                restartStreaming()
            } else {
                autoStart()
            }
        }
    }

    func setCaptureMode(_ mode: CaptureMode) {
        guard captureMode != mode else { return }
        captureMode = mode
        if mode == .video {
            refreshVideoLibrary()
            if selectedVideo == nil {
                selectedVideo = videoLibrary.first
            }
        }
        let overlay = ensureOverlay()
        overlay.setMode(mode)
        syncOverlayVisualizationSettings()
        refreshVideoPreviewIfNeeded()
        persist()
        if isStreaming {
            restartStreaming()
        } else {
            autoStart()
        }
    }

    func setAspectLock(_ value: Bool) {
        aspectLock = value
        overlay?.aspectLock = value
        persist()
    }

    func setOverlayMosaicEnabled(_ value: Bool) {
        overlayMosaicEnabled = value
        if value {
            overlay?.mosaicHolder.set(lastMosaicImage)
        } else {
            overlay?.mosaicHolder.set(nil)
        }
        syncOverlayVisualizationSettings()
        syncAgentSession()
        persist()
    }

    func setSelectedVideo(_ url: URL?) {
        selectedVideo = url
        scrubGenerator = nil
        scrubAssetURL = nil
        scrubAssetDuration = .zero
        applyVideoSettings(for: url)
        persist()
        refreshVideoPreviewIfNeeded()
        if isStreaming, captureMode == .video {
            restartStreaming()
        }
    }

    func setAudioVolume(_ value: Double) {
        audioVolume = max(0, min(1, value))
        audioPlayer?.setVolume(Float(audioVolume))
        persist()
    }

    func setAudioMuted(_ value: Bool) {
        guard audioMuted != value else { return }
        audioMuted = value
        persist()

        if captureMode == .video, isStreaming, let videoSource, let audioPlayer {
            if value {
                let time = audioPlayer.playbackTime
                videoSource.beginMutedPlayback(at: time)
                audioPlayer.pauseForMute()
                audioPlayer.setMuted(true)
            } else {
                let time = videoSource.currentMediaTime
                videoSource.endMutedPlayback()
                videoSource.seekMediaTime(time)
                audioPlayer.syncTo(time: time)
                audioPlayer.setMuted(false)
            }
            return
        }
        audioPlayer?.setMuted(value)
    }

    func setLoopVideo(_ value: Bool) {
        loopVideo = value
        persist()
        refreshVideoPreviewIfNeeded()
        if isStreaming, captureMode == .video {
            restartStreaming()
        }
    }

    func refreshVideoLibrary() {
        let directory = resolvedVideoDirectoryURL()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        videoLibrary = items
            .filter { $0.pathExtension.lowercased() == "mp4" }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        if let selectedVideo, !videoLibrary.contains(selectedVideo) {
            self.selectedVideo = videoLibrary.first
        } else if self.selectedVideo == nil {
            self.selectedVideo = videoLibrary.first
        }
        videoSettingsStore.prune(keeping: videoLibrary)
        applyVideoSettings(for: selectedVideo)
    }

    func fetchYouTube() {
        guard fetchState != .running else { return }
        let requestedURL = youtubeURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedURL.isEmpty else { return }

        fetchState = .running
        let scriptURL = resolvedFetchScriptURL()
        fetchTask?.cancel()
        fetchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let savedURL = try await self.youtubeDownloader.fetch(url: requestedURL, scriptURL: scriptURL)
                self.refreshVideoLibrary()
                let selected = self.videoLibrary.first {
                    $0.standardizedFileURL.path == savedURL.standardizedFileURL.path
                } ?? savedURL
                self.setSelectedVideo(selected)
                self.youtubeURLInput = ""
                self.fetchState = .idle
            } catch is CancellationError {
                self.fetchState = .idle
            } catch {
                self.fetchState = .failed(error.localizedDescription)
                Log.capture.error("youtube fetch failed: \(error.localizedDescription)")
            }
        }
    }

    func setFilters(_ value: FilterConfig) {
        filters = value
        session?.updateFilters(value)
        persist()
    }

    func setFlickerFighter(_ value: Double) {
        flickerFighter = min(1, max(0, value))
        session?.updateFlickerFighter(Float(flickerFighter))
        persist()
    }

    private func ensureOverlayVisible() {
        let controller = ensureOverlay()
        if controller.window?.isVisible != true {
            controller.show()
        }
    }

    private func ensureOverlay() -> OverlayWindowController {
        if let overlay {
            overlay.setMode(captureMode)
            overlay.setCaptureBox(captureBox)
            overlay.setVideoCrop(videoCropBox)
            if let resolution = outputResolution {
                overlay.outputResolution = resolution
            }
            overlay.aspectLock = aspectLock
            overlay.setMinimumSettingsWidth(360)
            syncOverlayVisualizationSettings()
            return overlay
        }

        let controller = OverlayWindowController(captureBox: captureBox)
        controller.setMode(captureMode)
        controller.setCaptureBox(captureBox)
        controller.setVideoCrop(videoCropBox)
        if let resolution = outputResolution {
            controller.outputResolution = resolution
        }
        controller.aspectLock = aspectLock
        controller.setMinimumSettingsWidth(360)
        controller.setSettingsContent(
            AnyView(
                SettingsPaneView(
                    onHeightChange: { [weak self] height in
                        self?.overlay?.setSettingsHeight(height)
                    },
                    minWidth: 360
                )
                .environmentObject(self)
            )
        )
        controller.onChange = { [weak self] box in
            Task { @MainActor in
                guard let self else { return }
                let displayChanged = self.captureBox.displayID != box.displayID
                self.captureBox = box
                self.boxRef?.update(box)
                self.persist()
                guard self.isStreaming, self.captureMode == .region else { return }
                if displayChanged {
                    self.restartStreaming()
                } else {
                    self.source?.updateRegion(box: box)
                }
            }
        }
        controller.onVideoCropChange = { [weak self] crop in
            Task { @MainActor in
                guard let self else { return }
                self.videoCropBox = crop
                self.videoSource?.updateCrop(crop)
                self.videoPreviewSource?.updateCrop(crop)
                self.saveCurrentVideoSettings()
            }
        }
        overlay = controller
        syncOverlayVisualizationSettings()
        return controller
    }

    func hideOverlay() {
        overlay?.hide()
        stopVideoPreview()
        syncOverlayVisualizationSettings()
        syncAgentSession()
    }

    func showOverlay() {
        ensureOverlayVisible()
        refreshVideoPreviewIfNeeded()
        syncOverlayVisualizationSettings()
        syncAgentSession()
    }

    func toggleOverlay() {
        if isOverlayVisible {
            hideOverlay()
        } else {
            showOverlay()
        }
    }

    func startStreaming() {
        guard !isStreaming else { return }
        guard !selectedHost.isEmpty else { return }
        syncFpsFromSelectedHost()
        guard let resolution = outputResolution else { return }
        if captureMode == .region, !ensureScreenPermission() { return }

        do {
            let newSender = try DDPSender(host: selectedHost)
            newSender.onStateChanged = { [weak self] state in
                Task { @MainActor in self?.senderState = state }
            }
            sender = newSender
            let controller = SessionController(
                sender: newSender,
                outputResolution: resolution,
                filterConfig: filters,
                flickerFighter: Float(flickerFighter)
            )
            controller.shouldProcessPreview = { [weak self] in
                self?.mosaicPreviewGate.shouldEmit() ?? false
            }
            controller.onFrameProcessed = { [weak self] pixels, width, height in
                Task { @MainActor in
                    self?.updatePreview(RGBFrame(width: width, height: height, pixels: pixels))
                }
            }
            session = controller

            switch captureMode {
            case .video:
                guard let selectedVideo else {
                    senderState = .failed("No video selected")
                    sender?.stop()
                    sender = nil
                    session?.stop()
                    session = nil
                    refreshVideoPreviewIfNeeded()
                    return
                }
                let sourceFps = VideoFrameSource.loadSourceFps(url: selectedVideo)
                streamingSourceFps = sourceFps
                let playbackRate = VideoAudioPlayer.playbackRate(sourceFps: sourceFps, outputFps: fps)
                startAudioPlayer(url: selectedVideo, outputFps: fps, sourceFps: sourceFps)
                let videoSource = try VideoFrameSource(
                    url: selectedVideo,
                    fps: fps,
                    crop: videoCropBox,
                    loop: loopVideo,
                    loopRange: loopRange,
                    decodeTarget: resolution,
                    playbackClock: { [weak self] in
                        self?.audioPlayer?.playbackTime ?? .zero
                    }
                )
                videoSource.setPlaybackRate(playbackRate)
                videoSource.shouldEmitPreview = { [weak self] in
                    guard let self else { return false }
                    return self.isOverlayVisible && self.videoPreviewGate.shouldEmit()
                }
                videoSource.onFrameBGRA = { [weak controller] buffer in
                    controller?.process(bgra: buffer)
                }
                videoSource.onPreviewBuffer = { [weak self] buffer in
                    guard let self else { return }
                    PerfLog.recordHudPreview()
                    Task { @MainActor in
                        guard !self.isLoopScrubbing else { return }
                        self.overlay?.setPreviewBuffer(buffer)
                    }
                }
                stopVideoPreview()
                self.videoSource = videoSource
                source = nil
            case .region:
                stopVideoPreview()
                startScreenCaptureStream(resolution: resolution, controller: controller)
            }
            PerfLog.configure(
                mode: captureMode == .region ? "region" : "video",
                output: resolution,
                fps: fps
            )
            var perfStart: [String: String] = [
                "mode": captureMode == .region ? "region" : "video",
                "output": "\(resolution.width)x\(resolution.height)",
                "target_fps": "\(fps)",
                "host": selectedHost,
                "mosaic": overlayMosaicEnabled ? "1" : "0",
                "overlay_visible": isOverlayVisible ? "1" : "0",
                "perf_path": PerfLog.path.path,
                "log_path": FileLog.shared.location.path,
            ]
            if captureMode == .region {
                perfStart["capture_box"] = "\(captureBox.width)x\(captureBox.height)"
                perfStart["capture_display"] = "\(captureBox.displayID)"
            } else if let selectedVideo {
                perfStart["video"] = selectedVideo.lastPathComponent
            }
            PerfLog.event("stream_start", perfStart)
            isStreaming = true
        } catch {
            senderState = .failed(error.localizedDescription)
            refreshVideoPreviewIfNeeded()
        }
    }

    private func startScreenCaptureStream(resolution: OutputResolution, controller: SessionController) {
        let selection = CaptureSelection(mode: .region, displayID: captureBox.displayID)
        let ref = CaptureBoxRef(captureBox)
        boxRef = ref
        let excludedWindows = [overlay?.captureWindowID].compactMap { $0 }
        let frameSource = DisplayFrameSource(
            boxRef: ref,
            outputResolution: resolution,
            fps: fps,
            captureSelection: selection,
            excludedWindowIDs: excludedWindows
        )
        frameSource.onFrameBGRA = { [weak controller] buffer in
            controller?.process(bgra: buffer)
        }
        source = frameSource
    }

    private func restartStreaming() {
        stopStreaming()
        startStreaming()
    }

    func stopStreaming() {
        if isStreaming {
            PerfLog.event("stream_stop")
        }
        session?.blackout()
        source?.stop()
        source = nil
        videoSource?.stop()
        videoSource = nil
        audioPlayer?.stop()
        audioPlayer = nil
        boxRef = nil
        session?.stop()
        session = nil
        sender?.stop()
        sender = nil
        isStreaming = false
        lastMosaicImage = nil
        overlay?.mosaicHolder.set(nil)
        refreshVideoPreviewIfNeeded()
    }

    private func startDiscovery() {
        discoveryTask?.cancel()
        discoveryTask = Task { [weak self] in
            guard let self else { return }
            await discovery.start()
            let stream = await discovery.hostStream()
            for await discovered in stream {
                await MainActor.run {
                    self.hosts = discovered
                    if self.selectedHost.isEmpty, let first = discovered.first {
                        self.selectedHost = first.host
                        self.applyHostProfile(
                            WLEDHostProfile(resolution: first.resolution, targetFps: first.targetFps),
                            restartIfStreaming: true
                        )
                    } else if let selected = discovered.first(where: {
                        $0.host.caseInsensitiveCompare(self.selectedHost) == .orderedSame
                    }) {
                        if self.selectedHost != selected.host {
                            self.selectedHost = selected.host
                            self.persist()
                        }
                        self.applyHostProfile(
                            WLEDHostProfile(resolution: selected.resolution, targetFps: selected.targetFps),
                            restartIfStreaming: true
                        )
                    } else {
                        self.reconcileSelectedHostIfNeeded(with: discovered)
                    }
                }
            }
        }
    }

    private func ensureScreenPermission() -> Bool {
        var granted = CGPreflightScreenCaptureAccess()
        if !granted {
            granted = CGRequestScreenCaptureAccess()
        }
        if granted {
            return true
        }
        let alert = NSAlert()
        alert.messageText = "Screen Recording Required"
        alert.informativeText = "Grant Screen Recording for WledCast and relaunch."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        return false
    }

    private func persist() {
        defaults.set(selectedHost, forKey: "lastHost")
        defaults.set(aspectLock, forKey: "aspectLock")
        defaults.set(captureMode.rawValue, forKey: "captureMode")
        defaults.set(selectedVideo?.path, forKey: "selectedVideoPath")
        defaults.set(loopVideo, forKey: "loopVideo")
        defaults.set(overlayMosaicEnabled, forKey: "overlayMosaicEnabled")
        defaults.set(audioVolume, forKey: "audioVolume")
        defaults.set(audioMuted, forKey: "audioMuted")
        if let resolution = outputResolution, let data = try? JSONEncoder().encode(resolution) {
            defaults.set(data, forKey: "outputResolution")
        }
        defaults.set(targetFps, forKey: "targetFps")
        if let filterData = try? JSONEncoder().encode(filters) {
            defaults.set(filterData, forKey: "filters")
        }
        defaults.set(flickerFighter, forKey: "flickerFighter")
        if let boxData = try? JSONEncoder().encode(captureBox) {
            defaults.set(boxData, forKey: "captureBox")
        }
    }

    private func restore() {
        selectedHost = defaults.string(forKey: "lastHost") ?? ""
        aspectLock = defaults.object(forKey: "aspectLock") as? Bool ?? true
        if let modeRaw = defaults.string(forKey: "captureMode"),
           let mode = CaptureMode(rawValue: modeRaw) {
            captureMode = mode
        } else {
            captureMode = .region
        }
        if let resData = defaults.data(forKey: "outputResolution"),
           let decoded = try? JSONDecoder().decode(OutputResolution.self, from: resData) {
            outputResolution = decoded
        }
        if defaults.object(forKey: "targetFps") != nil {
            targetFps = defaults.integer(forKey: "targetFps")
            fps = targetFps > 0 ? targetFps : WLEDHost.defaultFps
        }
        if let filterData = defaults.data(forKey: "filters"),
           let decodedFilters = try? JSONDecoder().decode(FilterConfig.self, from: filterData) {
            filters = decodedFilters
        }
        flickerFighter = min(1, max(0, defaults.double(forKey: "flickerFighter")))
        if let boxData = defaults.data(forKey: "captureBox"),
           let decodedBox = try? JSONDecoder().decode(CaptureBox.self, from: boxData) {
            captureBox = decodedBox
        }
        loopVideo = defaults.object(forKey: "loopVideo") as? Bool ?? true
        overlayMosaicEnabled = defaults.object(forKey: "overlayMosaicEnabled") as? Bool ?? true
        audioVolume = min(1, max(0, defaults.object(forKey: "audioVolume") as? Double ?? 1.0))
        audioMuted = defaults.object(forKey: "audioMuted") as? Bool ?? false
        if let path = defaults.string(forKey: "selectedVideoPath"), !path.isEmpty {
            selectedVideo = URL(fileURLWithPath: path)
        }
    }

    private func applyVideoSettings(for url: URL?) {
        guard let url else {
            videoCropBox = .full
            loopRange = .full
            overlay?.setVideoCrop(.full)
            return
        }
        let settings = videoSettingsStore.settings(for: url)
        videoCropBox = settings.crop
        loopRange = settings.loopRange.clamped()
        overlay?.setVideoCrop(videoCropBox)
    }

    private func saveCurrentVideoSettings() {
        guard let selectedVideo else { return }
        videoSettingsStore.save(
            VideoSettings(crop: videoCropBox, loopRange: loopRange.clamped()),
            for: selectedVideo
        )
    }

    private func migrateLegacyVideoSettings() {
        guard let selectedVideo else { return }
        var settings = videoSettingsStore.settings(for: selectedVideo)
        var migrated = false

        if let cropData = defaults.data(forKey: "videoCropBox"),
           let crop = try? JSONDecoder().decode(VideoCropBox.self, from: cropData) {
            settings.crop = crop
            migrated = true
            defaults.removeObject(forKey: "videoCropBox")
        }
        if let loopData = defaults.data(forKey: "loopRange"),
           let loop = try? JSONDecoder().decode(LoopRange.self, from: loopData) {
            settings.loopRange = loop.clamped()
            migrated = true
            defaults.removeObject(forKey: "loopRange")
        }
        guard migrated else { return }
        videoSettingsStore.save(settings, for: selectedVideo)
    }

    private func videoDirectoryURL() -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Videos")
    }

    private func resolvedVideoDirectoryURL() -> URL {
        let fm = FileManager.default
        let cwdVideos = videoDirectoryURL()
        if directoryContainsVideos(cwdVideos) { return cwdVideos }

        let bundleDir = Bundle.main.bundleURL.deletingLastPathComponent()
        let siblingVideos = bundleDir.appendingPathComponent("Videos")
        if directoryContainsVideos(siblingVideos) { return siblingVideos }

        let parentVideos = bundleDir.deletingLastPathComponent().appendingPathComponent("Videos")
        if directoryContainsVideos(parentVideos) { return parentVideos }
        if fm.fileExists(atPath: parentVideos.path) { return parentVideos }
        if fm.fileExists(atPath: siblingVideos.path) { return siblingVideos }
        return cwdVideos
    }

    private func resolvedFetchScriptURL() -> URL {
        let fm = FileManager.default
        let cwdScript = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Scripts/fetch_video.sh")
        if fm.isExecutableFile(atPath: cwdScript.path) { return cwdScript }

        let bundleDir = Bundle.main.bundleURL.deletingLastPathComponent()
        let siblingScript = bundleDir.appendingPathComponent("Scripts/fetch_video.sh")
        if fm.isExecutableFile(atPath: siblingScript.path) { return siblingScript }

        let resourcesScript = bundleDir.appendingPathComponent("Resources/Scripts/fetch_video.sh")
        if fm.isExecutableFile(atPath: resourcesScript.path) { return resourcesScript }

        let parentScript = bundleDir.deletingLastPathComponent().appendingPathComponent("Scripts/fetch_video.sh")
        if fm.isExecutableFile(atPath: parentScript.path) { return parentScript }
        return cwdScript
    }

    private func directoryContainsVideos(_ directory: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return false }
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return false }
        return items.contains { $0.pathExtension.lowercased() == "mp4" }
    }

    private func syncOverlayVisualizationSettings() {
        overlay?.mosaicEnabled = overlayMosaicEnabled
        mosaicPreviewGate.isEnabled = overlayMosaicEnabled && isOverlayVisible
        videoPreviewGate.isEnabled = isOverlayVisible
    }

    private func syncPreviewGates() {
        let interval = 1.0 / Double(max(1, fps))
        mosaicPreviewGate.setInterval(interval)
        videoPreviewGate.setInterval(interval)
    }

    private func syncAgentSession() {
        PerfLog.syncSession(agentSessionFields())
    }

    private func agentSessionFields() -> [String: String] {
        var fields: [String: String] = [
            "mode": captureMode == .region ? "region" : "video",
            "target_fps": "\(fps)",
            "host": selectedHost,
            "mosaic": overlayMosaicEnabled ? "1" : "0",
            "overlay_visible": isOverlayVisible ? "1" : "0",
        ]
        if let resolution = outputResolution {
            fields["output"] = "\(resolution.width)x\(resolution.height)"
        }
        if captureMode == .region {
            fields["capture_box"] = "\(captureBox.width)x\(captureBox.height)"
        } else if let selectedVideo {
            fields["video"] = selectedVideo.lastPathComponent
        }
        return fields
    }

    func handleAgent(_ request: AgentControlRequest) -> AgentControlResponse {
        switch request.cmd {
        case "status":
            return .success(agentStatus())
        case "overlay.show":
            showOverlay()
            return .success(agentStatus())
        case "overlay.hide":
            hideOverlay()
            return .success(agentStatus())
        case "mosaic.on":
            setOverlayMosaicEnabled(true)
            return .success(agentStatus())
        case "mosaic.off":
            setOverlayMosaicEnabled(false)
            return .success(agentStatus())
        case "stream.start":
            guard canStartStreaming else { return .failure("cannot start stream") }
            if !isStreaming { startStreaming() }
            return .success(agentStatus())
        case "stream.stop":
            if isStreaming { stopStreaming() }
            return .success(agentStatus())
        case "fps.set":
            guard let value = request.value, value > 0 else { return .failure("missing fps value") }
            targetFps = value
            applyEffectiveFps(value)
            persist()
            if !isStreaming { syncAgentSession() }
            return .success(agentStatus())
        default:
            return .failure("unknown cmd: \(request.cmd)")
        }
    }

    private func agentStatus() -> [String: String] {
        var status = agentSessionFields()
        status["streaming"] = isStreaming ? "1" : "0"
        status["sender"] = "\(senderState)"
        status["control_socket"] = LogPaths.controlSocket.path
        status["agent_json"] = LogPaths.agentSnapshot.path
        return status
    }

    private func updatePreview(_ frame: RGBFrame) {
        guard overlayMosaicEnabled, isOverlayVisible else { return }
        guard let image = makePreviewCGImage(frame) else { return }
        lastMosaicImage = image
        overlay?.mosaicHolder.set(image)
    }

    private func startAudioPlayer(url: URL, outputFps: Int, sourceFps: Float) {
        audioPlayer?.stop()
        audioPlayer = nil
        do {
            audioPlayer = try VideoAudioPlayer(
                url: url,
                loop: loopVideo,
                loopRange: loopRange,
                volume: Float(audioVolume),
                muted: audioMuted,
                sourceFps: sourceFps,
                outputFps: outputFps
            )
        } catch {
            audioPlayer = nil
        }
    }

    private func stopVideoPreview() {
        videoPreviewSource?.stop()
        videoPreviewSource = nil
    }

    private func refreshVideoPreviewIfNeeded() {
        guard captureMode == .video else {
            stopVideoPreview()
            return
        }
        guard isStreaming == false else {
            stopVideoPreview()
            return
        }
        guard overlay?.window?.isVisible == true else {
            stopVideoPreview()
            return
        }
        guard let selectedVideo else {
            stopVideoPreview()
            return
        }

        stopVideoPreview()
        do {
            let sourceFps = streamingSourceFps > 1 ? streamingSourceFps : VideoFrameSource.loadSourceFps(url: selectedVideo)
            streamingSourceFps = sourceFps
            let playbackRate = VideoAudioPlayer.playbackRate(sourceFps: sourceFps, outputFps: fps)
            let preview = try VideoFrameSource(
                url: selectedVideo,
                fps: fps,
                crop: videoCropBox,
                loop: loopVideo,
                loopRange: loopRange,
                decodeTarget: outputResolution
            )
            preview.setPlaybackRate(playbackRate)
            preview.shouldEmitPreview = { [weak self] in
                guard let self else { return false }
                return self.isOverlayVisible && self.videoPreviewGate.shouldEmit()
            }
            preview.onPreviewBuffer = { [weak self] buffer in
                guard let self else { return }
                PerfLog.recordHudPreview()
                Task { @MainActor in
                    guard !self.isLoopScrubbing else { return }
                    self.overlay?.setPreviewBuffer(buffer)
                }
            }
            videoPreviewSource = preview
        } catch {
            Log.capture.error("video preview start failed: \(error.localizedDescription)")
        }
    }

    func beginLoopScrub() {
        isLoopScrubbing = true
        overlay?.loopScrubbing = true
        videoPreviewSource?.stop()
        videoPreviewSource = nil
        if isStreaming, captureMode == .video {
            audioPlayer?.pauseForScrub()
        } else {
            videoSource?.stop()
            videoSource = nil
        }
        guard let selectedVideo else { return }
        if scrubAssetURL != selectedVideo {
            let asset = AVAsset(url: selectedVideo)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)
            generator.maximumSize = CGSize(width: 720, height: 720)
            scrubGenerator = generator
            scrubAssetURL = selectedVideo
            scrubAssetDuration = .zero
            Task { [weak self] in
                let duration = (try? await asset.load(.duration)) ?? .zero
                await MainActor.run {
                    guard let self else { return }
                    self.scrubAssetDuration = duration
                }
            }
        }
    }

    func scrubLoopRange(handle: LoopScrubHandle, ratio: Double) {
        guard let generator = scrubGenerator else { return }
        let totalSec = CMTimeGetSeconds(scrubAssetDuration)
        guard totalSec.isFinite, totalSec > 0 else { return }
        let clamped = max(0, min(1, ratio))
        let seekSec: Double
        switch handle {
        case .start:
            seekSec = totalSec * clamped
        case .end:
            let endSec = totalSec * clamped
            let floorSec = totalSec * loopRange.start
            seekSec = max(floorSec, endSec - 2.0)
        }
        let time = CMTime(seconds: seekSec, preferredTimescale: 600)
        generator.generateCGImageAsynchronously(for: time) { [weak self] cgImage, _, _ in
            guard let self, let cgImage else { return }
            let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            Task { @MainActor in
                guard self.isLoopScrubbing else { return }
                self.overlay?.setPreviewImage(image)
            }
        }
    }

    func commitLoopRange(_ range: LoopRange) {
        isLoopScrubbing = false
        overlay?.loopScrubbing = false
        let clamped = range.clamped()
        let changed = loopRange != clamped
        loopRange = clamped
        saveCurrentVideoSettings()
        if isStreaming, captureMode == .video {
            videoSource?.updateLoopRange(clamped)
            audioPlayer?.updateLoopRange(clamped)
        } else if changed || captureMode == .video {
            refreshVideoPreviewIfNeeded()
        }
    }

    private func makePreviewCGImage(_ frame: RGBFrame) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(frame.pixels) as CFData) else { return nil }
        return CGImage(
            width: frame.width,
            height: frame.height,
            bitsPerComponent: 8,
            bitsPerPixel: 24,
            bytesPerRow: frame.width * 3,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}

private final class PreviewGate: @unchecked Sendable {
    private let lock = NSLock()
    private var interval: CFAbsoluteTime = 1.0 / 28.0
    private var lastAt: CFAbsoluteTime = 0
    var isEnabled = true

    func setInterval(_ value: CFAbsoluteTime) {
        lock.lock()
        interval = max(1.0 / 120.0, value)
        lock.unlock()
    }

    func shouldEmit() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isEnabled else { return false }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastAt >= interval else { return false }
        lastAt = now
        return true
    }
}
