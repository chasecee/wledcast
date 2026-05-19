import ApplicationServices
import AppKit
import Combine
import CoreGraphics
import Foundation
import WledCore

@MainActor
final class AppModel: ObservableObject {
    @Published var hosts: [WLEDHost] = []
    @Published var selectedHost: String = ""
    @Published var outputResolution = OutputResolution(width: 16, height: 16)
    @Published var filters: FilterConfig = .default
    @Published var captureBox: CaptureBox = .centered(on: NSScreen.main ?? NSScreen.screens.first!)
    @Published var captureMode: CaptureMode = .region
    @Published var fps: Int = 30
    @Published var aspectLock = true
    @Published var isStreaming = false
    @Published var senderState: DDPSenderState = .stopped
    @Published var txPreviewImage: NSImage?
    @Published var txPreviewInfo: String = "No frames yet"
    @Published var captureDiagnostics: String = ""

    private let discovery = WLEDDiscoveryClient()
    private var discoveryTask: Task<Void, Never>?
    private var session: SessionController?
    private var sender: DDPSender?
    private var source: DisplayFrameSource?
    private var overlay: OverlayWindowController?
    private var boxRef: CaptureBoxRef?
    private var lastPreviewUpdate = Date.distantPast

    private let defaults = UserDefaults.standard

    init() {
        restore()
        startDiscovery()
        Task { @MainActor [weak self] in
            self?.autoStart()
        }
    }

    private func autoStart() {
        if overlay?.window?.isVisible != true {
            toggleOverlay()
        }
        if !isStreaming, !selectedHost.isEmpty {
            startStreaming()
        }
    }

    func quit() {
        stopStreaming()
        NSApp.terminate(nil)
    }

    func setHost(_ host: String) {
        selectedHost = host
        if let info = hosts.first(where: { $0.host == host }) {
            outputResolution = info.resolution
        }
        persist()
    }

    func setCaptureMode(_ mode: CaptureMode) {
        captureMode = mode
        persist()
    }

    func setFPS(_ value: Int) {
        fps = max(1, value)
        persist()
    }

    func setAspectLock(_ value: Bool) {
        aspectLock = value
        overlay?.aspectLock = value
        persist()
    }

    func setFilters(_ value: FilterConfig) {
        filters = value
        session?.updateFilters(value)
        persist()
    }

    func toggleOverlay() {
        if overlay == nil {
            let controller = OverlayWindowController(captureBox: captureBox)
            controller.outputResolution = outputResolution
            controller.aspectLock = aspectLock
            controller.onChange = { [weak self] box in
                Task { @MainActor in
                    guard let self else { return }
                    let displayChanged = self.captureBox.displayID != box.displayID
                    self.captureBox = box
                    self.boxRef?.update(box)
                    self.persist()
                    guard self.isStreaming else { return }
                    if displayChanged {
                        self.restartStreaming()
                    } else {
                        self.source?.updateRegion(box: box)
                    }
                }
            }
            overlay = controller
        }
        if overlay?.window?.isVisible == true {
            overlay?.hide()
        } else {
            overlay?.show()
        }
    }

    func startStreaming() {
        if isStreaming {
            return
        }
        guard ensureScreenPermission() else {
            return
        }
        guard !selectedHost.isEmpty else {
            return
        }

        if overlay == nil {
            toggleOverlay()
        }

        let selection = CaptureSelection(
            mode: captureMode,
            displayID: captureMode == .region ? captureBox.displayID : nil
        )
        let ref = CaptureBoxRef(captureBox)
        boxRef = ref
        let frameSource = DisplayFrameSource(
            boxRef: ref,
            outputResolution: outputResolution,
            fps: fps,
            captureSelection: selection
        )
        frameSource.onDiagnostics = { [weak self] diag in
            Task { @MainActor in
                self?.captureDiagnostics = format(diagnostics: diag)
            }
        }
        source = frameSource
        do {
            let newSender = try DDPSender(host: selectedHost)
            newSender.onStateChanged = { [weak self] state in
                Task { @MainActor in
                    self?.senderState = state
                }
            }
            sender = newSender
            let controller = SessionController(
                sender: newSender,
                outputResolution: outputResolution,
                filterConfig: filters
            )
            controller.onFrameProcessed = { [weak self] frame in
                Task { @MainActor in
                    self?.updatePreview(frame)
                }
            }
            frameSource.onFrame = { [weak controller] frame in
                controller?.process(frame: frame)
            }
            session = controller
            isStreaming = true
        } catch {
            senderState = .failed(error.localizedDescription)
        }
    }

