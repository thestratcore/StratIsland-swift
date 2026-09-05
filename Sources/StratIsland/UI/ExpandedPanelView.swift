import SwiftUI

/// Read-only detail, plus click-to-focus. Deliberately no interrupt/kill controls: this
/// surface sits under the cursor's path to the menu bar, and a misclick there would cost
/// an agent run.
struct ExpandedPanelView: View {
    @Bindable var store: SessionStore
    @State private var now = Date()

    /// Elapsed time only ticks while the panel is open — nothing reads it when collapsed.
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.sessions.isEmpty {
                Text("NO ACTIVE SESSIONS")
                    .font(Theme.ocr(10))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 18)
            } else {
                ForEach(store.sessions) { session in
                    SessionRow(session: session, now: now)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            store.acknowledge(session.id)
                            SessionFocuser.focus(session: session)
                        }
                    if session.id != store.sessions.last?.id {
                        Divider().overlay(Theme.hairline)
                    }
                }
            }

            if !store.recent.isEmpty {
                Divider().overlay(Theme.hairline)
                Text("RECENT")
                    .font(Theme.ocr(8))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                ForEach(store.recent.prefix(5)) { s in
                    HStack(spacing: 7) {
                        StateDot(state: .exited, size: 5)
                        Text(s.shortName(max: 36))
                            .font(Theme.ocr(9))
                            .foregroundStyle(Theme.textTertiary)
                        Spacer()
                        Text(s.project.uppercased())
                            .font(Theme.ocr(9))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 2)
                }
                .padding(.bottom, 6)
            }
        }
        .padding(.vertical, 6)
        .onReceive(tick) { now = $0 }
    }
}

/// Exactly two lines per session, always — identity and timing on the first, context on the
/// second. A variable-height row made the panel jump every time a `detail` string appeared
/// or a subagent spawned, and with several sessions running the list outgrew a glance.
/// Everything that used to occupy a third line (`detail`, `fan[]`) is folded into line two.
private struct SessionRow: View {
    let session: AgentSession
    let now: Date

    /// The prose slot: what the session is actually doing. Claude publishes `detail`; when
    /// it doesn't, the newest subagent's label is the next most informative thing.
    private var context: String? {
        if let d = session.detail { return d }
        return session.fan.last?.label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                StateDot(state: session.state)
                Text(session.cli.glyph)
                    .font(Theme.ocr(10))
                    .foregroundStyle(Theme.textTertiary)
                Text(session.shortName(max: 44))
                    .font(Theme.ocr(11))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if let badge = session.kind.badge {
                    Text(badge)
                        .font(Theme.ocr(8))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(Theme.hairline))
                }
                Spacer(minLength: 8)
                Text(session.state.label)
                    .font(Theme.ocr(9))
                    .foregroundStyle(session.state.color)
                    .lineLimit(1)
                Text(formatElapsed(now.timeIntervalSince(session.startedAt)))
                    .font(Theme.ocr(10))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }

            HStack(spacing: 6) {
                Text(session.project.uppercased())
                    .font(Theme.ocr(9))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .layoutPriority(1)
                if !session.fan.isEmpty {
                    // Subagents are a count here, not a list: they churn far too fast to
                    // read individually, and each one used to add a line.
                    Text("└\(session.fan.count)")
                        .font(Theme.ocr(9))
                        .foregroundStyle(Theme.textTertiary)
                        .layoutPriority(1)
                }
                if let context {
                    Text(context)
                        .font(Theme.prose(10))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 6)
                if let t = session.tokens {
                    Text(formatTokens(t))
                        .font(Theme.ocr(9))
                        .foregroundStyle(Theme.textTertiary)
                        .layoutPriority(1)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }
}
