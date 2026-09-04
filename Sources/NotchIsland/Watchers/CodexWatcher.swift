import Foundation

/// Codex publishes no live status: its rollout logs are write-only and there is no index.
/// So this is deliberately coarse — process presence for existence, rollout file mtime for
/// activity, and the `notify` hook for completion. A session carries no `detail` in v1.
@MainActor
final class CodexWatcher {
    private let sessionsRoot = NSString(string: "~/.codex/sessions").expandingTildeInPath
    private var timer: DispatchSourceTimer?
    private var cwdCache: [Int32: String] = [:]
    private var firstSeen: [Int32: Date] = [:]
    /// path -> cwd from the rollout's `session_meta`. Written once at session start, so
    /// this is read once per file and kept.
    private var rolloutCWD: [String: String] = [:]
    private let onUpdate: ([SessionSnapshot]) -> Void

    /// Activity window: a rollout file touched within this many seconds means "working".
    private let activeWindow: TimeInterval = 5

    init(onUpdate: @escaping ([SessionSnapshot]) -> Void) {
        self.onUpdate = onUpdate
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        // 2 s while Codex is alive; the tick is a sysctl call, not a fork, so the idle
        // case costs effectively nothing.
        t.schedule(deadline: .now(), repeating: 2.0, leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scan() }
        }
        t.resume()
        timer = t
    }

    func stop() { timer?.cancel(); timer = nil }

    private func scan() {
        let pids = listProcesses()
            .filter { $0.comm == "codex" }
            .map(\.pid)
            .sorted()

        guard !pids.isEmpty else {
            cwdCache.removeAll()
            firstSeen.removeAll()
            onUpdate([])
            return
        }

        let rollouts = currentRollouts()
        let newest = rollouts.max { $0.mtime < $1.mtime }
        let anyActive = newest.map { Date().timeIntervalSince($0.mtime) < activeWindow } ?? false
        // Fallback when no rollout can be attributed to a process: activity is credited to
        // the most recently started one.
        let activePID = pids.last

        var out: [SessionSnapshot] = []
        for pid in pids {
            let cwd = cwdCache[pid] ?? processCWD(pid) ?? ""
            cwdCache[pid] = cwd
            let started = firstSeen[pid] ?? Date()
            firstSeen[pid] = started

            // Match the process to its own rollout by working directory. That gives this
            // session its own activity signal instead of a global one, and Codex writes no
            // title, so the first thing the user actually typed stands in for one.
            let mine = rollouts
                .filter { !cwd.isEmpty && $0.cwd == cwd }
                .max { $0.mtime < $1.mtime }
            let busy: Bool
            if let mine {
                busy = Date().timeIntervalSince(mine.mtime) < activeWindow
            } else {
                busy = anyActive && pid == activePID
            }
            let title = mine.flatMap { SessionTitle.codex(rolloutPath: $0.path) }

            out.append(SessionSnapshot(
                id: "codex:\(pid)",
                cli: .codex,
                kind: .interactive,
                pid: pid,
                sessionId: nil,
                name: title ?? (cwd as NSString).lastPathComponent,
                cwd: cwd,
                busy: busy,
                detail: nil,
                startedAt: started,
                tokens: nil,
                fan: []
            ))
        }
        onUpdate(out)
    }

    private struct Rollout {
        let path: String
        let cwd: String
        let mtime: Date
    }

    /// Only today's and yesterday's directories are checked — walking the full
    /// sessions/YYYY/MM/DD tree every two seconds would be absurd.
    private func currentRollouts() -> [Rollout] {
        let fm = FileManager.default
        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy/MM/dd"
        var out: [Rollout] = []

        for offset in 0...1 {
            guard let day = cal.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let dir = (sessionsRoot as NSString).appendingPathComponent(fmt.string(from: day))
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for f in files where f.hasPrefix("rollout-") && f.hasSuffix(".jsonl") {
                let path = (dir as NSString).appendingPathComponent(f)
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let m = attrs[.modificationDate] as? Date else { continue }
                out.append(Rollout(path: path, cwd: cwd(ofRollout: path), mtime: m))
            }
        }
        return out
    }

    /// The first record of a rollout is `session_meta`, which carries the working directory.
    private func cwd(ofRollout path: String) -> String {
        if let hit = rolloutCWD[path] { return hit }
        var result = ""
        if let handle = FileHandle(forReadingAtPath: path) {
            defer { try? handle.close() }
            if let data = try? handle.read(upToCount: 64 * 1024),
               let first = String(decoding: data, as: UTF8.self).split(separator: "\n").first,
               let obj = try? JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any],
               let payload = obj["payload"] as? [String: Any],
               let c = payload["cwd"] as? String {
                result = c
            }
        }
        rolloutCWD[path] = result
        return result
    }
}
