import SwiftUI

/// The whole island: two flanks in the menu bar hugging the physical cutout, plus a panel
/// that drops below it when expanded. Nothing is ever drawn inside the cutout itself —
/// there are no pixels there.
struct IslandView: View {
    @Bindable var store: SessionStore
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let presentation: IslandPresentation
    /// Reports the panel's natural height so the window can size itself to the content.
    var onPanelHeight: (CGFloat) -> Void = { _ in }

    /// Constant in both states — see the note on `Theme.flankWidth`.
    private var flankWidth: CGFloat { Theme.flankWidth }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                leftFlank
                    .frame(width: flankWidth, height: notchHeight)
                Color.clear
                    .frame(width: notchWidth, height: notchHeight)
                rightFlank
                    .frame(width: flankWidth, height: notchHeight)
            }
            if presentation.expanded {
                ExpandedPanelView(store: store)
                    .frame(width: flankWidth * 2 + notchWidth)
                    .background(
                        GeometryReader { geo in
                            Color.clear.onChange(of: geo.size.height, initial: true) { _, h in
                                onPanelHeight(h)
                            }
                        }
                    )
                    .background(Theme.panelFill)
                    .clipShape(
                        UnevenRoundedRectangle(
                            bottomLeadingRadius: Theme.panelCornerRadius,
                            bottomTrailingRadius: Theme.panelCornerRadius
                        )
                    )
                    .transition(.opacity)
            }
        }
        // Matches the window's own frame animation. Two different curves driving the same
        // motion is what made the open look unsteady; the window height is the motion now,
        // and the content only fades with it.
        .animation(.easeOut(duration: 0.22), value: presentation.expanded)
    }

    // MARK: - Left flank: the tally

    /// Collapsed, the question is "does anything want me", not "which session is this" — so
    /// the flank counts states instead of naming one session. Names are what hovering is for.
    private var leftFlank: some View {
        ZStack(alignment: .trailing) {
            FlankShape(outerEdge: .leading, radius: Theme.flankCornerRadius)
                .fill(Theme.panelFill)
            HStack(spacing: 5) {
                let counts = store.stateCounts
                if let lead = counts.first {
                    // The most urgent state present owns the dot, so `working` and
                    // `needsInput` keep the pulse that makes them readable peripherally.
                    StateDot(state: lead.state)
                    // Longest first: SwiftUI takes the first candidate that fits the flank,
                    // which beats guessing a character budget for a proportional-ish face.
                    ViewThatFits(in: .horizontal) {
                        tally(counts, .full)
                        tally(counts, .short)
                        tally(counts, .leadOnly)
                    }
                } else {
                    Text("\u{2014}")
                        .font(Theme.ocr(8))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.trailing, 8)
        }
    }

    private func tally(_ counts: [StateCount], _ style: SummaryStyle) -> some View {
        Text(flankSummary(counts, style: style))
            .font(Theme.ocr(8))
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(1)
            .fixedSize()
    }

    // MARK: - Right flank: everything else, as dots

    private var rightFlank: some View {
        ZStack(alignment: .leading) {
            FlankShape(outerEdge: .trailing, radius: Theme.flankCornerRadius)
                .fill(Theme.panelFill)
            HStack(spacing: 5) {
                let rest = store.secondary
                ForEach(rest.prefix(4)) { s in
                    StateDot(state: s.state, size: 6)
                }
                if rest.count > 4 {
                    Text("+\(rest.count - 4)")
                        .font(Theme.ocr(7))
                        .foregroundStyle(Theme.textSecondary)
                }
                if rest.isEmpty, let s = store.primary {
                    Text(s.state == .working ? formatElapsed(s.elapsed) : s.state.label)
                        .font(Theme.ocr(7))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                if store.muted {
                    Text("M")
                        .font(Theme.ocr(6))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.leading, 8)
        }
    }
}

/// The three widths the flank tally is offered at, longest first.
enum SummaryStyle: CaseIterable {
    case full       // "2 WORKING \u{00B7} 1 IDLE"
    case short      // "2 WORK \u{00B7} 1 IDLE"
    case leadOnly   // "2 WORK +1"
}

/// Renders a tally at one of the three widths. Counts arrive most-urgent-first and that
/// order is preserved: the leading group is the one the dot and the sound are about.
func flankSummary(_ counts: [StateCount], style: SummaryStyle) -> String {
    guard let lead = counts.first else { return "\u{2014}" }
    switch style {
    case .full:
        return counts.map { "\($0.count) \($0.state.label)" }.joined(separator: " \u{00B7} ")
    case .short:
        return counts.map { "\($0.count) \($0.state.shortLabel)" }.joined(separator: " \u{00B7} ")
    case .leadOnly:
        let rest = counts.dropFirst().reduce(0) { $0 + $1.count }
        let head = "\(lead.count) \(lead.state.shortLabel)"
        return rest == 0 ? head : head + " +\(rest)"
    }
}
