import SwiftUI
import WledCore

struct MenuBarContent: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(statusText)
                .font(.system(size: 12, weight: .medium))
            Divider()
            Text("WLED Devices")
                .font(.system(size: 11, weight: .semibold))
            if model.hosts.isEmpty {
                Text("No verified hosts")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.hosts) { host in
                    Button {
                        model.setHost(host.host)
                    } label: {
                        HStack {
                            Text(host.host)
                            Spacer()
                            Text("\(host.resolution.width)x\(host.resolution.height)")
                            if model.selectedHost == host.host {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider()
            Button(model.isStreaming ? "Stop Stream" : "Start Stream") {
                if model.isStreaming {
                    model.stopStreaming()
                } else {
                    model.startStreaming()
                }
            }
            Button(model.isWindowVisible ? "Hide Window" : "Show Window") {
                model.toggleOverlay()
            }
            Button("Quit") {
                model.quit()
            }
        }
        .padding(12)
    }

    private var statusText: String {
        let state: String = switch model.senderState {
        case .connecting: "connecting"
        case .ready: "ready"
        case .failed(let message): "failed: \(message)"
        case .stopped: "stopped"
        }
        let host = model.selectedHost.isEmpty ? "no host" : model.selectedHost
        return "\(model.isStreaming ? "Streaming" : "Idle") · \(host) · \(state) · \(model.wledFpsLabel)"
    }
}
