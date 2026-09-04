import AppKit

/// Brings the Terminal tab that owns a session to the front.
///
/// Terminal.app is the only terminal on this machine, and its AppleScript dictionary
/// exposes `tty of tab`, so the whole thing reduces to matching a device path. Background
/// sessions run on a pty owned by the Claude daemon rather than on a Terminal tab, so we
/// walk up the parent chain until a tty resolves to something Terminal knows about.
@MainActor
enum TerminalFocuser {

    static func focus(session: AgentSession) {
        guard let pid = session.pid else { return }
        guard let tty = resolveTTY(startingAt: pid) else {
            // No tty anywhere up the chain: the best we can do is raise Terminal.
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
            return
        }
        run(script: focusScript(tty: tty))
    }

    /// Walk pid -> ppid until a controlling terminal appears (max 8 hops).
    private static func resolveTTY(startingAt pid: Int32) -> String? {
        var current: Int32? = pid
        for _ in 0..<8 {
            guard let p = current, p > 1 else { return nil }
            if let tty = processTTY(p) { return tty }
            current = parentPID(p)
        }
        return nil
    }

    private static func focusScript(tty: String) -> String {
        """
        tell application "Terminal"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        if tty of t is "\(tty)" then
                            set selected of t to true
                            set index of w to 1
                            return
                        end if
                    end try
                end repeat
            end repeat
        end tell
        """
    }

    private static func run(script: String) {
        // Off the main actor would be nicer, but NSAppleScript wants a run loop and these
        // scripts complete in single-digit milliseconds.
        var error: NSDictionary?
        guard let s = NSAppleScript(source: script) else { return }
        s.executeAndReturnError(&error)
        if let error {
            NSLog("StratIsland: Terminal focus failed: \(error)")
        }
    }
}
