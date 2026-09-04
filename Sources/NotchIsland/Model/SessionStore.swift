import Foundation
import Observation

/// Raw per-session facts scraped from a CLI's on-disk state, before any transition logic.
struct SessionSnapshot {
    let id: String
    let cli: CLIKind
    let kind: SessionKind
    let pid: Int32?
    let sessionId: String?
    let name: String
    let cwd: String
    /// True while the agent is actively running a turn.
    let busy: Bool
    let detail: String?
    let startedAt: Date
    let tokens: Int?
    let fan: [FanItem]
}

/// Single source of truth. Watchers push raw snapshots in; this merges them, derives the
/// five UI states, detects transitions, and fires sound. Main-actor only.
@Observable
@MainActor
final class SessionStore {

    private(set) var sessions: [AgentSession] = []
    private(set) var recent: [AgentSession] = []

    var muted: Bool = false {
        didSet { UserDefaults.standard.set(muted, forKey: "muted") }
    }

    /// Sessions currently blocked on the user, learned from the Notification hook. The
    /// file-based status can't distinguish "waiting for you" from "finished".
    ///
    /// Clearing this is the subtle part. We must not clear simply because the session reads
    /// `busy`: it is unverified whether Claude reports busy or idle while a permission
    /// prompt is on screen, and if it reports busy the state would be cleared the instant it
    /// was set. So a block is only lifted on positive evidence that the session moved on.
    private var blocked: [String: BlockedMark] = [:]

    private struct BlockedMark {
        let at: Date
        let busyAtPush: Bool
        let detailAtPush: String?
    }

    /// Safety net: nothing stays flagged as blocked forever, even if every other signal is
    /// missed.
    private let blockedMaxAge: TimeInterval = 15 * 60

    /// Latest snapshots per CLI, kept so one watcher's update doesn't erase the other's.
    private var snapshots: [CLIKind: [SessionSnapshot]] = [:]

    private var pendingAckTimers: [String: DispatchWorkItem] = [:]
    private var soundDebounce: DispatchWorkItem?
    private var queuedSounds: Set<Sound> = []

    let sound = SoundPlayer()

    init() {
        muted = UserDefaults.standard.bool(forKey: "muted")
    }

    // MARK: - Ingestion

    func apply(_ snaps: [SessionSnapshot], for cli: CLIKind) {
        snapshots[cli] = snaps
        rebuild()
    }

    /// A push edge from a hook script.
    func applyPush(_ push: PushEvent) {
        switch push.event {
        case .notification:
            if let sid = push.sessionId {
                let current = sessions.first { $0.sessionId == sid }
                blocked[sid] = BlockedMark(
                    at: Date(),
                    busyAtPush: current?.state == .working,
                    detailAtPush: current?.detail
                )
            }
        case .stop:
            if let sid = push.sessionId { blocked.removeValue(forKey: sid) }
            // Codex has no status file, so `stop` is the only "finished" signal it gets.
            if push.cli == .codex {
                markCodexDone(cwd: push.cwd)
                return
            }
        }
        rebuild()
    }

    /// Clear the "unacknowledged" flag — the user has seen it.
    func acknowledgeAll() {
        var changed = false
        for i in sessions.indices where sessions[i].state == .doneUnacked {
            sessions[i].state = .idle
            sessions[i].doneAt = nil
            cancelAckTimer(sessions[i].id)
            changed = true
        }
        if changed { sort() }
    }

    func acknowledge(_ id: String) {
        guard let i = sessions.firstIndex(where: { $0.id == id }),
              sessions[i].state == .doneUnacked else { return }
        sessions[i].state = .idle
        sessions[i].doneAt = nil
        cancelAckTimer(id)
        sort()
    }

    // MARK: - Merge + transitions

