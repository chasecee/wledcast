import Foundation
import Network

public protocol HTTPClient: Sendable {
    func get(url: URL) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init(timeout: TimeInterval = 2.0) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.waitsForConnectivity = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        self.session = URLSession(configuration: config)
    }

    public func get(url: URL) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(from: url)
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
    private var verifiedHosts: [String: WLEDHostProfile] = [:]
    private var continuation: AsyncStream<[WLEDHost]>.Continuation?

    public init(httpClient: HTTPClient = URLSessionHTTPClient()) {
        self.httpClient = httpClient
    }

    public func fetchHostProfile(host: String) async throws -> WLEDHostProfile {
        guard let infoURL = Self.infoURL(for: host) else {
            throw NSError(domain: "WLEDDiscoveryClient", code: 400)
        }
        async let infoRequest = httpClient.get(url: infoURL)
        async let cfgData = Self.fetchCfgData(httpClient: httpClient, host: host)
        let (infoData, infoResponse) = try await infoRequest
        guard infoResponse.statusCode == 200 else {
            throw NSError(domain: "WLEDDiscoveryClient", code: infoResponse.statusCode)
        }
        let resolution = try WLEDInfoParser.matrixResolution(from: infoData)
        let cfg = await cfgData
        if cfg == nil {
            Log.discovery.warning("cfg unavailable for \(host), falling back to info/default fps")
        }
        let targetFps = WLEDCfgParser.resolveTargetFps(infoData: infoData, cfgData: cfg)
        return WLEDHostProfile(resolution: resolution, targetFps: targetFps)
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

    public func inject(host: String, profile: WLEDHostProfile) {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        hostCandidates.insert(trimmed)
        let previous = verifiedHosts[trimmed]
        verifiedHosts[trimmed] = profile
        if previous != profile {
            continuation?.yield(snapshotHosts())
        }
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
        await withTaskGroup(of: (String, WLEDHostProfile?).self) { group in
            for host in hosts {
                group.addTask { [httpClient] in
                    guard let infoURL = Self.infoURL(for: host) else {
                        return (host, nil)
                    }
                    do {
                        async let infoRequest = httpClient.get(url: infoURL)
                        async let cfgData = Self.fetchCfgData(httpClient: httpClient, host: host)
                        let (infoData, infoResponse) = try await infoRequest
                        guard infoResponse.statusCode == 200 else {
                            Log.discovery.warning("probe \(host) info http \(infoResponse.statusCode)")
                            return (host, nil)
                        }
                        let resolution = try WLEDInfoParser.matrixResolution(from: infoData)
                        let targetFps = WLEDCfgParser.resolveTargetFps(infoData: infoData, cfgData: await cfgData)
                        return (host, WLEDHostProfile(resolution: resolution, targetFps: targetFps))
                    } catch {
                        Log.discovery.warning("probe \(host) failed: \(error.localizedDescription)")
                        return (host, nil)
                    }
                }
            }

            while let result = await group.next() {
                if let profile = result.1 {
                    let previous = verifiedHosts[result.0]
                    verifiedHosts[result.0] = profile
                    if previous != profile {
                        Log.discovery.notice(
                            "verified \(result.0) \(profile.resolution.width)x\(profile.resolution.height) \(profile.effectiveFps)fps"
                        )
                    }
                }
            }
        }
        continuation?.yield(snapshotHosts())
    }

    private func snapshotHosts() -> [WLEDHost] {
        verifiedHosts
            .map { WLEDHost(host: $0.key, resolution: $0.value.resolution, targetFps: $0.value.targetFps) }
            .sorted(by: { $0.host < $1.host })
    }

    private func clearContinuation() {
        continuation = nil
    }

    private static func fetchCfgData(httpClient: HTTPClient, host: String) async -> Data? {
        for path in ["/cfg.json", "/json/cfg"] {
            guard let url = apiURL(for: host, path: path) else { continue }
            guard let (data, response) = try? await httpClient.get(url: url),
                  response.statusCode == 200 else {
                continue
            }
            return data
        }
        return nil
    }

    private static func infoURL(for host: String) -> URL? {
        apiURL(for: host, path: "/json/info")
    }

    private static func apiURL(for host: String, path: String) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        components.port = 80
        components.path = path
        return components.url
    }
}
