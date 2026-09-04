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
    /// Always on. See `startPointerTracking`.
    private var pointerMonitors: [Any] = []
    private var lastShouldShow: Bool?
    /// While an attention flash is on screen, the pointer's position is irrelevant.
    private var attentionUntil: Date?
    private let debugLog = ProcessInfo.processInfo.environment["NOTCHISLAND_DEBUG_LOG"] == "1"
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
        startPointerTracking()
        if debugPinned { setExpanded(true) }
    }

    private func frame(for expanded: Bool, notch: CGRect) -> NSRect {
        // Width is identical in both states: only the height changes, so the flanks stay
        // welded to the edges of the cutout and the island never slides sideways.
        let width = notch.width + Theme.flankWidth * 2
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

    private func scheduleCollapse(after delay: TimeInterval = 0.35) {
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.collapseWork = nil
                self?.setExpanded(false)
            }
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func setExpanded(_ value: Bool) {
        guard expanded != value else { return }
        expanded = value
        log("expanded=\(value)")
        applyFrame(animated: true)
    }

    /// Hover is decided by asking where the pointer is, not by being told.
    ///
    /// SwiftUI's `.onHover` is a tracking area on a window that resizes the moment the
    /// pointer enters it, and it chattered badly in practice — a single pass over the
    /// island logged `inside=true, false, true, false` in a few hundred milliseconds, each
    /// edge fighting the previous one's animation. That is what "auto-hide doesn't work,
    /// but not every time" looked like from the outside: whichever edge landed last won.
    ///
    /// A pointer position is unambiguous and has no relationship to the window's animation
    /// state. Global monitors see events destined for other apps (this app is never
    /// frontmost); the local monitor covers the case where it is. The callback is a
    /// rectangle test, and nothing runs while the pointer is still.
    private func startPointerTracking() {
        guard pointerMonitors.isEmpty, !debugPinned else { return }
        let events: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        ]
        let global = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluatePointer() }
        }
        if let global { pointerMonitors.append(global) }
        let local = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            MainActor.assumeIsolated { self?.evaluatePointer() }
            return event
        }
        if let local { pointerMonitors.append(local) }
    }

    /// Expand when the pointer is over the collapsed island; collapse when it has left the
    /// panel. The two rectangles differ — the island grows on expanding — which is the
    /// hysteresis that stops it flickering at the boundary.
    private func evaluatePointer() {
        guard let panel, let notch = notchRect, !debugPinned, panel.isVisible else { return }
        if let until = attentionUntil, until > Date() { return }
        let pointer = NSEvent.mouseLocation

        if expanded {
            if panel.frame.insetBy(dx: -4, dy: -4).contains(pointer) {
                collapseWork?.cancel()
                collapseWork = nil
            } else if collapseWork == nil {
                scheduleCollapse(after: 0.2)
            }
        } else if frame(for: false, notch: notch).contains(pointer) {
            collapseWork?.cancel()
            collapseWork = nil
            store.acknowledgeAll()   // seeing it counts as acknowledging it
            setExpanded(true)
        }
    }

    private func log(_ message: @autoclosure () -> String) {
        guard debugLog else { return }
        FileHandle.standardError.write("[notchisland] \(message())\n".data(using: .utf8)!)
    }

    /// A transition into `needsInput` briefly expands the island on its own: nothing
    /// progresses until the user acts, so pulling their eye is doing real work.
    func flashForAttention() {
        guard !expanded else { return }
        collapseWork?.cancel()
        attentionUntil = Date().addingTimeInterval(3.5)
        setExpanded(true)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.attentionUntil = nil
                // If the flash pulled the pointer onto the island, hovering takes over from
                // here; otherwise this collapses it.
                if let panel = self.panel,
                   panel.frame.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation) {
                    return
                }
                self.setExpanded(false)
            }
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
        if shouldShow != lastShouldShow {
            lastShouldShow = shouldShow
            log("visibility terminal=\(terminalRunning) attention=\(store.hasAttention) "
                + "menuBarHidden=\(visibility.menuBarHidden) -> show=\(shouldShow)")
        }

        if shouldShow, !panel.isVisible {
            panel.orderFrontRegardless()
        } else if !shouldShow, panel.isVisible {
            collapseNow()
            panel.orderOut(nil)
        }
        // This runs on space changes and app switches, both of which can strand the panel
        // open with the pointer long gone.
        evaluatePointer()
    }

    /// Switching spaces or displays leaves the pointer somewhere unrelated with no exit
    /// event ever delivered, so treat it as leaving.
    func collapseNow() {
        collapseWork?.cancel()
        collapseWork = nil
        setExpanded(false)
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
