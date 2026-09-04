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
final class PushServer {
    static var socketPath: String {
        let dir = NSString(string: "~/Library/Application Support/NotchIsland").expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return (dir as NSString).appendingPathComponent("push.sock")
    }

    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let handler: (PushEvent) -> Void

    init(handler: @escaping (PushEvent) -> Void) {
        self.handler = handler
    }

    func start() {
        let path = Self.socketPath
        unlink(path)

        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }

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
        guard bound == 0, listen(fd, 8) == 0 else { close(fd); fd = -1; return }
        chmod(path, 0o600)

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .utility))
        src.setEventHandler { [weak self] in self?.accept() }
        src.resume()
        source = src
    }

    func stop() {
        source?.cancel(); source = nil
        if fd >= 0 { close(fd); fd = -1 }
        unlink(Self.socketPath)
    }

    private func accept() {
        let client = Darwin.accept(fd, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }

        var buf = [UInt8](repeating: 0, count: 8192)
        let n = read(client, &buf, buf.count)
        guard n > 0 else { return }
        let data = Data(buf[0..<n])

        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let cli = (obj["cli"] as? String).flatMap(CLIKind.init(rawValue:)),
                  let ev = (obj["event"] as? String).flatMap(PushKind.init(rawValue:))
            else { continue }
            let event = PushEvent(
                cli: cli, event: ev,
                sessionId: obj["session_id"] as? String,
                cwd: obj["cwd"] as? String
            )
            handler(event)
        }
    }

    deinit { stop() }
}
