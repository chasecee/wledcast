import Foundation

public struct VideoSettings: Codable, Equatable, Sendable {
    public var crop: VideoCropBox
    public var loopRange: LoopRange

    public init(crop: VideoCropBox = .full, loopRange: LoopRange = .full) {
        self.crop = crop
        self.loopRange = loopRange.clamped()
    }
}

public enum VideoKey {
    public static func from(url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        if let id = youtubeID(in: stem) {
            return id
        }
        return stem
    }

    public static func youtubeID(in filename: String) -> String? {
        guard let match = filename.range(of: #"[A-Za-z0-9_-]{11}$"#, options: .regularExpression) else {
            return nil
        }
        let id = String(filename[match])
        guard id.count == 11 else { return nil }
        return id
    }
}

public final class VideoSettingsStore: @unchecked Sendable {
    private var entries: [String: VideoSettings] = [:]
    private let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        load()
    }

    public func settings(for url: URL) -> VideoSettings {
        lock.lock()
        defer { lock.unlock() }
        return entries[VideoKey.from(url: url)] ?? VideoSettings()
    }

    public func save(_ settings: VideoSettings, for url: URL) {
        lock.lock()
        entries[VideoKey.from(url: url)] = settings
        lock.unlock()
        persist()
    }

    public func prune(keeping urls: [URL]) {
        let keys = Set(urls.map { VideoKey.from(url: $0) })
        lock.lock()
        entries = entries.filter { keys.contains($0.key) }
        lock.unlock()
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: VideoSettings].self, from: data) else {
            return
        }
        lock.lock()
        entries = decoded
        lock.unlock()
    }

    private func persist() {
        lock.lock()
        let snapshot = entries
        lock.unlock()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("WledCast", isDirectory: true)
            .appendingPathComponent("video-settings.json")
    }
}
