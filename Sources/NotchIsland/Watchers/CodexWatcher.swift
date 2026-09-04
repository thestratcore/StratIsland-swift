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

        let recentTouch = newestRolloutMTime()
        let anyActive = recentTouch.map { Date().timeIntervalSince($0) < activeWindow } ?? false
        // With several Codex processes we cannot attribute a rollout file to one of them,
        // so activity is credited to the most recently started process only.
        let activePID = pids.last

        var out: [SessionSnapshot] = []
        for pid in pids {
            let cwd = cwdCache[pid] ?? processCWD(pid) ?? ""
            cwdCache[pid] = cwd
            let started = firstSeen[pid] ?? Date()
            firstSeen[pid] = started

            out.append(SessionSnapshot(
                id: "codex:\(pid)",
                cli: .codex,
                kind: .interactive,
                pid: pid,
                sessionId: nil,
                name: (cwd as NSString).lastPathComponent,
                cwd: cwd,
                busy: anyActive && pid == activePID,
                detail: nil,
                startedAt: started,
                tokens: nil,
                fan: []
            ))
        }
        onUpdate(out)
    }

    /// Only today's and yesterday's directories are checked — walking the full
    /// sessions/YYYY/MM/DD tree every two seconds would be absurd.
    private func newestRolloutMTime() -> Date? {
        let fm = FileManager.default
        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy/MM/dd"
        var newest: Date?

        for offset in 0...1 {
            guard let day = cal.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let dir = (sessionsRoot as NSString).appendingPathComponent(fmt.string(from: day))
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for f in files where f.hasPrefix("rollout-") && f.hasSuffix(".jsonl") {
                let path = (dir as NSString).appendingPathComponent(f)
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let m = attrs[.modificationDate] as? Date else { continue }
                if newest == nil || m > newest! { newest = m }
            }
        }
        return newest
    }
}
