import Foundation

public final class FileLog: @unchecked Sendable {
    public static let shared = FileLog()

    private let lock = NSLock()
    private let url: URL
    private let maxBytes: UInt64 = 1_048_576
    private let trimToBytes: UInt64 = 524_288
    private let formatter: ISO8601DateFormatter

    private init() {
        self.url = LogPaths.fileLog
        self.formatter = ISO8601DateFormatter()
        self.formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    public var location: URL { url }

    public func append(level: String, category: String, message: String) {
        let line = "\(formatter.string(from: Date())) [\(level)] [\(category)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            let endOffset = try handle.seekToEnd()
            try handle.write(contentsOf: data)
            let newSize = endOffset + UInt64(data.count)
            if newSize > maxBytes {
                try trim(handle: handle, currentSize: newSize)
            }
        } catch {}
    }

    private func trim(handle: FileHandle, currentSize: UInt64) throws {
        let keepFrom = currentSize - trimToBytes
        try handle.seek(toOffset: keepFrom)
        var tail = try handle.readToEnd() ?? Data()
        if let newline = tail.firstIndex(of: 0x0A), newline + 1 < tail.count {
            tail = tail.subdata(in: (newline + 1)..<tail.count)
        }
        try handle.truncate(atOffset: 0)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: tail)
    }
}
