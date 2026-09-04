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
        nc.addObserver(self, selector: #selector(evaluate),
                       name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(evaluate),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(evaluate),
                       name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(evaluate),
                       name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        evaluate()
    }

    @objc private func evaluate() {
        let hidden = detectFullScreen()
        guard hidden != menuBarHidden else { return }
        menuBarHidden = hidden
        // While the menu bar is hidden, watch for the cursor being pushed to the top edge,
        // which is what reveals it. The monitor only runs in that state.
        if hidden { installMouseMonitor() } else { removeMouseMonitor() }
        onChange()
    }

    /// A window at layer 0 covering the entire screen means a full-screen space.
    private func detectFullScreen() -> Bool {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
        else { return false }
        let bounds = screen.frame

        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        for win in list {
            guard let layer = win[kCGWindowLayer as String] as? Int, layer == 0,
                  let dict = win[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: dict as CFDictionary)
            else { continue }
            if rect.width >= bounds.width - 1, rect.height >= bounds.height - 1 {
                return true
            }
        }
        return false
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
                } else if !atTop, !self.menuBarHidden, self.detectFullScreen() {
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
