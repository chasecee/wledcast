import Foundation
import WledCore

func usage() -> String {
    """
    wledcast-ctl — control a running WledCast instance

    usage:
      wledcast-ctl status
      wledcast-ctl overlay show|hide
      wledcast-ctl mosaic on|off
      wledcast-ctl stream start|stop
      wledcast-ctl fps <n>
      wledcast-ctl perf
      wledcast-ctl wait <seconds>
    """
}

func readPerfSnapshot() -> Data {
    let url = LogPaths.agentSnapshot
    guard let data = try? Data(contentsOf: url) else {
        let err = AgentControlResponse.failure("missing agent.json at \(url.path)")
        return (try? JSONEncoder().encode(err)) ?? Data()
    }
    return data
}

func request(for args: [String]) -> AgentControlRequest? {
    guard let cmd = args.first else { return nil }
    switch cmd {
    case "status":
        return AgentControlRequest(cmd: "status")
    case "overlay":
        guard args.count >= 2 else { return nil }
        switch args[1] {
        case "show": return AgentControlRequest(cmd: "overlay.show")
        case "hide": return AgentControlRequest(cmd: "overlay.hide")
        default: return nil
        }
    case "mosaic":
        guard args.count >= 2 else { return nil }
        switch args[1] {
        case "on": return AgentControlRequest(cmd: "mosaic.on")
        case "off": return AgentControlRequest(cmd: "mosaic.off")
        default: return nil
        }
    case "stream":
        guard args.count >= 2 else { return nil }
        switch args[1] {
        case "start": return AgentControlRequest(cmd: "stream.start")
        case "stop": return AgentControlRequest(cmd: "stream.stop")
        default: return nil
        }
    case "fps":
        guard args.count >= 2, let value = Int(args[1]), value > 0 else { return nil }
        return AgentControlRequest(cmd: "fps.set", value: value)
    case "perf", "wait":
        return nil
    default:
        return nil
    }
}

let args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty else {
    fputs(usage(), stderr)
    exit(1)
}

if args.first == "perf" {
    let data = readPerfSnapshot()
    if var line = String(data: data, encoding: .utf8) {
        while line.last == "\n" { line.removeLast() }
        print(line)
    }
    exit(FileManager.default.fileExists(atPath: LogPaths.agentSnapshot.path) ? 0 : 1)
}

if args.first == "wait" {
    let seconds = args.count >= 2 ? (Double(args[1]) ?? 1) : 1
    Thread.sleep(forTimeInterval: max(0.1, seconds))
    exit(0)
}

guard let req = request(for: args) else {
    fputs(usage(), stderr)
    exit(1)
}

do {
    let response = try AgentControlClient().send(req)
    let data = try JSONEncoder().encode(response)
    print(String(decoding: data, as: UTF8.self))
    exit(response.ok ? 0 : 1)
} catch {
    let response = AgentControlResponse.failure(error.localizedDescription)
    if let data = try? JSONEncoder().encode(response) {
        print(String(decoding: data, as: UTF8.self))
    }
    exit(1)
}
