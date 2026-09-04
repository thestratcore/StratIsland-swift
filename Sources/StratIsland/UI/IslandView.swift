import SwiftUI

/// The whole island: two flanks in the menu bar hugging the physical cutout, plus a panel
/// that drops below it when expanded. Nothing is ever drawn inside the cutout itself —
/// there are no pixels there.
struct IslandView: View {
    @Bindable var store: SessionStore
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    @Binding var expanded: Bool
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
            if expanded {
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
        .animation(.easeOut(duration: 0.22), value: expanded)
    }

    // MARK: - Left flank: the single most urgent session

    private var leftFlank: some View {
        ZStack(alignment: .trailing) {
            FlankShape(outerEdge: .leading, radius: Theme.flankCornerRadius)
                .fill(Theme.panelFill)
            HStack(spacing: 5) {
                if let s = store.primary {
                    StateDot(state: s.state)
                    Text(s.cli.glyph)
                        .font(Theme.ocr(9))
                        .foregroundStyle(Theme.textTertiary)
                    Text(s.shortName(max: 10))
                        .font(Theme.ocr(10))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                } else {
                    Text("—")
                        .font(Theme.ocr(10))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.trailing, 8)
        }
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
                        .font(Theme.ocr(9))
                        .foregroundStyle(Theme.textSecondary)
                }
                if rest.isEmpty, let s = store.primary {
                    Text(s.state == .working ? formatElapsed(s.elapsed) : s.state.label)
                        .font(Theme.ocr(9))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                if store.muted {
                    Text("M")
                        .font(Theme.ocr(8))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.leading, 8)
        }
    }
}
