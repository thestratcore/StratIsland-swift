import Foundation

enum CLIKind: String, Codable {
    case claude
    case codex

    /// CLI identity is carried by a glyph, never by hue.
    var glyph: String {
        switch self {
        case .claude: return "✳"
        case .codex:  return "◇"
        }
    }

    var displayName: String {
        switch self {
        case .claude: return "CLAUDE"
        case .codex:  return "CODEX"
        }
    }
}

enum SessionKind: String, Codable {
    case interactive
    case background

    var badge: String? { self == .background ? "BG" : nil }
}

/// One running subagent / tool call, from Claude's job `fan[]`. Shown only when expanded.
struct FanItem: Identifiable, Equatable {
    let id: String
    let kind: String
    let label: String
    let startedAt: Date?
}

/// A single entity in the island. Claude interactive sessions, Claude background jobs and
/// Codex sessions are all peers here.
struct AgentSession: Identifiable, Equatable {
    let id: String              // "claude:<pid>" or "codex:<pid>"
    var cli: CLIKind
    var kind: SessionKind
    var pid: Int32?
    var sessionId: String?      // Claude's UUID, used to match hook pushes
    var name: String
    var cwd: String
    var state: SessionState
    var detail: String?         // human-readable current action (Claude only in v1)
    var startedAt: Date
    var lastActivity: Date
    var tokens: Int?
    var fan: [FanItem]
    /// When the session entered `doneUnacked`; used for the 60 s auto-ack.
    var doneAt: Date?

    var project: String {
        let base = (cwd as NSString).lastPathComponent
        return base.isEmpty ? "~" : base
    }

    /// Compact-state label: uppercased, truncated to fit an 80 pt flank in OCR A.
    func shortName(max: Int = 11) -> String {
        let raw = name.isEmpty ? project : name
        let up = raw.uppercased()
        if up.count <= max { return up }
        let cut = String(up.prefix(max - 1))
            .trimmingCharacters(in: .whitespaces)
        return cut + "…"
    }

    var elapsed: TimeInterval { Date().timeIntervalSince(startedAt) }

    static func == (a: AgentSession, b: AgentSession) -> Bool {
        a.id == b.id && a.state == b.state && a.detail == b.detail
            && a.tokens == b.tokens && a.fan == b.fan && a.name == b.name
            && a.doneAt == b.doneAt
    }
}

func formatElapsed(_ t: TimeInterval) -> String {
    let s = Int(max(0, t))
    if s < 3600 { return String(format: "%02d:%02d", s / 60, s % 60) }
    return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
}

func formatTokens(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 1_000 { return "\(n / 1000)K" }
    return "\(n)"
}
