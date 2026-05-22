import Foundation

public struct AgentControlRequest: Codable, Sendable {
    public var cmd: String
    public var value: Int?
    public var seconds: Double?

    public init(cmd: String, value: Int? = nil, seconds: Double? = nil) {
        self.cmd = cmd
        self.value = value
        self.seconds = seconds
    }
}

public struct AgentControlResponse: Codable, Sendable {
    public var ok: Bool
    public var error: String?
    public var data: [String: String]?

    public static func success(_ data: [String: String] = [:]) -> AgentControlResponse {
        AgentControlResponse(ok: true, error: nil, data: data.isEmpty ? nil : data)
    }

    public static func failure(_ message: String) -> AgentControlResponse {
        AgentControlResponse(ok: false, error: message, data: nil)
    }
}

public final class AgentControlClient: Sendable {
    public init() {}

    public func send(_ request: AgentControlRequest, socketPath: URL = LogPaths.controlSocket) throws -> AgentControlResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "AgentControl", code: 1) }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = socketPath.path
        guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw NSError(domain: "AgentControl", code: 2)
        }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { cstr in
                strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), cstr, 103)
            }
        }
        let len = socklen_t(MemoryLayout.size(ofValue: addr))
        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, len)
            }
        }
        guard connectResult == 0 else {
            throw NSError(domain: "AgentControl", code: 3, userInfo: [NSLocalizedDescriptionKey: "connect failed: is WledCast running?"])
        }

        let encoder = JSONEncoder()
        var payload = try encoder.encode(request)
        payload.append(0x0A)
        guard write(fd, payload.withUnsafeBytes { $0.baseAddress! }, payload.count) == payload.count else {
            throw NSError(domain: "AgentControl", code: 4)
        }

        shutdown(fd, SHUT_WR)
        var responseData = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            responseData.append(contentsOf: chunk.prefix(n))
        }
        guard let newline = responseData.firstIndex(of: 0x0A) else {
            throw NSError(domain: "AgentControl", code: 5)
        }
        return try JSONDecoder().decode(AgentControlResponse.self, from: responseData.prefix(newline))
    }
}

public final class AgentControlServer: @unchecked Sendable {
    public static let shared = AgentControlServer()

    private let queue = DispatchQueue(label: "wledcast.agent.control")
    private var listenFD: Int32 = -1
    private var handler: (@Sendable (AgentControlRequest) async -> AgentControlResponse)?

    private init() {}

    public func start(handler: @escaping @Sendable (AgentControlRequest) async -> AgentControlResponse) {
        self.handler = handler
        queue.async { [weak self] in
            self?.runListenLoop()
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.listenFD >= 0 {
                close(self.listenFD)
                self.listenFD = -1
            }
            try? FileManager.default.removeItem(at: LogPaths.controlSocket)
        }
    }

    private func runListenLoop() {
        let path = LogPaths.controlSocket.path
        try? FileManager.default.createDirectory(at: LogPaths.directory, withIntermediateDirectories: true)
        unlink(path)

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { cstr in
                strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), cstr, 103)
            }
        }
        let len = socklen_t(MemoryLayout.size(ofValue: addr))
        let bindResult = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, len)
            }
        }
        guard bindResult == 0, Darwin.listen(listenFD, 8) == 0 else {
            close(listenFD)
            listenFD = -1
            return
        }

        while listenFD >= 0 {
            let client = accept(listenFD, nil, nil)
            if client < 0 { continue }
            serve(clientFD: client)
        }
    }

    private func serve(clientFD: Int32) {
        defer { close(clientFD) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while buffer.count < 65536 {
            let n = read(clientFD, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk.prefix(n))
            if buffer.contains(0x0A) { break }
        }
        guard let newline = buffer.firstIndex(of: 0x0A) else {
            writeResponse(clientFD, .failure("empty request"))
            return
        }
        guard let request = try? JSONDecoder().decode(AgentControlRequest.self, from: buffer.prefix(newline)) else {
            writeResponse(clientFD, .failure("invalid json"))
            return
        }
        guard let handler else {
            writeResponse(clientFD, .failure("no handler"))
            return
        }
        let semaphore = DispatchSemaphore(value: 0)
        var response = AgentControlResponse.failure("timeout")
        Task {
            response = await handler(request)
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 10)
        writeResponse(clientFD, response)
    }

    private func writeResponse(_ fd: Int32, _ response: AgentControlResponse) {
        guard var data = try? JSONEncoder().encode(response) else { return }
        data.append(0x0A)
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress!, data.count) }
    }
}
