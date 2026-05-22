import Foundation

public enum YouTubeDownloaderError: Error, Equatable {
    case invalidURL
    case scriptNotFound
    case outputParseFailed
    case scriptFailed(String)
}

extension YouTubeDownloaderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Enter a valid YouTube URL."
        case .scriptNotFound:
            return "Download script not found."
        case .outputParseFailed:
            return "Could not find saved file path."
        case .scriptFailed(let message):
            return message.isEmpty ? "Video fetch failed." : message
        }
    }
}

public actor YouTubeDownloader {
    public init() {}

    public func fetch(url: String, scriptURL: URL) async throws -> URL {
        guard Self.isValidYouTubeURL(url) else {
            throw YouTubeDownloaderError.invalidURL
        }
        guard FileManager.default.isExecutableFile(atPath: scriptURL.path) else {
            throw YouTubeDownloaderError.scriptNotFound
        }

        let output = try await runScript(scriptURL: scriptURL, url: url)
        guard let savedURL = Self.parseSavedPath(from: output) else {
            throw YouTubeDownloaderError.outputParseFailed
        }
        return savedURL
    }

    public static func parseSavedPath(from output: String) -> URL? {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        for line in lines.reversed() {
            guard line.hasPrefix("saved: ") else { continue }
            let payload = String(line.dropFirst("saved: ".count)).trimmingCharacters(in: .whitespaces)
            let path: String
            if let range = payload.range(of: " (", options: .backwards), payload.hasSuffix(")") {
                path = String(payload[..<range.lowerBound])
            } else {
                path = payload
            }
            guard !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return nil
    }

    private static func isValidYouTubeURL(_ input: String) -> Bool {
        guard let components = URLComponents(string: input),
              let host = components.host?.lowercased()
        else {
            return false
        }
        let normalized = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return normalized == "youtu.be" || normalized.hasSuffix("youtube.com")
    }

    private func runScript(scriptURL: URL, url: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [scriptURL.path, url]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            let collector = OutputCollector()

            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                collector.append(chunk)
            }

            process.terminationHandler = { process in
                pipe.fileHandleForReading.readabilityHandler = nil
                let tail = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = collector.finish(tail)
                if process.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: YouTubeDownloaderError.scriptFailed(trimmed))
                }
            }

            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let queue = DispatchQueue(label: "wledcast.youtube.downloader.capture")
    private var outputData = Data()
    private var pending = ""

    func append(_ chunk: Data) {
        queue.sync {
            outputData.append(chunk)
            guard let text = String(data: chunk, encoding: .utf8) else { return }
            pending += text
            let parts = pending.split(separator: "\n", omittingEmptySubsequences: false)
            if parts.count > 1 {
                for line in parts.dropLast() {
                    let value = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty {
                        Log.capture.info(value)
                    }
                }
                pending = String(parts.last ?? "")
            }
        }
    }

    func finish(_ tail: Data) -> String {
        queue.sync {
            if !tail.isEmpty {
                outputData.append(tail)
            }
            let trailing = pending.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trailing.isEmpty {
                Log.capture.info(trailing)
                pending = ""
            }
            return String(decoding: outputData, as: UTF8.self)
        }
    }
}
