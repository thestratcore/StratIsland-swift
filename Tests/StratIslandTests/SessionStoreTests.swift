import Foundation
import XCTest
@testable import StratIsland

@MainActor
final class SessionStoreTests: XCTestCase {
    private var now = Date(timeIntervalSince1970: 1_000)
    private var scheduler: TestScheduler!
    private var sound: SoundSpy!
    private var store: SessionStore!

    override func setUp() async throws {
        scheduler = TestScheduler()
        sound = SoundSpy()
        store = SessionStore(
            sound: sound,
            scheduler: scheduler,
            now: { [unowned self] in self.now }
        )
        store.muted = false
    }

    func testWorkingToIdleBecomesDoneUntilAcknowledged() {
        store.apply([snapshot(busy: true)], for: .claude)
        store.apply([snapshot(busy: false)], for: .claude)

        XCTAssertEqual(store.sessions.single?.state, .doneUnacked)
        store.acknowledgeAll()
        XCTAssertEqual(store.sessions.single?.state, .idle)
    }

    func testBlockedStateRequiresPositiveEvidenceToClear() {
        store.apply([snapshot(busy: false, detail: "Waiting")], for: .claude)
        store.applyPush(PushEvent(cli: .claude, event: .notification, sessionId: "session-a", cwd: "/tmp/a"))
        XCTAssertEqual(store.sessions.single?.state, .needsInput)

        store.apply([snapshot(busy: true, detail: "Waiting")], for: .claude)
        XCTAssertEqual(store.sessions.single?.state, .working)
    }

    func testBlockedStateExpiresDeterministically() {
        store = SessionStore(
            sound: sound,
            scheduler: scheduler,
            now: { [unowned self] in self.now },
            blockedMaxAge: 10
        )
        store.muted = false
        store.apply([snapshot(busy: true, detail: "Waiting")], for: .claude)
        store.applyPush(PushEvent(cli: .claude, event: .notification, sessionId: "session-a", cwd: "/tmp/a"))
        XCTAssertEqual(store.sessions.single?.state, .needsInput)

        now.addTimeInterval(11)
        store.apply([snapshot(busy: true, detail: "Waiting")], for: .claude)
        XCTAssertEqual(store.sessions.single?.state, .working)
    }

    func testAutoAcknowledgementUsesInjectedScheduler() {
        store.apply([snapshot(busy: true)], for: .claude)
        store.apply([snapshot(busy: false)], for: .claude)
        XCTAssertEqual(store.sessions.single?.state, .doneUnacked)

        scheduler.run(delay: 60)
        XCTAssertEqual(store.sessions.single?.state, .idle)
    }

    func testExitedSessionMovesToRecent() {
        store.apply([snapshot(busy: false)], for: .claude)
        store.apply([], for: .claude)
        XCTAssertEqual(store.sessions.single?.state, .exited)

        scheduler.run(delay: 8)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertEqual(store.recent.single?.id, "claude:1")
    }

    func testCodexCompletionTargetsMatchingSessionID() {
        let a = snapshot(id: "codex:1", cli: .codex, sessionId: "a", busy: true)
        let b = snapshot(id: "codex:2", cli: .codex, sessionId: "b", busy: true)
        store.apply([a, b], for: .codex)

        store.applyPush(PushEvent(cli: .codex, event: .stop, sessionId: "b", cwd: "/tmp/a"))

        XCTAssertEqual(store.sessions.first { $0.sessionId == "a" }?.state, .working)
        XCTAssertEqual(store.sessions.first { $0.sessionId == "b" }?.state, .doneUnacked)
    }

    // MARK: - The collapsed tally

    func testStateCountsGroupByStateMostUrgentFirst() {
        store.apply(
            [
                snapshot(id: "claude:1", sessionId: "a", busy: true),
                snapshot(id: "claude:2", sessionId: "b", busy: true),
                snapshot(id: "claude:3", sessionId: "c", busy: false),
            ],
            for: .claude
        )

        XCTAssertEqual(
            store.stateCounts,
            [StateCount(state: .working, count: 2), StateCount(state: .idle, count: 1)]
        )
    }

    /// An exited session lingers for the reap delay so the row doesn't vanish under the
    /// cursor. It must not still be counted in the menu bar while it does.
    func testStateCountsExcludeExitedSessions() {
        store.apply([snapshot(id: "claude:1", sessionId: "a", busy: false)], for: .claude)
        store.apply([], for: .claude)

        XCTAssertEqual(store.sessions.single?.state, .exited)
        XCTAssertEqual(store.stateCounts, [])
    }

    func testFlankSummaryRendersEachWidth() {
        let counts = [
            StateCount(state: .needsInput, count: 1),
            StateCount(state: .working, count: 2),
            StateCount(state: .idle, count: 3),
        ]
        XCTAssertEqual(flankSummary(counts, style: .full), "1 NEEDS YOU \u{00B7} 2 WORKING \u{00B7} 3 IDLE")
        XCTAssertEqual(flankSummary(counts, style: .short), "1 NEEDS \u{00B7} 2 WORK \u{00B7} 3 IDLE")
        // The narrowest form keeps the urgent group and folds the rest into a count.
        XCTAssertEqual(flankSummary(counts, style: .leadOnly), "1 NEEDS +5")
    }

    func testFlankSummaryWithOneGroupHasNoOverflow() {
        let counts = [StateCount(state: .idle, count: 1)]
        XCTAssertEqual(flankSummary(counts, style: .full), "1 IDLE")
        XCTAssertEqual(flankSummary(counts, style: .leadOnly), "1 IDLE")
    }

    func testFlankSummaryIsEmDashWhenNothingIsRunning() {
        for style in SummaryStyle.allCases {
            XCTAssertEqual(flankSummary([], style: style), "\u{2014}")
        }
    }

    private func snapshot(
        id: String = "claude:1",
        cli: CLIKind = .claude,
        sessionId: String? = "session-a",
        busy: Bool,
        detail: String? = nil
    ) -> SessionSnapshot {
        SessionSnapshot(
            id: id,
            cli: cli,
            kind: .interactive,
            pid: 1,
            sessionId: sessionId,
            name: "Test",
            cwd: "/tmp/a",
            busy: busy,
            detail: detail,
            startedAt: now,
            tokens: nil,
            fan: [],
            surfaceID: nil
        )
    }
}

@MainActor
private final class TestScheduler: SessionScheduling {
    private struct Entry {
        let delay: TimeInterval
        let token: TestScheduledAction
        let action: @MainActor () -> Void
    }

    private var entries: [Entry] = []

    func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void) -> ScheduledAction {
        let token = TestScheduledAction()
        entries.append(Entry(delay: delay, token: token, action: action))
        return token
    }

    func run(delay: TimeInterval) {
        let ready = entries.filter { $0.delay == delay }
        entries.removeAll { $0.delay == delay }
        ready.filter { !$0.token.cancelled }.forEach { $0.action() }
    }
}

@MainActor
private final class TestScheduledAction: ScheduledAction {
    private(set) var cancelled = false
    func cancel() { cancelled = true }
}

@MainActor
private final class SoundSpy: SoundPlaying {
    private(set) var played: [Sound] = []
    func play(_ sound: Sound) { played.append(sound) }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
