import Darwin
import Foundation

/// How a session process is bound to the cmux surface that hosts it.
///
/// cmux exports the binding into every process it launches, so the pid the watchers
/// already have is enough to find the surface — there is no need to ask cmux for a
/// process table, and nothing has to be matched heuristically the way Terminal tabs were
/// matched by tty. A process's environment is fixed for its lifetime, so this is read once
/// per pid and cached.
struct CmuxBinding: Equatable {
    let surfaceID: String
    let workspaceID: String?
    /// `claude` or `codex`, as cmux launched it. Absent for a plain shell.
    let agentKind: String?
}

@MainActor
enum CmuxBindingResolver {

    private static var cache: [Int32: CmuxBinding?] = [:]

    /// The surface hosting `pid`, walking up the parent chain for processes cmux did not
    /// launch directly — a background Claude job is a child of the daemon, not of the pane
    /// shell, exactly as it was for the tty walk it replaces.
    static func binding(forPID pid: Int32, maxHops: Int = 8) -> CmuxBinding? {
        if let hit = cache[pid] { return hit }
        var current: Int32? = pid
        var found: CmuxBinding?
        for _ in 0..<maxHops {
            guard let p = current, p > 1 else { break }
            if let env = processEnvironment(p), let binding = cmuxBinding(in: env) {
                found = binding
                break
            }
            current = parentPID(p)
        }
        cache[pid] = found
        return found
    }

    /// Sessions come and go constantly; without this the cache would grow for the life of
    /// the app. Pruning by liveness rather than by a caller's pid list keeps this correct
    /// no matter which watcher calls it — a Claude scan must not evict Codex entries.
    static func pruneDeadProcesses() {
        cache = cache.filter { processIsAlive($0.key) }
    }

    static func resetForTesting() { cache.removeAll() }
}

func cmuxBinding(in env: [String: String]) -> CmuxBinding? {
    guard let surface = env["CMUX_SURFACE_ID"], !surface.isEmpty else { return nil }
    return CmuxBinding(
        surfaceID: surface,
        workspaceID: env["CMUX_WORKSPACE_ID"].flatMap { $0.isEmpty ? nil : $0 },
        agentKind: env["CMUX_AGENT_LAUNCH_KIND"].flatMap { $0.isEmpty ? nil : $0 }
    )
}

/// The environment of another process, via `KERN_PROCARGS2`. Same-user processes only,
/// which is all we ever look at — this reads no more than `ps -E` does.
func processEnvironment(_ pid: Int32) -> [String: String]? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
    return parseProcArgs2(Data(buffer[0..<size]))
}

/// KERN_PROCARGS2 layout: `argc` as a host-order Int32, the executable path, padding NULs,
/// `argc` NUL-terminated argv strings, then the environment as NUL-terminated `KEY=VALUE`
/// strings until the buffer runs out. Split out from the sysctl call so the parsing — the
/// part that can actually be wrong — is testable without a live process.
func parseProcArgs2(_ data: Data) -> [String: String]? {
    let bytes = [UInt8](data)
    let intSize = MemoryLayout<Int32>.size
    guard bytes.count > intSize else { return nil }

    var argc = Int32(0)
    withUnsafeMutableBytes(of: &argc) { dst in
        dst.copyBytes(from: bytes[0..<intSize])
    }
    guard argc >= 0 else { return nil }

    var index = intSize
    // The executable path, then any padding NULs before argv[0].
    while index < bytes.count, bytes[index] != 0 { index += 1 }
    while index < bytes.count, bytes[index] == 0 { index += 1 }

    // argv, which we skip: a JSON blob of hook settings is passed on the command line and
    // is of no interest here.
    for _ in 0..<Int(argc) {
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        guard index < bytes.count else { return [:] }
        index += 1
    }

    var env: [String: String] = [:]
    var start = index
    while index < bytes.count {
        if bytes[index] == 0 {
            if index > start,
               let entry = String(bytes: bytes[start..<index], encoding: .utf8),
               let split = entry.firstIndex(of: "=") {
                env[String(entry[entry.startIndex..<split])] =
                    String(entry[entry.index(after: split)...])
            }
            start = index + 1
        }
        index += 1
    }
    return env
}
