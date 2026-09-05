import AppKit
import Foundation

/// Drives cmux over its bundled CLI, which speaks to the app's control socket at
/// `~/.local/state/cmux/cmux.sock`.
///
/// Two things make this simpler than the Terminal.app path it replaces. There is a real
/// address for a session — cmux exports `CMUX_SURFACE_ID` into every process it launches,
/// so `surface.focus` takes an id rather than a tty matched against a tab list. And the
/// socket accepts a request from any process running as the user: verified with a scrubbed
/// environment (`env -i`), which is the situation a LaunchAgent launch is in. That means
/// **no Automation permission** — the AppleScript prompt Terminal focusing needed is gone.
@MainActor
enum CmuxControl {

    static let bundleID = "com.cmuxterm.app"

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// `<cmux.app>/Contents/Resources/bin/cmux`, resolved through the bundle id rather than
    /// hardcoded to /Applications.
    static var cliURL: URL? {
        if let cached = cachedCLI { return cached }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        let cli = app.appending(path: "Contents/Resources/bin/cmux")
        guard FileManager.default.isExecutableFile(atPath: cli.path) else { return nil }
        cachedCLI = cli
        return cli
    }

    private static var cachedCLI: URL?

    /// Select the surface, raise the window it lives in, and bring cmux forward.
    ///
    /// The RPC answers with the window and workspace the surface resolved to, so a session
    /// in a background window needs no separate lookup. Both calls are short-lived spawns
    /// on a user click — never on the watch path.
    static func focus(surfaceID: String) {
        guard let cli = cliURL else {
            Diagnostics.logger.error("cmux CLI not found; cannot focus surface")
            activate()
            return
        }
        Task.detached {
            let result = await run(cli, ["rpc", "surface.focus", "{\"surface_id\":\"\(surfaceID)\"}"])
            switch result {
            case .success(let output):
                if let windowID = jsonString(in: output, key: "window_id") {
                    _ = await run(cli, ["rpc", "window.focus", "{\"window_id\":\"\(windowID)\"}"])
                }
            case .failure(let error):
                Diagnostics.logger.error(
                    "cmux surface.focus failed: \(error.message, privacy: .public)"
                )
            }
            await MainActor.run { activate() }
        }
    }

    /// Bring cmux to the front without focusing anything in particular — the fallback when
    /// a session carries no surface binding.
    static func activate() {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// `cmux rpc` prints a JSON object on success and `Error: …` with a non-zero exit on
    /// failure, so the two are told apart by status rather than by parsing the message.
    private nonisolated static func run(
        _ cli: URL, _ arguments: [String]
    ) async -> Result<String, CmuxCLIError> {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = cli
            process.arguments = arguments
            // The CLI is chatty about deprecated command spellings on stderr otherwise.
            process.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "CMUX_QUIET": "1"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
            } catch {
                continuation.resume(returning: .failure(CmuxCLIError(message: "\(error)")))
                return
            }
            let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            process.waitUntilExit()
            let output = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            continuation.resume(
                returning: process.terminationStatus == 0
                    ? .success(output)
                    : .failure(CmuxCLIError(message: output))
            )
        }
    }
}

struct CmuxCLIError: Error {
    let message: String
}

/// One string field out of a small JSON object, without decoding into a type that exists
/// only to be read once.
func jsonString(in output: String, key: String) -> String? {
    guard let data = output.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return obj[key] as? String
}
