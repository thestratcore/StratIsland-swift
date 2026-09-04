import AppKit

/// Tracks whether the menu bar is currently on screen. A permanent black shape over a
/// full-screen video is how an app like this gets deleted, so the island hides with the
/// menu bar and comes back when it is revealed.
@MainActor
final class MenuBarVisibility {
    private(set) var menuBarHidden = false
    var onChange: () -> Void = {}

    private var mouseMonitor: Any?

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(evaluateSoon),
                       name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(evaluateSoon),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(evaluate),
                       name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(evaluate),
                       name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        evaluate()
    }

    @objc private func evaluate() {
        let hidden = detectMenuBarHidden()
        // While the menu bar is hidden, watch for the cursor being pushed to the top edge,
        // which is what reveals it. The monitor only runs in that state.
        if hidden != menuBarHidden {
            menuBarHidden = hidden
            if hidden { installMouseMonitor() } else { removeMouseMonitor() }
        }
        // Always notify, even when this state is unchanged: the controller's other gate is
        // whether Terminal is running, and app launch/quit arrives on these same
        // notifications. Returning early here left the island on screen after Terminal
        // quit, until something else happened to poke the store.
        onChange()
    }

    /// Space transitions notify at the start of the animation, when the window list still
    /// describes the space being left. Re-check once it has settled.
    @objc private func evaluateSoon() {
        evaluate()
        for delay in [0.4, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.evaluate() }
            }
        }
    }

    /// Ask about the menu bar directly rather than inferring it from window geometry.
    ///
    /// The window server owns a "Menubar" window at the main-menu level, and it drops off
    /// the on-screen list exactly when the menu bar goes away — full-screen spaces, and
    /// "Automatically hide and show the menu bar" alike. The previous test looked for a
    /// layer-0 window covering the whole screen, which missed every full-screen app that
    /// leaves the menu-bar strip alone (most of them, on a notched display) and could not
    /// be loosened without also matching an ordinary zoomed window.
    private func detectMenuBarHidden() -> Bool {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        for win in list {
            guard let layer = win[kCGWindowLayer as String] as? Int,
                  layer == Int(CGWindowLevelForKey(.mainMenuWindow)),
                  win[kCGWindowOwnerName as String] as? String == "Window Server",
                  let dict = win[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: dict as CFDictionary)
            else { continue }
            if rect.height > 0 { return false }
        }
        return true
    }

    private func installMouseMonitor() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
                else { return }
                let atTop = NSEvent.mouseLocation.y >= screen.frame.maxY - 4
                if atTop, self.menuBarHidden {
                    self.menuBarHidden = false
                    self.onChange()
                } else if !atTop, !self.menuBarHidden, self.detectMenuBarHidden() {
                    self.menuBarHidden = true
                    self.onChange()
                }
            }
        }
    }

    private func removeMouseMonitor() {
        if let m = mouseMonitor { NSEvent.removeMonitor(m) }
        mouseMonitor = nil
    }
}
