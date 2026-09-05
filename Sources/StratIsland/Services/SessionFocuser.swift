import AppKit

/// Sends the user back to wherever a session is running.
///
/// cmux is the primary host: a session it launched carries its surface id, which addresses
/// the pane exactly. Terminal.app remains as a fallback for sessions started outside cmux —
/// it costs one branch here, and losing click-to-focus for those would be a regression.
@MainActor
enum SessionFocuser {

    static func focus(session: AgentSession) {
        if let surfaceID = session.surfaceID {
            CmuxControl.focus(surfaceID: surfaceID)
            return
        }
        // Nothing bound this session to a surface. It may have been started before cmux
        // was running, or in Terminal — try the tty path, and fall back to raising
        // whichever host is actually running.
        if TerminalFocuser.focus(session: session) { return }
        if CmuxControl.isRunning { CmuxControl.activate() }
    }
}
