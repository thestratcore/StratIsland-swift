import Foundation

/// Reads Claude Code's own status files. This is the richest source we have: it already
/// carries a name, a busy flag, and a human-readable "what it's doing right now" string.
///
///   ~/.claude/sessions/<pid>.json   -> identity, kind, status
///   ~/.claude/jobs/<jobId>/state.json -> detail, fan[], tokens
@MainActor
final class ClaudeWatcher {
    private let sessionsDir = NSString(string: "~/.claude/sessions").expandingTildeInPath
    private let jobsDir = NSString(string: "~/.claude/jobs").expandingTildeInPath
    private var watcher: FSWatcher?
    private let onUpdate: ([SessionSnapshot]) -> Void
    private let health: AppHealth

    init(health: AppHealth, onUpdate: @escaping ([SessionSnapshot]) -> Void) {
        self.health = health
        self.onUpdate = onUpdate
    }

    func start() {
        watcher = FSWatcher(paths: [sessionsDir, jobsDir]) { [weak self] in
            Task { @MainActor in self?.scan() }
        }
        if watcher?.start() == true {
            health.clear(.fileEvents)
        } else {
            health.report(.fileEvents, "Claude session directories are not being watched")
        }
        scan()
    }

    func stop() { watcher?.stop(); watcher = nil }

    func scan() {
        let fm = FileManager.default
        let files: [String]
        do {
            files = try fm.contentsOfDirectory(atPath: sessionsDir)
            health.clear(.claudeWatcher)
        } catch {
            health.report(.claudeWatcher, "Cannot read the Claude sessions directory")
            onUpdate([])
            return
        }
        var out: [SessionSnapshot] = []
        var malformedFiles = 0

        for file in files where file.hasSuffix(".json") {
            guard let obj = readJSONObject(at: (sessionsDir as NSString).appendingPathComponent(file)),
                  let pid = obj["pid"] as? Int32 ?? (obj["pid"] as? Int).map(Int32.init)
            else {
                malformedFiles += 1
                continue
            }

            // A session file outlives a crashed process; the pid is the truth.
            guard processIsAlive(pid) else { continue }

            let status = obj["status"] as? String ?? "idle"
            let kind: SessionKind = (obj["kind"] as? String) == "bg" ? .background : .interactive
            let jobId = obj["jobId"] as? String

            // Claude keeps pre-warmed background "spares" ready to claim. They have no job
            // attached and are not doing anything — showing them would add pills that
            // appear and vanish for reasons the user has no way to interpret.
            if kind == .background, jobId == nil { continue }
            let cwd = obj["cwd"] as? String ?? ""
            let name = (obj["name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            let nameSource = obj["nameSource"] as? String
            let sessionId = obj["sessionId"] as? String
            let startedMs = obj["startedAt"] as? Double ?? 0

            var detail: String?
            var tokens: Int?
            var fan: [FanItem] = []
            var busy = (status == "busy")

            // Join to the job record. `parkedJobId` is deliberately ignored: an interactive
            // session that is parked watching a background job must not inherit that job's
            // detail, or the same work would be reported twice.
            if let jobId {
                let statePath = (jobsDir as NSString)
                    .appendingPathComponent(jobId)
                    .appending("/state.json")
                if let job = readJSONObject(at: statePath) {
                    detail = (job["detail"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    tokens = job["tokens"] as? Int
                    if let state = job["state"] as? String { busy = busy || state == "working" }
                    if let rawFan = job["fan"] as? [[String: Any]] {
                        fan = rawFan.compactMap { item in
                            guard let id = item["id"] as? String else { return nil }
                            let started = (item["startedAt"] as? Double).map {
                                Date(timeIntervalSince1970: $0 / 1000)
                            }
                            return FanItem(
                                id: id,
                                kind: item["kind"] as? String ?? "task",
                                label: compactLabel(item["label"] as? String ?? ""),
                                startedAt: started
                            )
                        }
                    }
                }
            }

            // `nameSource: "derived"` means the name is the working directory reworded —
            // every thread in a repo would read the same. The transcript's own title says
            // what this one is for.
            var title = name
            if name.isEmpty || nameSource == "derived" {
                if let sessionId, let t = SessionTitle.claude(sessionId: sessionId, cwd: cwd) {
                    title = t
                } else if name.isEmpty {
                    title = (cwd as NSString).lastPathComponent
                }
            }

            out.append(SessionSnapshot(
                id: "claude:\(pid)",
                cli: .claude,
                kind: kind,
                pid: pid,
                sessionId: sessionId,
                name: title,
                cwd: cwd,
                busy: busy,
                detail: (detail?.isEmpty ?? true) ? nil : detail,
                startedAt: startedMs > 0 ? Date(timeIntervalSince1970: startedMs / 1000) : Date(),
                tokens: tokens,
                fan: fan,
                surfaceID: CmuxBindingResolver.binding(forPID: pid)?.surfaceID
            ))
        }
        CmuxBindingResolver.pruneDeadProcesses()
        if malformedFiles > 0 {
            health.report(.claudeWatcher, "Rejected \(malformedFiles) malformed session file(s)")
        } else {
            health.clear(.claudeWatcher)
        }
        onUpdate(out)
    }
}

/// `fan[]` labels are whole shell commands — sometimes hundreds of characters. Collapse
/// them to one readable line.
private func compactLabel(_ raw: String) -> String {
    let flat = raw.replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\\n", with: " ")
        .split(separator: " ")
        .joined(separator: " ")
    return flat.count > 70 ? String(flat.prefix(69)) + "…" : flat
}
