import AppKit
import SwiftUI

/// Owns the borderless panel that floats above the menu bar and keeps its frame locked to
/// the physical cutout.
@MainActor
final class NotchWindowController: NSObject {

    private var panel: NSPanel?
    private var hosting: NSHostingView<AnyView>?
    private let store: SessionStore
    private let visibility: MenuBarVisibility

    private var expanded = false
    private var panelHeight: CGFloat = 120
    private var collapseWork: DispatchWorkItem?
    /// Set NOTCHISLAND_DEBUG_EXPANDED=1 to pin the panel open. Hover can't be driven from a
    /// script without tripping the Accessibility prompt, so this is how the expanded layout
    /// gets inspected.
    private let debugPinned = ProcessInfo.processInfo.environment["NOTCHISLAND_DEBUG_EXPANDED"] == "1"

    /// The cutout, derived from the screen rather than hardcoded, so a scaling change or an
    /// external display doesn't leave the island floating in the wrong place.
    private var notchRect: CGRect? {
        for screen in NSScreen.screens {
            guard let l = screen.auxiliaryTopLeftArea,
                  let r = screen.auxiliaryTopRightArea,
                  screen.safeAreaInsets.top > 0 else { continue }
            let width = r.minX - l.maxX
            guard width > 0 else { continue }
            return CGRect(x: l.maxX, y: l.minY, width: width, height: l.height)
        }
        return nil
    }

    init(store: SessionStore, visibility: MenuBarVisibility) {
        self.store = store
        self.visibility = visibility
        super.init()
    }

    func start() {
        build()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        visibility.onChange = { [weak self] in self?.refreshVisibility() }
        visibility.start()
        refreshVisibility()
    }

    // MARK: - Window

    private func build() {
        guard panel == nil, let notch = notchRect else { return }

        let root = AnyView(
            IslandView(
                store: store,
                notchWidth: notch.width,
                notchHeight: notch.height,
                expanded: Binding(get: { [weak self] in self?.expanded ?? false },
                                  set: { [weak self] in self?.setExpanded($0) }),
                onPanelHeight: { [weak self] h in self?.updatePanelHeight(h) }
            )
            .onHover { [weak self] inside in self?.hover(inside) }
        )

        let view = NSHostingView(rootView: root)
        // Non-activating: clicking the island must not steal focus from Terminal, since
        // its whole job is to send you back there.
        let p = NSPanel(
            contentRect: frame(for: false, notch: notch),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.contentView = view
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        p.ignoresMouseEvents = false
        p.hidesOnDeactivate = false
        p.isMovable = false
        p.orderFrontRegardless()

        panel = p
        hosting = view
        if debugPinned { setExpanded(true) }
    }

    private func frame(for expanded: Bool, notch: CGRect) -> NSRect {
        let flank = expanded ? Theme.flankExpanded : Theme.flankCompact
        let width = notch.width + flank * 2
        let height = notch.height + (expanded ? panelHeight : 0)
        return NSRect(
            x: notch.midX - width / 2,
            y: notch.maxY - height,
            width: width,
            height: height
        )
    }

    private func applyFrame(animated: Bool) {
        guard let panel, let notch = notchRect else { return }
        let target = frame(for: expanded, notch: notch)
        guard panel.frame != target else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.28
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
    }

    private func updatePanelHeight(_ h: CGFloat) {
        let clamped = max(60, min(h, 460))
        guard abs(clamped - panelHeight) > 0.5 else { return }
        panelHeight = clamped
        if expanded { applyFrame(animated: true) }
    }

    // MARK: - Expand / collapse

    private func hover(_ inside: Bool) {
        guard !debugPinned else { return }
        collapseWork?.cancel()
        if inside {
            store.acknowledgeAll()   // seeing it counts as acknowledging it
            setExpanded(true)
        } else {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.setExpanded(false) }
            }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }

    private func setExpanded(_ value: Bool) {
        guard expanded != value else { return }
        expanded = value
        applyFrame(animated: true)
    }

    /// A transition into `needsInput` briefly expands the island on its own: nothing
    /// progresses until the user acts, so pulling their eye is doing real work.
    func flashForAttention() {
        guard !expanded else { return }
        setExpanded(true)
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.setExpanded(false) }
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: work)
    }

    // MARK: - Visibility

    func refreshVisibility() {
        guard let panel else { return }
        let terminalRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.apple.Terminal"
        }
        // Terminal-gated, with one override: never hide something that is blocked on the
        // user or has just finished — losing that is the failure that kills trust.
        let shouldShow = (terminalRunning || store.hasAttention)
            && !visibility.menuBarHidden
            && notchRect != nil

        if shouldShow, !panel.isVisible {
            panel.orderFrontRegardless()
        } else if !shouldShow, panel.isVisible {
            setExpanded(false)
            panel.orderOut(nil)
        }
    }

    @objc private func screensChanged() {
        guard let notch = notchRect else {
            panel?.orderOut(nil)
            return
        }
        panel?.setFrame(frame(for: expanded, notch: notch), display: true)
        refreshVisibility()
    }
}
