import Foundation
import Darwin

enum PushKind: String {
    case notification   // Claude: permission prompt / waiting on the user
    case stop           // either CLI: turn finished
}

struct PushEvent {
    let cli: CLIKind
    let event: PushKind
    let sessionId: String?
    let cwd: String?
}

/// Listens on a Unix domain socket for one-line JSON pushes from the two hook scripts.
/// This exists because a status *file* can't distinguish "waiting for you" from
/// "finished" — both look idle — and because Codex has no status file at all.
@MainActor
final class PushServer {
    static var socketPath: String {
        let dir = NSString(string: "~/Library/Application Support/StratIsland").expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return (dir as NSString).appendingPathComponent("push.sock")
    }

    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var clients: [Int32: (source: DispatchSourceRead, data: Data)] = [:]
    private let handler: (PushEvent) -> Void

    init(handler: @escaping (PushEvent) -> Void) {
        self.handler = handler
    }

    @discardableResult
    func start() -> Bool {
        let path = Self.socketPath
        unlink(path)

        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            Diagnostics.logger.error("Unable to create Unix socket: errno \(errno)")
            return false
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { p in
            path.withCString { src in
                strncpy(UnsafeMutableRawPointer(p).assumingMemoryBound(to: CChar.self), src, 103)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            Diagnostics.logger.error("Unable to bind or listen on Unix socket: errno \(errno)")
            close(fd)
            fd = -1
            return false
        }
        chmod(path, 0o600)

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [weak self] in self?.accept() }
        src.resume()
        source = src
        return true
    }

    func stop() {
        source?.cancel(); source = nil
        for client in Array(clients.keys) { closeClient(client) }
        if fd >= 0 { close(fd); fd = -1 }
        unlink(Self.socketPath)
    }

    private func accept() {
        let client = Darwin.accept(fd, nil, nil)
        guard client >= 0, clients.count < 16 else { if client >= 0 { close(client) }; return }
        _ = fcntl(client, F_SETFL, O_NONBLOCK)
        let readSource = DispatchSource.makeReadSource(fileDescriptor: client, queue: .main)
        clients[client] = (readSource, Data())
        readSource.setEventHandler { [weak self] in self?.readClient(client) }
        readSource.setCancelHandler { close(client) }
        readSource.resume()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.clients[client] != nil else { return }
            self.closeClient(client)
        }
    }

    private func readClient(_ client: Int32) {
        guard var entry = clients[client] else { return }
        var buf = [UInt8](repeating: 0, count: 2048)
        while true {
            let n = read(client, &buf, buf.count)
            if n > 0 {
                entry.data.append(contentsOf: buf[0..<n])
                guard entry.data.count <= 8192 else { closeClient(client); return }
                while let newline = entry.data.firstIndex(of: 10) {
                    let line = entry.data.prefix(upTo: newline)
                    entry.data.removeSubrange(...newline)
                    handleLine(line)
                }
            } else if n == 0 { closeClient(client); return }
            else if errno == EAGAIN || errno == EWOULDBLOCK { break }
            else { closeClient(client); return }
        }
        clients[client] = (entry.source, entry.data)
    }

    private func handleLine(_ line: Data.SubSequence) {
        for line in String(decoding: line, as: UTF8.self).split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let cli = (obj["cli"] as? String).flatMap(CLIKind.init(rawValue:)),
                  let ev = (obj["event"] as? String).flatMap(PushKind.init(rawValue:))
            else {
                Diagnostics.logger.error("Rejected malformed push event")
                continue
            }
            let event = PushEvent(
                cli: cli, event: ev,
                sessionId: obj["session_id"] as? String,
                cwd: obj["cwd"] as? String
            )
            // cmux launches Claude with its own hook set passed inline as `--settings`,
            // so whether the hooks in ~/.claude/settings.json still reach us is a property
            // of how Claude merges settings sources, not something the app can assume.
            // This line is how that gets answered on a live machine.
            Diagnostics.logger.info(
                "Push received: \(cli.rawValue, privacy: .public)/\(ev.rawValue, privacy: .public)"
            )
            handler(event)
        }
    }

    private func closeClient(_ client: Int32) {
        guard let entry = clients.removeValue(forKey: client) else { return }
        entry.source.cancel()
    }

}
