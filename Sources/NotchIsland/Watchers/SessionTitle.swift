import Foundation

/// Where a session's *purpose* comes from.
///
/// The obvious field is the wrong one. `~/.claude/sessions/<pid>.json` carries a `name`,
/// but for an interactive session it arrives with `nameSource: "derived"` and is just the
/// working directory in disguise — every session started in the same repo is called
/// "obsidian-stratcore", which says nothing about what that thread is doing. Background
/// jobs are the exception: they get a real, model-written name.
///
/// The real title is in the transcript. Claude Code appends an `ai-title` record to
/// `~/.claude/projects/<slug>/<sessionId>.jsonl` and rewrites it as the conversation moves,
/// so the last one is a current description of the thread. Codex writes no title at all,
/// so its first genuine user message stands in for one.
///
/// Both files are large and append-only, so this reads a tail (or a bounded head) rather
/// than the whole thing, and caches on size so a quiet session costs one `stat`.
@MainActor
enum SessionTitle {

    private struct Cached {
        let title: String?
        let size: Int
        let checked: Date
    }

    private static var claudeCache: [String: Cached] = [:]
    private static var claudePaths: [String: String] = [:]
    private static var codexCache: [String: String?] = [:]

    /// Don't re-read a growing transcript on every FSEvent. A busy session rewrites its
    /// state file several times a second, and each one wakes the watcher; the title moves
    /// on the order of minutes, so re-reading on that cadence is pure waste. Measured: the
    /// 5 s interval this started at cost ~1.1% CPU during an active turn, against 0.0%
    /// idle before titles existed.
    private static let recheckInterval: TimeInterval = 30

    // MARK: - Claude

    static func claude(sessionId: String, cwd: String) -> String? {
        guard let path = transcriptPath(sessionId: sessionId, cwd: cwd) else { return nil }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int)
            .flatMap { $0 } ?? 0

        if let hit = claudeCache[sessionId],
           Date().timeIntervalSince(hit.checked) < recheckInterval,
           hit.title != nil || hit.size == size {
            return hit.title
        }
        let title = readClaudeTitle(path: path)
        claudeCache[sessionId] = Cached(title: title, size: size, checked: Date())
        return title
    }

    /// The slug is the absolute path with every non-alphanumeric character replaced by a
    /// dash. Directory layouts change, so fall back to a search when that guess misses.
    private static func transcriptPath(sessionId: String, cwd: String) -> String? {
        if let cached = claudePaths[sessionId] {
            return FileManager.default.fileExists(atPath: cached) ? cached : nil
        }
        let root = NSString(string: "~/.claude/projects").expandingTildeInPath
        let slug = String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        let guess = "\(root)/\(slug)/\(sessionId).jsonl"
        if FileManager.default.fileExists(atPath: guess) {
            claudePaths[sessionId] = guess
            return guess
        }
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: root) else { return nil }
        for dir in dirs {
            let candidate = "\(root)/\(dir)/\(sessionId).jsonl"
            if FileManager.default.fileExists(atPath: candidate) {
                claudePaths[sessionId] = candidate
                return candidate
            }
        }
        return nil
    }

    /// Read the tail: the newest `ai-title` wins, and a session that has not earned one yet
    /// falls back to what the user last asked for.
    private static func readClaudeTitle(path: String) -> String? {
        // 64 KB covers many `ai-title` records in practice; the wider read is only for a
        // transcript that has written a lot since its last one.
        if let title = scanForTitle(path: path, bytes: 64 * 1024) { return title }
        return scanForTitle(path: path, bytes: 512 * 1024)
    }

    private static func scanForTitle(path: String, bytes: Int) -> String? {
        guard let tail = tailChunk(path: path, bytes: bytes) else { return nil }
        var lastPrompt: String?

        for line in tail.split(separator: "\n").reversed() {
            if line.contains("\"ai-title\"") {
                if let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                   let title = (obj["aiTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !title.isEmpty {
                    return clean(title)
                }
            }
            if lastPrompt == nil, line.contains("\"last-prompt\"") {
                if let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                   let p = (obj["lastPrompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !p.isEmpty {
                    lastPrompt = clean(p)
                }
            }
        }
        return lastPrompt
    }

    // MARK: - Codex

    /// Codex has no title, and its first user message is the injected AGENTS.md context, so
    /// take the first one that reads like something a person typed. A rollout's opening
    /// turns never change, so this is cached for the life of the process.
    static func codex(rolloutPath: String) -> String? {
        if let hit = codexCache[rolloutPath] { return hit }
        var found: String?
        for line in headLines(path: rolloutPath, bytes: 512 * 1024, limit: 400) {
            guard line.contains("\"role\":\"user\"") || line.contains("\"role\": \"user\"") else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  payload["role"] as? String == "user",
                  let content = payload["content"] as? [[String: Any]]
            else { continue }
            let text = content.compactMap { $0["text"] as? String }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Injected context, not a prompt: AGENTS.md headers and <environment_context>
            // style wrappers both arrive as user messages.
            if text.isEmpty || text.hasPrefix("#") || text.hasPrefix("<") { continue }
            found = clean(text)
            break
        }
        codexCache[rolloutPath] = found
        return found
    }

    // MARK: - IO

    private static func tailChunk(path: String, bytes: Int) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let offset = end > UInt64(bytes) ? end - UInt64(bytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func headLines(path: String, bytes: Int, limit: Int) -> [Substring] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: bytes) else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").prefix(limit).map { $0 }
    }

    /// Titles land in a 124 pt flank and a two-line row; newlines and runs of whitespace
    /// would wreck both. A prompt that starts with an absolute path — common with Codex,
    /// where the first message *is* the title — would otherwise spend the whole line on
    /// `/Users/admin/Documents/…`, so paths collapse to their last component.
    private static func clean(_ raw: String) -> String {
        let flat = raw.replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ")
            .map { token -> String in
                let t = String(token)
                guard t.hasPrefix("/") || t.hasPrefix("~/") else { return t }
                let parts = t.split(separator: "/")
                guard parts.count > 2, let last = parts.last else { return t }
                return "…/" + last
            }
            .joined(separator: " ")
        return flat.count > 60 ? String(flat.prefix(59)) + "…" : flat
    }
}
