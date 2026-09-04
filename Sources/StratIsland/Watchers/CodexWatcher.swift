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
    /// Metadata from the rollout's `session_meta`. Written once, so each file is read once.
    private var rolloutMetadata: [String: RolloutMetadata] = [:]
    private let onUpdate: ([SessionSnapshot]) -> Void
    private let health: AppHealth

    /// Activity window: a rollout file touched within this many seconds means "working".
    private let activeWindow: TimeInterval = 5

    init(health: AppHealth, onUpdate: @escaping ([SessionSnapshot]) -> Void) {
        self.health = health
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
        let processes: [(pid: Int32, comm: String)]
        switch listProcesses() {
        case .success(let result):
            processes = result
            health.clear(.codexWatcher)
        case .failure(let error):
            health.report(.codexWatcher, "Process enumeration failed: \(error)")
            return
        }
        let pids = processes.filter { $0.comm == "codex" }
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
        var unclaimed = Set(rollouts.map(\.path))
        for pid in pids {
            let cwd = cwdCache[pid] ?? processCWD(pid) ?? ""
            cwdCache[pid] = cwd
            let started = firstSeen[pid] ?? Date()
            firstSeen[pid] = started

            // Match the process to its own rollout by working directory. That gives this
            // session its own activity signal instead of a global one, and Codex writes no
            // title, so the first thing the user actually typed stands in for one.
            let candidates = rollouts.filter {
                unclaimed.contains($0.path) && !cwd.isEmpty && $0.cwd == cwd
            }
            let mine: Rollout?
            if let processStarted = processStartDate(pid) {
                mine = candidates.min {
                    abs($0.startedAt.timeIntervalSince(processStarted))
                        < abs($1.startedAt.timeIntervalSince(processStarted))
                }
            } else {
                mine = candidates.max { $0.mtime < $1.mtime }
            }
            if let mine { unclaimed.remove(mine.path) }
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
                sessionId: mine?.sessionId,
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
        let sessionId: String?
        let startedAt: Date
        let mtime: Date
    }

    private struct RolloutMetadata {
        let cwd: String
        let sessionId: String?
        let startedAt: Date
    }

    /// Only today's and yesterday's directories are checked — walking the full
    /// sessions/YYYY/MM/DD tree every two seconds would be absurd.
    private func currentRollouts() -> [Rollout] {
        let fm = FileManager.default
        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy/MM/dd"
        var out: [Rollout] = []
        var malformedFiles = 0

        for offset in 0...1 {
            guard let day = cal.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let dir = (sessionsRoot as NSString).appendingPathComponent(fmt.string(from: day))
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for f in files where f.hasPrefix("rollout-") && f.hasSuffix(".jsonl") {
                let path = (dir as NSString).appendingPathComponent(f)
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let m = attrs[.modificationDate] as? Date else { continue }
                let metadata = metadata(ofRollout: path, fallbackDate: m)
                if metadata.cwd.isEmpty || metadata.sessionId == nil {
                    malformedFiles += 1
                }
                out.append(Rollout(
                    path: path,
                    cwd: metadata.cwd,
                    sessionId: metadata.sessionId,
                    startedAt: metadata.startedAt,
                    mtime: m
                ))
            }
        }
        if malformedFiles > 0 {
            health.report(.codexWatcher, "Rejected \(malformedFiles) malformed rollout metadata record(s)")
        } else {
            health.clear(.codexWatcher)
        }
        return out
    }

    /// The first record of a rollout is `session_meta`, which carries the working directory.
    private func metadata(ofRollout path: String, fallbackDate: Date) -> RolloutMetadata {
        if let hit = rolloutMetadata[path] { return hit }
        var result = RolloutMetadata(cwd: "", sessionId: nil, startedAt: fallbackDate)
        if let handle = FileHandle(forReadingAtPath: path) {
            defer { try? handle.close() }
            if let data = try? handle.read(upToCount: 64 * 1024),
               let first = String(decoding: data, as: UTF8.self).split(separator: "\n").first,
               let obj = try? JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any],
               let payload = obj["payload"] as? [String: Any] {
                let timestamp = (payload["timestamp"] as? String)
                    .flatMap { ISO8601DateFormatter().date(from: $0) }
                result = RolloutMetadata(
                    cwd: payload["cwd"] as? String ?? "",
                    sessionId: payload["id"] as? String ?? payload["session_id"] as? String,
                    startedAt: timestamp ?? fallbackDate
                )
            }
        }
        rolloutMetadata[path] = result
        return result
    }
}
