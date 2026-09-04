import SwiftUI
import CoreText

enum Theme {
    /// Compact flank width on each side of the cutout. OCR A is monospaced and wide — at
    /// 80 pt the session name clipped to "OBS…", which tells you nothing. 124 pt fits ~10
    /// characters and still leaves ~680 pt of menu bar free on each side: menus grow
    /// rightward from the left edge and status items grow leftward from the right edge, so
    /// the strip beside the notch is the last real estate either one claims.
    static let flankCompact: CGFloat = 124
    static let flankExpanded: CGFloat = 168
    static let panelCornerRadius: CGFloat = 18
    static let flankCornerRadius: CGFloat = 9

    static let textPrimary = Color(red: 0.961, green: 0.965, blue: 0.961)   // --text-primary
    static let textSecondary = Color(red: 0.604, green: 0.624, blue: 0.627) // --text-secondary
    static let textTertiary = Color(red: 0.420, green: 0.435, blue: 0.439)  // --text-tertiary
    static let hairline = Color.white.opacity(0.08)
    static let panelFill = Color.black

    // MARK: - Type

    /// Added to every type size in the island. The call sites keep their relative
    /// proportions; this is the one dial for overall legibility, since the whole thing is
    /// read at a glance from a normal sitting distance rather than studied.
    static let fontBump: CGFloat = 2

    /// OCR A carries the machine-readout character: names, states, counts, timings.
    static func ocr(_ size: CGFloat) -> Font {
        FontRegistry.ocrFamily.map { Font.custom($0, fixedSize: size + fontBump) }
            ?? .system(size: size + fontBump, weight: .medium, design: .monospaced)
    }

    /// The `detail` line is prose written for a human. OCR A at 11 pt makes it unreadable,
    /// so structure and content deliberately use different faces.
    static func prose(_ size: CGFloat) -> Font {
        .system(size: size + fontBump, design: .monospaced)
    }
}

enum FontRegistry {
    private(set) static var ocrFamily: String?

    /// Prefer the copy bundled in the app so appearance can't change if the system font
    /// is moved or removed; fall back to a system-installed copy, then to nothing.
    static func register() {
        if let url = Bundle.main.url(forResource: "OCRAEXT", withExtension: "TTF") {
            var error: Unmanaged<CFError>?
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        }
        for candidate in ["OCR A Extended", "OCRAExtended"] {
            if NSFont(name: candidate, size: 12) != nil {
                ocrFamily = candidate
                return
            }
        }
        ocrFamily = nil
    }
}

/// The flanks are flush with the top edge of the screen and continuous with the cutout, so
/// only the outer bottom corner is rounded.
struct FlankShape: Shape {
    let outerEdge: HorizontalEdge
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = min(radius, rect.height / 2, rect.width / 2)
        if outerEdge == .leading {
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
            p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r),
                           control: CGPoint(x: rect.minX, y: rect.maxY))
        } else {
            p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.maxY))
            p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - r),
                           control: CGPoint(x: rect.maxX, y: rect.maxY))
        }
        p.closeSubpath()
        return p
    }
}

/// A state dot. Working and needs-input pulse.
///
/// Deliberately not a SwiftUI `repeatForever` animation: that keeps SwiftUI re-evaluating
/// and cost ~6% CPU continuously while any session was working. A CABasicAnimation runs on
/// the render server instead, so a pulsing dot is free on the main thread.
struct StateDot: View {
    let state: SessionState
    var size: CGFloat = 7

    var body: some View {
        // The frame is not optional: an NSViewRepresentable accepts whatever width SwiftUI
        // proposes, and without this the dot swallowed the flank and squeezed the name
        // down to "OBSID…".
        DotRepresentable(state: state, diameter: size)
            .frame(width: size, height: size)
    }
}

private struct DotRepresentable: NSViewRepresentable {
    let state: SessionState
    let diameter: CGFloat

    func makeNSView(context: Context) -> DotView { DotView(diameter: diameter) }

    func updateNSView(_ view: DotView, context: Context) {
        view.apply(state: state, diameter: diameter)
    }
}

final class DotView: NSView {
    private let dot = CALayer()
    private var currentState: SessionState?
    private var diameter: CGFloat

    init(diameter: CGFloat) {
        self.diameter = diameter
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        wantsLayer = true
        layer?.addSublayer(dot)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: diameter, height: diameter) }

    override func layout() {
        super.layout()
        dot.frame = CGRect(
            x: (bounds.width - diameter) / 2,
            y: (bounds.height - diameter) / 2,
            width: diameter, height: diameter
        )
        dot.cornerRadius = diameter / 2
    }

    func apply(state: SessionState, diameter: CGFloat) {
        if self.diameter != diameter {
            self.diameter = diameter
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
        guard currentState != state else { return }
        currentState = state

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.backgroundColor = NSColor(state.color).cgColor
        CATransaction.commit()

        dot.removeAnimation(forKey: "pulse")
        guard state.pulses else {
            dot.opacity = 1
            return
        }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.35
        pulse.duration = 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dot.add(pulse, forKey: "pulse")
    }
}
