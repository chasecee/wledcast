import Foundation

public enum PerfLog {
    public static var path: URL { LogPaths.perfLog }

    public static func event(_ name: String, _ fields: [String: String] = [:]) {
        var payload = fields
        payload["event"] = name
        Writer.shared.write(payload)
        if name == "stream_start" {
            Metrics.shared.beginSession(fields)
        } else if name == "stream_stop" {
            Metrics.shared.endSession()
        }
    }

    public static func configure(mode: String, output: OutputResolution, fps: Int) {
        Metrics.shared.configure(mode: mode, output: output, fps: fps)
    }

    public static func recordFrame(sourceWidth: Int, sourceHeight: Int, processMs: Double, preview: Bool) {
        Metrics.shared.recordFrame(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            processMs: processMs,
            preview: preview
        )
    }

    public static func noteCapture(
        frameWidth: Int,
        frameHeight: Int,
        sourceRect: CGRect,
        output: OutputResolution,
        streamFps: Double
    ) {
        Metrics.shared.noteCapture(
            frameWidth: frameWidth,
            frameHeight: frameHeight,
            sourceRect: sourceRect,
            output: output,
            streamFps: streamFps
        )
    }

    public static func recordHudPreview() {
        Metrics.shared.recordHudPreview()
    }

    public static func syncSession(_ fields: [String: String]) {
        Metrics.shared.syncSession(fields)
    }
}

private final class Writer: @unchecked Sendable {
    static let shared = Writer()

    let url: URL
    private let lock = NSLock()
    private let formatter = ISO8601DateFormatter()

    private init() {
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        url = LogPaths.perfLog
    }

    func write(_ fields: [String: String]) {
        let ts = formatter.string(from: Date())
        let body = fields
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        let line = "\(ts) \(body)\n"
        guard let data = line.data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {}
    }
}

private struct AgentSnapshot: Codable {
    struct Session: Codable {
        var active: Bool
        var startedAt: String?
        var endedAt: String?
        var mode: String?
        var output: String?
        var targetFps: Int?
        var host: String?
        var mosaic: Bool?
        var overlayVisible: Bool?
        var captureBox: String?
        var video: String?
    }

    struct Window: Codable {
        var at: String
        var mode: String
        var fps: Double
        var targetFps: Int
        var output: String
        var src: String
        var capture: String?
        var captureFps: Double?
        var processAvgMs: Double
        var processMaxMs: Double
        var previewFrames: Int
        var hudPreviewFrames: Int
        var frames: Int
    }

    var updatedAt: String
    var perfLog: String
    var fileLog: String
    var session: Session
    var latestWindow: Window?
    var recentWindows: [Window]
    var hint: String
}

private final class Metrics: @unchecked Sendable {
    static let shared = Metrics()

    private let lock = NSLock()
    private let flushInterval: CFAbsoluteTime = 2
    private let maxRecentWindows = 30
    private var windowStart = CFAbsoluteTimeGetCurrent()
    private var frameCount = 0
    private var previewCount = 0
    private var hudPreviewCount = 0
    private var processSumMs = 0.0
    private var processMaxMs = 0.0
    private var lastSourceWidth = 0
    private var lastSourceHeight = 0
    private var mode = "unknown"
    private var output = OutputResolution(width: 0, height: 0)
    private var targetFps = 0
    private var captureNote: [String: String] = [:]
    private var sessionStartFields: [String: String] = [:]
    private var sessionLiveFields: [String: String] = [:]
    private var sessionActive = false
    private var sessionStartedAt: String?
    private var recentWindows: [AgentSnapshot.Window] = []
    private var latestWindow: AgentSnapshot.Window?
    private let formatter = ISO8601DateFormatter()

    private init() {
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        writeAgentSnapshot(hint: "idle")
    }

    func configure(mode: String, output: OutputResolution, fps: Int) {
        lock.lock()
        self.mode = mode
        self.output = output
        self.targetFps = fps
        resetWindow(locked: true)
        lock.unlock()
    }

    func beginSession(_ fields: [String: String]) {
        lock.lock()
        sessionActive = true
        sessionStartFields = fields
        sessionStartedAt = formatter.string(from: Date())
        recentWindows = []
        latestWindow = nil
        resetWindow(locked: true)
        lock.unlock()
        writeAgentSnapshot(hint: "streaming")
    }

    func endSession() {
        lock.lock()
        flushWindow(locked: true)
        sessionActive = false
        lock.unlock()
        writeAgentSnapshot(hint: hintFromLatest())
    }

    func recordFrame(sourceWidth: Int, sourceHeight: Int, processMs: Double, preview: Bool) {
        lock.lock()
        frameCount += 1
        if preview { previewCount += 1 }
        processSumMs += processMs
        processMaxMs = max(processMaxMs, processMs)
        lastSourceWidth = sourceWidth
        lastSourceHeight = sourceHeight
        flushIfDue(locked: true)
        lock.unlock()
    }

    func recordHudPreview() {
        lock.lock()
        hudPreviewCount += 1
        flushIfDue(locked: true)
        lock.unlock()
    }

    func syncSession(_ fields: [String: String]) {
        lock.lock()
        sessionLiveFields.merge(fields) { _, new in new }
        lock.unlock()
        writeAgentSnapshot(hint: hintFromLatest())
    }

