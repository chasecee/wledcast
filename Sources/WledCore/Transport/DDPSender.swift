import Foundation
import Network

public enum DDPSenderState: Equatable, Sendable {
    case connecting
    case ready
    case failed(String)
    case stopped
}

public final class DDPSender: @unchecked Sendable {
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private var packetizer = DDPPacketizer()
    private let queue = DispatchQueue(label: "wledcast.ddp.sender")
    private var connection: NWConnection?
    private var reconnectTask: DispatchWorkItem?
    public var onStateChanged: (@Sendable (DDPSenderState) -> Void)?

    public init(host: String, port: UInt16 = DDPPacketizer.port) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "DDPSender", code: 1)
        }
        self.host = NWEndpoint.Host(host)
        self.port = nwPort
        queue.async { [weak self] in
            self?.connect()
        }
    }

    public func send(frame: RGBFrame) {
        sendRaw(frame.flattenedData())
    }

    public func sendRaw(_ payload: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let connection else {
                self.scheduleReconnect()
                return
            }
            let packets = self.packetizer.packets(for: payload)
            for packet in packets {
                connection.send(content: packet, completion: .contentProcessed { _ in })
            }
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.reconnectTask?.cancel()
            self.reconnectTask = nil
            self.connection?.cancel()
            self.connection = nil
            self.onStateChanged?(.stopped)
        }
    }

    private func connect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        let newConnection = NWConnection(host: host, port: port, using: .udp)
        newConnection.stateUpdateHandler = { [weak self] state in
            self?.handleState(state)
        }
        connection = newConnection
        onStateChanged?(.connecting)
        newConnection.start(queue: queue)
    }

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            onStateChanged?(.ready)
        case .failed(let error):
            onStateChanged?(.failed(error.localizedDescription))
            connection?.cancel()
            connection = nil
            scheduleReconnect()
        case .cancelled:
            if connection != nil {
                connection = nil
                scheduleReconnect()
            }
        default:
            break
        }
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnectTask = nil
            self.connect()
        }
        reconnectTask = work
        queue.asyncAfter(deadline: .now() + 1.2, execute: work)
    }
}
