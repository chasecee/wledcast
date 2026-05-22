import Foundation

public enum LogPaths {
    public static let directory: URL = {
        if let override = ProcessInfo.processInfo.environment["WLEDCAST_LOG_DIR"] {
            let url = URL(fileURLWithPath: override, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        if let repo = findRepoRoot() {
            let logs = repo.appendingPathComponent("logs", isDirectory: true)
            try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            return logs
        }
        let fallback = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/WledCast", isDirectory: true)
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }()

    public static var perfLog: URL { directory.appendingPathComponent("perf.log") }
    public static var fileLog: URL { directory.appendingPathComponent("wledcast.log") }
    public static var agentSnapshot: URL { directory.appendingPathComponent("agent.json") }
    public static var controlSocket: URL { directory.appendingPathComponent("control.sock") }

    public static func findRepoRoot() -> URL? {
        var candidates: [URL] = [
            Bundle.main.bundleURL.deletingLastPathComponent(),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
        ]
        if let resource = Bundle.main.resourceURL {
            candidates.append(resource.deletingLastPathComponent())
        }
        for start in candidates {
            var dir = start.standardizedFileURL
            for _ in 0..<10 {
                if isRepoRoot(dir) { return dir }
                let parent = dir.deletingLastPathComponent()
                if parent.path == dir.path { break }
                dir = parent
            }
        }
        return nil
    }

    private static func isRepoRoot(_ url: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: url.appendingPathComponent("Package.swift").path)
            || fm.fileExists(atPath: url.appendingPathComponent(".git").path)
    }
}
