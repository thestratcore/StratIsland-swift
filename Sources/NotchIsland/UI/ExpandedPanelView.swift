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
                            TerminalFocuser.focus(session: session)
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
                        Text(s.shortName(max: 18))
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

private struct SessionRow: View {
    let session: AgentSession
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                StateDot(state: session.state)
                Text(session.cli.glyph)
                    .font(Theme.ocr(10))
                    .foregroundStyle(Theme.textTertiary)
                Text(session.shortName(max: 22))
                    .font(Theme.ocr(11))
                    .foregroundStyle(Theme.textPrimary)
                if let badge = session.kind.badge {
                    Text(badge)
                        .font(Theme.ocr(8))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(Theme.hairline))
                }
                Spacer()
                Text(formatElapsed(now.timeIntervalSince(session.startedAt)))
                    .font(Theme.ocr(10))
                    .foregroundStyle(Theme.textSecondary)
            }

            HStack(spacing: 6) {
                Text(session.project.uppercased())
                    .font(Theme.ocr(9))
                    .foregroundStyle(Theme.textTertiary)
                Text(session.state.label)
                    .font(Theme.ocr(9))
                    .foregroundStyle(session.state.color)
                Spacer()
                if let t = session.tokens {
                    Text(formatTokens(t))
                        .font(Theme.ocr(9))
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            if let detail = session.detail {
                Text(detail)
                    .font(Theme.prose(10))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 1)
            }

            // Subagents live here and only here — they churn far too fast for the pill.
            ForEach(session.fan.prefix(3)) { item in
                HStack(spacing: 5) {
                    Text("└")
                        .font(Theme.ocr(9))
                        .foregroundStyle(Theme.textTertiary)
                    Text(item.kind.uppercased())
                        .font(Theme.ocr(8))
                        .foregroundStyle(Theme.textTertiary)
                    Text(item.label)
                        .font(Theme.prose(9))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }
}
