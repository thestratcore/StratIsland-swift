import AppKit

/// Brings the Terminal tab that owns a session to the front.
///
/// This is the fallback path now — cmux addresses a session by surface id, which needs no
/// AppleScript and no Automation permission. It stays for sessions started outside cmux:
/// Terminal's dictionary exposes `tty of tab`, so the whole thing reduces to matching a
/// device path. Background sessions run on a pty owned by the Claude daemon rather than on
/// a Terminal tab, so we walk up the parent chain until a tty resolves to something
/// Terminal knows about.
@MainActor
enum TerminalFocuser {

    /// Returns false when this path cannot serve the session at all — Terminal is not
    /// running, or nothing up the parent chain has a controlling terminal — so the caller
    /// can try something else rather than triggering an Automation prompt for nothing.
    @discardableResult
    static func focus(session: AgentSession) -> Bool {
        guard isRunning, let pid = session.pid else { return false }
        guard let tty = resolveTTY(startingAt: pid) else { return false }
        run(script: focusScript(tty: tty))
        return true
    }

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").isEmpty
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