    private func restartStreaming() {
        stopStreaming()
        startStreaming()
    }

    func stopStreaming() {
        source?.stop()
        source = nil
        session?.stop()
        session = nil
        sender?.stop()
        sender = nil
        isStreaming = false
        txPreviewInfo = "No frames yet"
        txPreviewImage = nil
        captureDiagnostics = ""
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
                        self.outputResolution = first.resolution
                    } else if let selected = discovered.first(where: { $0.host == self.selectedHost }) {
                        self.outputResolution = selected.resolution
                    }
                    self.persist()
                    self.autoStart()
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
        if let filterData = try? JSONEncoder().encode(filters) {
            defaults.set(filterData, forKey: "filters")
        }
        if let boxData = try? JSONEncoder().encode(captureBox) {
            defaults.set(boxData, forKey: "captureBox")
        }
    }

    private func restore() {
        selectedHost = defaults.string(forKey: "lastHost") ?? ""
        fps = max(1, defaults.integer(forKey: "fps"))
        if fps == 0 {
            fps = 30
        }
        aspectLock = defaults.object(forKey: "aspectLock") as? Bool ?? true
        if let modeRaw = defaults.string(forKey: "captureMode"), let mode = CaptureMode(rawValue: modeRaw) {
            captureMode = mode
        }
        if
            let filterData = defaults.data(forKey: "filters"),
            let decodedFilters = try? JSONDecoder().decode(FilterConfig.self, from: filterData)
        {
            filters = decodedFilters
        }
        if
            let boxData = defaults.data(forKey: "captureBox"),
            let decodedBox = try? JSONDecoder().decode(CaptureBox.self, from: boxData)
        {
            captureBox = decodedBox
        }
    }

    private func updatePreview(_ frame: RGBFrame) {
        let now = Date()
        guard now.timeIntervalSince(lastPreviewUpdate) > 0.15 else { return }
        lastPreviewUpdate = now
        txPreviewInfo = "\(frame.width)x\(frame.height) · \(sampleString(frame))"
        txPreviewImage = makePreviewImage(frame)
    }

    private func sampleString(_ frame: RGBFrame) -> String {
        let count = min(9, frame.pixels.count)
        guard count > 0 else { return "empty" }
        let values = frame.pixels.prefix(count).map { String(format: "%02X", $0) }
        return values.joined(separator: " ")
    }

    private func makePreviewImage(_ frame: RGBFrame) -> NSImage? {
        var rgba = [UInt8](repeating: 255, count: frame.width * frame.height * 4)
        for i in 0..<(frame.width * frame.height) {
            rgba[i * 4] = frame.pixels[i * 3]
            rgba[i * 4 + 1] = frame.pixels[i * 3 + 1]
            rgba[i * 4 + 2] = frame.pixels[i * 3 + 2]
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        guard let cgImage = CGImage(
            width: frame.width,
            height: frame.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: frame.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
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

private func format(diagnostics diag: DisplayFrameSource.Diagnostics) -> String {
    let displayPart = "display \(diag.displayID)"
    let framePart = "frame \(Int(diag.framePixels.width))x\(Int(diag.framePixels.height)) px"
    let srcPart = "src \(Int(diag.sourceRect.minX)),\(Int(diag.sourceRect.minY)) \(Int(diag.sourceRect.width))x\(Int(diag.sourceRect.height)) pt"
    let countPart = "\(diag.deliveredFrames) frames"
    return [displayPart, framePart, srcPart, countPart].joined(separator: "  ·  ")
}
