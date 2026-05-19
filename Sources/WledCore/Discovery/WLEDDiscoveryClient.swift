import Foundation
import Network

public protocol HTTPClient: Sendable {
    func get(url: URL) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionHTTPClient: HTTPClient {
    public init() {}

    public func get(url: URL) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "HTTPClient", code: 1)
        }
        return (data, http)
    }
}

public actor WLEDDiscoveryClient {
    private let httpClient: HTTPClient
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "wledcast.discovery.browser")
    private var hostCandidates = Set<String>()
    private var verifiedHosts: [String: OutputResolution] = [:]
    private var continuation: AsyncStream<[WLEDHost]>.Continuation?

    public init(httpClient: HTTPClient = URLSessionHTTPClient()) {
        self.httpClient = httpClient
    }

    public func fetchMatrixResolution(host: String) async throws -> OutputResolution {
        guard let url = infoURL(for: host) else {
            throw NSError(domain: "WLEDDiscoveryClient", code: 400)
        }
        let (data, response) = try await httpClient.get(url: url)
        guard response.statusCode == 200 else {
            throw NSError(domain: "WLEDDiscoveryClient", code: response.statusCode)
        }
        return try WLEDInfoParser.matrixResolution(from: data)
    }

    public func discoverHosts(timeout: TimeInterval = 3) async -> [String] {
        let stream = hostStream()
        start()
        return await withTaskGroup(of: [String].self) { group in
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return []
            }
            group.addTask {
                for await hosts in stream {
                    return hosts.map(\.host)
                }
                return []
            }
            let first = await group.next() ?? []
            group.cancelAll()
            return first.sorted()
        }
    }

    public func hostStream() -> AsyncStream<[WLEDHost]> {
        AsyncStream { continuation in
            self.continuation = continuation
            continuation.yield(self.snapshotHosts())
            continuation.onTermination = { _ in
                Task { await self.clearContinuation() }
            }
        }
    }

    public func start() {
        if browser != nil {
            return
        }
        let params = NWParameters.tcp
        let newBrowser = NWBrowser(for: .bonjour(type: "_wled._tcp", domain: "local"), using: params)
        newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { await self?.ingest(results: results) }
        }
        newBrowser.stateUpdateHandler = { state in
            Log.discovery.info("browser state \(String(describing: state))")
        }
        newBrowser.start(queue: queue)
        browser = newBrowser
    }

    public func verify(host: String) async {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        hostCandidates.insert(trimmed)
        await probeNewHosts([trimmed])
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }

    private func ingest(results: Set<NWBrowser.Result>) async {
        var newHosts = Set<String>()
        for result in results {
            switch result.endpoint {
            case let .service(name: name, type: _, domain: domain, interface: _):
                if domain == "local" || domain == "local." {
                    let candidate = "\(name).local"
                    if hostCandidates.insert(candidate).inserted {
                        newHosts.insert(candidate)
                    }
                }
            case let .hostPort(host, _):
                let normalized = host.debugDescription.replacingOccurrences(of: "\"", with: "")
                if hostCandidates.insert(normalized).inserted {
                    newHosts.insert(normalized)
                }
            default:
                break
            }
        }
        guard !newHosts.isEmpty else { return }
        let list = newHosts.sorted().joined(separator: ", ")
        Log.discovery.info("bonjour candidates \(list)")
        await probeNewHosts(newHosts)
    }

    private func probeNewHosts(_ hosts: Set<String>) async {
        await withTaskGroup(of: (String, OutputResolution?).self) { group in
            for host in hosts {
                group.addTask { [httpClient] in
                    guard let url = Self.infoURL(for: host) else {
                        return (host, nil)
                    }
                    do {
                        let (data, response) = try await httpClient.get(url: url)
                        guard response.statusCode == 200 else {
                            Log.discovery.warning("probe \(host) http \(response.statusCode)")
                            return (host, nil)
                        }
                        let resolution = try WLEDInfoParser.matrixResolution(from: data)
                        return (host, resolution)
                    } catch {
                        Log.discovery.warning("probe \(host) failed: \(error.localizedDescription)")
                        return (host, nil)
                    }
                }
            }

            while let result = await group.next() {
                if let resolution = result.1 {
                    let previous = verifiedHosts[result.0]
                    verifiedHosts[result.0] = resolution
                    if previous != resolution {
                        Log.discovery.notice("verified \(result.0) \(resolution.width)x\(resolution.height)")
                    }
                }
            }
        }
        continuation?.yield(snapshotHosts())
    }

    private func snapshotHosts() -> [WLEDHost] {
        verifiedHosts
            .map { WLEDHost(host: $0.key, resolution: $0.value) }
            .sorted(by: { $0.host < $1.host })
    }

    private func clearContinuation() {
        continuation = nil
    }

    private static func infoURL(for host: String) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        components.port = 80
        components.path = "/json/info"
        return components.url
    }

    private func infoURL(for host: String) -> URL? {
        Self.infoURL(for: host)
    }
}
