import AppKit
import ServiceManagement

/// An agent app with no Dock icon and no menu bar item is an app you can only quit with
/// `killall`. This is the control surface — it deliberately shows no status, because the
/// island is the only readout (built-in display only, by design).
@MainActor
final class StatusItemController: NSObject {
    private var item: NSStatusItem?
    private let store: SessionStore
    private let health: AppHealth

    init(store: SessionStore, health: AppHealth) {
        self.store = store
        self.health = health
        super.init()
    }

    func start() {
        let i = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let icon = Self.menuBarImage() {
            i.button?.image = icon
            i.button?.title = ""
        } else {
            i.button?.title = "◉"
            i.button?.font = NSFont(name: FontRegistry.monoFamily ?? "Menlo", size: 12)
        }
        i.menu = buildMenu()
        item = i
    }

    /// The custom menu bar icon, when one was bundled. Drawn as a *template*: macOS
    /// recolours it for the current appearance and dims it while the menu is open, which is
    /// why only the alpha channel matters and any colour in the file is discarded.
    /// Absent, the app falls back to a text glyph rather than shipping a blank button.
    private static func menuBarImage() -> NSImage? {
        for ext in ["pdf", "png"] {
            guard let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: ext),
                  let image = NSImage(contentsOf: url) else { continue }
            // 18 pt inside a 22 pt menu bar is roughly what Apple's own items leave. A PDF
            // scales; a bitmap is point-sized here, so a 36 px asset stays crisp on Retina.
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            return image
        }
        return nil
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let mute = NSMenuItem(title: "Mute sounds", action: #selector(toggleMute), keyEquivalent: "m")
        mute.target = self
        mute.state = store.muted ? .on : .off
        mute.identifier = NSUserInterfaceItemIdentifier("mute")
        menu.addItem(mute)

        let healthItem = NSMenuItem(title: "Health: OK", action: nil, keyEquivalent: "")
        healthItem.identifier = NSUserInterfaceItemIdentifier("health")
        healthItem.isEnabled = false
        menu.addItem(healthItem)

        menu.addItem(.separator())

        // Both installers below need no clone: everything they touch is bundled inside
        // Contents/Resources, so a DMG or Homebrew install is enough to finish setup.
        let hooks = NSMenuItem(title: "Install hooks…", action: #selector(installHooks), keyEquivalent: "")
        hooks.target = self
        menu.addItem(hooks)

        let login = NSMenuItem(title: "Start at login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = Self.loginItemEnabled ? .on : .off
        login.identifier = NSUserInterfaceItemIdentifier("login")
        menu.addItem(login)

        menu.addItem(.separator())

        let sock = NSMenuItem(title: "Copy socket path", action: #selector(copySocket), keyEquivalent: "")
        sock.target = self
        menu.addItem(sock)

        let quit = NSMenuItem(title: "Quit StratIsland", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func toggleMute() { store.muted.toggle() }

    @objc private func copySocket() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(PushServer.socketPath, forType: .string)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Install hooks

    /// `install-hooks.sh` and its script are bundled alongside the app (see package.sh) so
    /// setup needs no clone — a DMG or Homebrew install already has everything it runs.
    @objc private func installHooks() {
        guard let script = Bundle.main.url(forResource: "install-hooks", withExtension: "sh") else {
            present(title: "Install hooks", message: "install-hooks.sh is missing from this build.")
            return
        }
        runInstallHooks(script: script, force: false)
    }

    private func runInstallHooks(script: URL, force: Bool) {
        Task.detached {
            let result = Self.runShellScript(script, arguments: force ? ["--force"] : [])
            await MainActor.run { self.presentHooksResult(result, script: script) }
        }
    }

    /// Off the main actor: the hooks script shells out to python3 and does file I/O, and
    /// none of that should be able to stall the island.
    private nonisolated static func runShellScript(_ script: URL, arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return "Failed to run install-hooks.sh: \(error)"
        }
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func presentHooksResult(_ output: String, script: URL) {
        // Codex allows exactly one `notify` program; the script warns rather than clobbering
        // someone else's, and this is the second run that consents to replacing it.
        let offerForce = output.contains("root notify already exists")
        let alert = NSAlert()
        alert.messageText = "Install hooks"
        alert.informativeText = output.isEmpty ? "No output." : output
        alert.addButton(withTitle: "OK")
        if offerForce { alert.addButton(withTitle: "Replace existing notify") }
        if alert.runModal() == .alertSecondButtonReturn, offerForce {
            runInstallHooks(script: script, force: true)
        }
    }

    private func present(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Start at login

    /// Backed by SMAppService rather than the LaunchAgent scripts/install-launchagent.sh
    /// installs: it needs no plist and works from wherever the app was installed —
    /// /Applications via the DMG or Homebrew, not just a build/ directory in a clone.
    private static var loginItemEnabled: Bool { SMAppService.mainApp.status == .enabled }

    @objc private func toggleLoginItem() {
        do {
            if Self.loginItemEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            present(title: "Start at login", message: "Couldn't change login item: \(error.localizedDescription)")
        }
    }
}

extension StatusItemController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        menu.items.first { $0.identifier?.rawValue == "mute" }?.state = store.muted ? .on : .off
        menu.items.first { $0.identifier?.rawValue == "login" }?.state = Self.loginItemEnabled ? .on : .off
        let lines = health.menuLines
        menu.items.first { $0.identifier?.rawValue == "health" }?.title = lines.isEmpty
            ? "Health: OK"
            : "Health: " + lines.map { "\($0.0.rawValue): \($0.1)" }.joined(separator: "; ")
    }
}