    private func rebuild() {
        let previous = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        let incoming = snapshots.values.flatMap { $0 }
        var next: [AgentSession] = []
        var entering: [SessionState] = []

        for snap in incoming {
            let prior = previous[snap.id]
            let state = derive(snap, prior: prior)
            if prior?.state != state { entering.append(state) }

            var s = AgentSession(
                id: snap.id,
                cli: snap.cli,
                kind: snap.kind,
                pid: snap.pid,
                sessionId: snap.sessionId,
                name: snap.name,
                cwd: snap.cwd,
                state: state,
                detail: snap.detail,
                startedAt: snap.startedAt,
                lastActivity: Date(),
                tokens: snap.tokens,
                fan: snap.fan,
                doneAt: state == .doneUnacked ? (prior?.doneAt ?? Date()) : nil
            )
            if state != .working { s.fan = [] }
            next.append(s)

            if state == .doneUnacked, prior?.state != .doneUnacked {
                scheduleAutoAck(snap.id)
            }
        }

        // Anything that vanished from the snapshots has exited.
        let liveIDs = Set(next.map(\.id))
        for (id, old) in previous where !liveIDs.contains(id) {
            guard old.state != .exited else { continue }
            var gone = old
            gone.state = .exited
            gone.fan = []
            gone.doneAt = nil
            next.append(gone)
            cancelAckTimer(id)
            scheduleReap(id)
        }
        // Keep already-exited entries until their reap timer fires.
        for (id, old) in previous where old.state == .exited && !liveIDs.contains(id) {
            if !next.contains(where: { $0.id == id }) { next.append(old) }
        }

        next.sort {
            if $0.state.urgency != $1.state.urgency { return $0.state.urgency < $1.state.urgency }
            return $0.startedAt > $1.startedAt
        }
        // Claude rewrites its job state on every tool call. Without this guard the view
        // tree would be invalidated several times a second for no visible change.
        guard next != sessions else { return }
        sessions = next

        if entering.contains(.needsInput) { queueSound(.needsInput) }
        if entering.contains(.doneUnacked) { queueSound(.finished) }
    }

    private func derive(_ snap: SessionSnapshot, prior: AgentSession?) -> SessionState {
        if let sid = snap.sessionId, let mark = blocked[sid] {
            if isUnblocked(snap, mark) {
                blocked.removeValue(forKey: sid)
            } else {
                return .needsInput
            }
        }
        if snap.busy { return .working }
        switch prior?.state {
        case .working:      return .doneUnacked   // working -> idle is a completion
        case .doneUnacked:  return .doneUnacked   // hold until acked or auto-acked
        default:            return .idle
        }
    }

    /// Positive evidence that a blocked session has resumed: it started working having not
    /// been working when the prompt appeared, its reported action changed, or the block is
    /// simply too old to trust.
    private func isUnblocked(_ snap: SessionSnapshot, _ mark: BlockedMark) -> Bool {
        if Date().timeIntervalSince(mark.at) > blockedMaxAge { return true }
        if snap.busy && !mark.busyAtPush { return true }
        if let detail = snap.detail, detail != mark.detailAtPush { return true }
        return false
    }

    private func markCodexDone(cwd: String?) {
        guard let i = sessions.firstIndex(where: {
            $0.cli == .codex && (cwd == nil || $0.cwd == cwd)
        }) else { return }
        guard sessions[i].state != .doneUnacked else { return }
        sessions[i].state = .doneUnacked
        sessions[i].doneAt = Date()
        scheduleAutoAck(sessions[i].id)
        queueSound(.finished)
        sort()
    }

    private func sort() {
        sessions.sort {
            if $0.state.urgency != $1.state.urgency { return $0.state.urgency < $1.state.urgency }
            return $0.startedAt > $1.startedAt
        }
    }

    // MARK: - One-shot timers (no polling)

    private func scheduleAutoAck(_ id: String) {
        cancelAckTimer(id)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.acknowledge(id) }
        }
        pendingAckTimers[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
    }

    private func scheduleReap(_ id: String) {
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let i = self.sessions.firstIndex(where: { $0.id == id }),
                      self.sessions[i].state == .exited else { return }
                let gone = self.sessions.remove(at: i)
                self.recent.insert(gone, at: 0)
                if self.recent.count > 10 { self.recent.removeLast() }
            }
        }
        pendingAckTimers[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    private func cancelAckTimer(_ id: String) {
        pendingAckTimers[id]?.cancel()
        pendingAckTimers[id] = nil
    }

    // MARK: - Sound (coalesced so N simultaneous completions play once)

    private func queueSound(_ s: Sound) {
        guard !muted else { return }
        queuedSounds.insert(s)
        soundDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // "You are the bottleneck" outranks "something finished".
                if self.queuedSounds.contains(.needsInput) { self.sound.play(.needsInput) }
                else if self.queuedSounds.contains(.finished) { self.sound.play(.finished) }
                self.queuedSounds.removeAll()
            }
        }
        soundDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    // MARK: - Derived view state

    var hasAttention: Bool {
        sessions.contains { $0.state == .needsInput || $0.state == .doneUnacked }
    }

    var primary: AgentSession? { sessions.first }

    var secondary: [AgentSession] { Array(sessions.dropFirst()) }
}