    func noteCapture(
        frameWidth: Int,
        frameHeight: Int,
        sourceRect: CGRect,
        output: OutputResolution,
        streamFps: Double
    ) {
        lock.lock()
        captureNote = [
            "capture": "\(frameWidth)x\(frameHeight)",
            "source_rect": "\(Int(sourceRect.width))x\(Int(sourceRect.height))@\(Int(sourceRect.origin.x)),\(Int(sourceRect.origin.y))",
            "capture_fps": String(format: "%.1f", streamFps),
            "oversample_x": String(max(1, frameWidth / max(1, output.width))),
            "oversample_y": String(max(1, frameHeight / max(1, output.height))),
        ]
        lock.unlock()
    }

    private func flushIfDue(locked: Bool) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - windowStart >= flushInterval else { return }
        flushWindow(locked: locked)
    }

    private func flushWindow(locked: Bool) {
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - windowStart
        guard frameCount > 0 else {
            resetWindow(locked: locked)
            return
        }
        let fps = Double(frameCount) / elapsed
        let avgMs = processSumMs / Double(frameCount)
        var fields: [String: String] = [
            "event": "window",
            "mode": mode,
            "target_fps": "\(targetFps)",
            "fps": String(format: "%.1f", fps),
            "frames": "\(frameCount)",
            "output": "\(output.width)x\(output.height)",
            "src": "\(lastSourceWidth)x\(lastSourceHeight)",
            "process_avg_ms": String(format: "%.3f", avgMs),
            "process_max_ms": String(format: "%.3f", processMaxMs),
            "preview_frames": "\(previewCount)",
            "hud_preview_frames": "\(hudPreviewCount)",
        ]
        fields.merge(captureNote) { _, new in new }
        Writer.shared.write(fields)

        let window = AgentSnapshot.Window(
            at: formatter.string(from: Date()),
            mode: mode,
            fps: fps,
            targetFps: targetFps,
            output: "\(output.width)x\(output.height)",
            src: "\(lastSourceWidth)x\(lastSourceHeight)",
            capture: captureNote["capture"],
            captureFps: Double(captureNote["capture_fps"] ?? ""),
            processAvgMs: avgMs,
            processMaxMs: processMaxMs,
            previewFrames: previewCount,
            hudPreviewFrames: hudPreviewCount,
            frames: frameCount
        )
        latestWindow = window
        recentWindows.append(window)
        if recentWindows.count > maxRecentWindows {
            recentWindows.removeFirst(recentWindows.count - maxRecentWindows)
        }
        resetWindow(locked: locked)
        writeAgentSnapshot(hint: hintFrom(window: window))
    }

    private func hintFromLatest() -> String {
        if let latestWindow { return hintFrom(window: latestWindow) }
        return sessionActive ? "streaming" : "idle"
    }

    private func hintFrom(window: AgentSnapshot.Window) -> String {
        if window.processAvgMs > 2 {
            return "pipeline_hot"
        }
        if window.previewFrames > window.frames / 3 || window.hudPreviewFrames > window.frames / 3 {
            return "preview_overhead"
        }
        if window.mode == "video" {
            let capturePx = pixelCount(window.capture ?? window.src)
            let outputPx = pixelCount(window.output)
            if capturePx > outputPx * 2 {
                return "decode_or_audio_likely"
            }
        }
        if window.mode == "region" {
            let capturePx = pixelCount(window.capture ?? window.src)
            let outputPx = pixelCount(window.output)
            if capturePx > outputPx * 2 {
                return "screencapture_likely"
            }
        }
        if window.processAvgMs < 1 {
            return "pipeline_ok_check_subsystems"
        }
        return "mixed"
    }

    private func pixelCount(_ size: String) -> Int {
        let parts = size.split(separator: "x")
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else { return 0 }
        return w * h
    }

    private func writeAgentSnapshot(hint: String) {
        let live = sessionLiveFields
        let session = AgentSnapshot.Session(
            active: sessionActive,
            startedAt: sessionStartedAt,
            endedAt: sessionActive ? nil : formatter.string(from: Date()),
            mode: live["mode"] ?? sessionStartFields["mode"] ?? mode,
            output: live["output"] ?? sessionStartFields["output"],
            targetFps: (live["target_fps"] ?? sessionStartFields["target_fps"]).flatMap(Int.init),
            host: live["host"] ?? sessionStartFields["host"],
            mosaic: (live["mosaic"] ?? sessionStartFields["mosaic"]) == "1",
            overlayVisible: (live["overlay_visible"] ?? sessionStartFields["overlay_visible"]) == "1",
            captureBox: live["capture_box"] ?? sessionStartFields["capture_box"],
            video: live["video"] ?? sessionStartFields["video"]
        )
        let snapshot = AgentSnapshot(
            updatedAt: formatter.string(from: Date()),
            perfLog: LogPaths.perfLog.path,
            fileLog: LogPaths.fileLog.path,
            session: session,
            latestWindow: latestWindow,
            recentWindows: recentWindows,
            hint: hint
        )
        let url = LogPaths.agentSnapshot
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func resetWindow(locked: Bool) {
        windowStart = CFAbsoluteTimeGetCurrent()
        frameCount = 0
        previewCount = 0
        hudPreviewCount = 0
        processSumMs = 0
        processMaxMs = 0
    }
}
