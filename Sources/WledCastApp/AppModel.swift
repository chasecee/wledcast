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
    @Published var fps: Int = 30
    @Published var aspectLock = true
    @Published var isStreaming = false
    @Published var senderState: DDPSenderState = .stopped

    private let discovery = WLEDDiscoveryClient()
    private var discoveryTask: Task<Void, Never>?
    private var session: SessionController?
    private var sender: DDPSender?
    private var source: DisplayFrameSource?
    private var videoSource: VideoFrameSource?
    private var videoPreviewSource: VideoFrameSource?
    private var overlay: OverlayWindowController?
    private var boxRef: CaptureBoxRef?
    private var lastMosaicImage: NSImage?
    private var lastPreviewUpdate: Date = .distantPast
    private let previewMinInterval: TimeInterval = 0.1
    private var scrubGenerator: AVAssetImageGenerator?
    private var scrubAssetURL: URL?
    private var scrubAssetDuration: CMTime = .zero

    private let defaults = UserDefaults.standard
    private let youtubeDownloader = YouTubeDownloader()
    private var fetchTask: Task<Void, Never>?

    init() {
        restore()
        refreshVideoLibrary()
        startDiscovery()
        if !selectedHost.isEmpty {
            refreshSelectedHostResolution()
        }
        Task { @MainActor [weak self] in
            self?.autoStart()
        }
    }

    private func autoStart() {
        if !isOverlayVisible {
            toggleOverlay()
        }
        if !isStreaming, canStartStreaming, isSelectedHostConnected {
            startStreaming()
        }
    }

    private var isOverlayVisible: Bool {
        overlay?.window?.isVisible == true
    }

    private var canStartStreaming: Bool {
        guard !selectedHost.isEmpty, outputResolution != nil else { return false }
        if captureMode == .video {
            return selectedVideo != nil
        }
        return true
    }

    private var isSelectedHostConnected: Bool {
        hosts.contains { $0.host == selectedHost }
    }

    private func refreshSelectedHostResolution() {
        let host = selectedHost
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let resolution = try await self.discovery.fetchMatrixResolution(host: host)
                guard self.selectedHost == host else { return }
                await self.discovery.inject(host: host, resolution: resolution)
                let previous = self.outputResolution
                if previous != resolution {
                    self.outputResolution = resolution
                    self.overlay?.outputResolution = resolution
                    self.persist()
                    if self.isStreaming {
                        self.restartStreaming()
                    } else {
                        self.autoStart()
                    }
                } else {
                    self.autoStart()
                }
            } catch {
                Log.app.warning("failed to fetch matrix for \(host): \(error.localizedDescription)")
            }
        }
    }

    func quit() {
        stopStreaming()
        NSApp.terminate(nil)
    }

    func setHost(_ host: String) {
        let hostChanged = host != selectedHost
        selectedHost = host
        if let info = hosts.first(where: { $0.host == host }) {
            outputResolution = info.resolution
            overlay?.outputResolution = info.resolution
        } else {
            outputResolution = nil
        }
        persist()
        guard hostChanged else { return }
        if isStreaming {
            restartStreaming()
        } else {
            autoStart()
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

    func setFPS(_ value: Int) {
        fps = max(1, value)
        persist()
        if captureMode == .video {
            videoSource?.setOutputFps(fps)
            videoPreviewSource?.setOutputFps(fps)
        } else if isStreaming {
            restartStreaming()
        }
    }

    func setAspectLock(_ value: Bool) {
        aspectLock = value
        overlay?.aspectLock = value
        persist()
    }

    func setOverlayMosaicEnabled(_ value: Bool) {
        overlayMosaicEnabled = value
        if value, let lastMosaicImage {
            overlay?.mosaicImage = lastMosaicImage
        }
        syncOverlayVisualizationSettings()
        persist()
    }

    func setSelectedVideo(_ url: URL?) {
        selectedVideo = url
        scrubGenerator = nil
        scrubAssetURL = nil
        scrubAssetDuration = .zero
        loopRange = .full
        persist()
        refreshVideoPreviewIfNeeded()
        if isStreaming, captureMode == .video {
            restartStreaming()
        }
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
                self.persist()
            }
        }
        overlay = controller
        syncOverlayVisualizationSettings()
        return controller
    }

    func toggleOverlay() {
        let controller = ensureOverlay()
        if controller.window?.isVisible == true {
            controller.hide()
            stopVideoPreview()
        } else {
            controller.show()
            refreshVideoPreviewIfNeeded()
        }
    }

    func startStreaming() {
        guard !isStreaming else { return }
        guard !selectedHost.isEmpty else { return }
        guard let resolution = outputResolution else { return }
        if captureMode == .region, !ensureScreenPermission() { return }
        ensureOverlayVisible()

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
            controller.onFrameProcessed = { [weak self] frame in
                Task { @MainActor in self?.updatePreview(frame) }
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
                let videoSource = try VideoFrameSource(
                    url: selectedVideo,
                    fps: fps,
                    crop: videoCropBox,
                    loop: loopVideo,
                    loopRange: loopRange
                )
                videoSource.onFrameBGRA = { [weak controller] buffer in
                    controller?.process(bgra: buffer)
                }
                videoSource.onPreviewBuffer = { [weak self] buffer in
                    Task { @MainActor in
                        self?.overlay?.setPreviewBuffer(buffer)
                    }
                }
                stopVideoPreview()
                self.videoSource = videoSource
                source = nil
            case .region:
                stopVideoPreview()
                startScreenCaptureStream(resolution: resolution, controller: controller)
            }
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
        session?.blackout()
        source?.stop()
        source = nil
        videoSource?.stop()
        videoSource = nil
        boxRef = nil
        session?.stop()
        session = nil
        sender?.stop()
        sender = nil
        isStreaming = false
        overlay?.mosaicImage = nil
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
                    let previous = self.outputResolution
                    if self.selectedHost.isEmpty, let first = discovered.first {
                        self.selectedHost = first.host
                        self.outputResolution = first.resolution
                    } else if let selected = discovered.first(where: { $0.host == self.selectedHost }) {
                        self.outputResolution = selected.resolution
                    }
                    if let resolution = self.outputResolution {
                        self.overlay?.outputResolution = resolution
                    }
                    self.persist()
                    if self.isStreaming, self.outputResolution != previous {
                        self.restartStreaming()
                    } else {
                        self.autoStart()
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
        defaults.set(fps, forKey: "fps")
        defaults.set(aspectLock, forKey: "aspectLock")
        defaults.set(captureMode.rawValue, forKey: "captureMode")
        defaults.set(selectedVideo?.path, forKey: "selectedVideoPath")
        defaults.set(loopVideo, forKey: "loopVideo")
        defaults.set(overlayMosaicEnabled, forKey: "overlayMosaicEnabled")
        if let loopData = try? JSONEncoder().encode(loopRange) {
            defaults.set(loopData, forKey: "loopRange")
        }
        if let resolution = outputResolution, let data = try? JSONEncoder().encode(resolution) {
            defaults.set(data, forKey: "outputResolution")
        }
        if let filterData = try? JSONEncoder().encode(filters) {
            defaults.set(filterData, forKey: "filters")
        }
        defaults.set(flickerFighter, forKey: "flickerFighter")
        if let boxData = try? JSONEncoder().encode(captureBox) {
            defaults.set(boxData, forKey: "captureBox")
        }
        if let cropData = try? JSONEncoder().encode(videoCropBox) {
            defaults.set(cropData, forKey: "videoCropBox")
        }
    }

    private func restore() {
        selectedHost = defaults.string(forKey: "lastHost") ?? ""
        fps = max(1, defaults.integer(forKey: "fps"))
        if fps == 0 { fps = 30 }
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
        if let filterData = defaults.data(forKey: "filters"),
           let decodedFilters = try? JSONDecoder().decode(FilterConfig.self, from: filterData) {
            filters = decodedFilters
        }
        flickerFighter = min(1, max(0, defaults.double(forKey: "flickerFighter")))
        if let boxData = defaults.data(forKey: "captureBox"),
           let decodedBox = try? JSONDecoder().decode(CaptureBox.self, from: boxData) {
            captureBox = decodedBox
        }
        if let cropData = defaults.data(forKey: "videoCropBox"),
           let decodedCrop = try? JSONDecoder().decode(VideoCropBox.self, from: cropData) {
            videoCropBox = decodedCrop
        }
        loopVideo = defaults.object(forKey: "loopVideo") as? Bool ?? true
        overlayMosaicEnabled = defaults.object(forKey: "overlayMosaicEnabled") as? Bool ?? true
        if let path = defaults.string(forKey: "selectedVideoPath"), !path.isEmpty {
            selectedVideo = URL(fileURLWithPath: path)
        }
        if let loopData = defaults.data(forKey: "loopRange"),
           let decodedLoop = try? JSONDecoder().decode(LoopRange.self, from: loopData) {
            loopRange = decodedLoop.clamped()
        }
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

    private func updatePreview(_ frame: RGBFrame) {
        let now = Date()
        guard now.timeIntervalSince(lastPreviewUpdate) >= previewMinInterval else { return }
        lastPreviewUpdate = now
        let image = makePreviewImage(frame)
        lastMosaicImage = image
        overlay?.mosaicImage = image
    }

    private func syncOverlayVisualizationSettings() {
        overlay?.mosaicEnabled = overlayMosaicEnabled
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
            let preview = try VideoFrameSource(
                url: selectedVideo,
                fps: fps,
                crop: videoCropBox,
                loop: loopVideo,
                loopRange: loopRange
            )
            preview.onPreviewBuffer = { [weak self] buffer in
                Task { @MainActor in
                    self?.overlay?.setPreviewBuffer(buffer)
                }
            }
            videoPreviewSource = preview
        } catch {
            Log.capture.error("video preview start failed: \(error.localizedDescription)")
        }
    }

    func beginLoopScrub() {
        videoPreviewSource?.stop()
        videoPreviewSource = nil
        videoSource?.stop()
        videoSource = nil
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

    func scrubLoopRange(toRatio ratio: Double) {
        guard let generator = scrubGenerator else { return }
        let totalSec = CMTimeGetSeconds(scrubAssetDuration)
        guard totalSec.isFinite, totalSec > 0 else { return }
        let clamped = max(0, min(1, ratio))
        let time = CMTime(seconds: totalSec * clamped, preferredTimescale: 600)
        generator.generateCGImageAsynchronously(for: time) { [weak self] cgImage, _, _ in
            guard let self, let cgImage else { return }
            let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            Task { @MainActor in
                self.overlay?.setPreviewImage(image)
            }
        }
    }

    func commitLoopRange(_ range: LoopRange) {
        let clamped = range.clamped()
        let changed = loopRange != clamped
        loopRange = clamped
        persist()
        if isStreaming, captureMode == .video {
            restartStreaming()
        } else if changed || captureMode == .video {
            refreshVideoPreviewIfNeeded()
        }
    }

    private func makePreviewImage(_ frame: RGBFrame) -> NSImage? {
        guard let provider = CGDataProvider(data: Data(frame.pixels) as CFData) else { return nil }
        guard let cgImage = CGImage(
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
        ) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: frame.width, height: frame.height))
    }
}
