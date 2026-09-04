import AppKit
import SwiftUI

/// Holds the delegate for the process lifetime (NSApplication does not retain it).
nonisolated(unsafe) var keepAlive: AnyObject?

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SessionStore()
    private let health = AppHealth()
    private var claude: ClaudeWatcher?
    private var codex: CodexWatcher?
    private var push: PushServer?
    private var window: NotchWindowController?
    private var statusItem: StatusItemController?
    private let visibility = MenuBarVisibility()

    private var lastAttention = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        FontRegistry.register()

        let window = NotchWindowController(store: store, visibility: visibility)
        window.start()
        self.window = window

        let statusItem = StatusItemController(store: store, health: health)
        statusItem.start()
        self.statusItem = statusItem

        claude = ClaudeWatcher(health: health) { [weak self] snaps in
            guard let self else { return }
            self.store.apply(snaps, for: .claude)
            self.afterUpdate()
        }
        claude?.start()

        codex = CodexWatcher(health: health) { [weak self] snaps in
            guard let self else { return }
            self.store.apply(snaps, for: .codex)
            self.afterUpdate()
        }
        codex?.start()

        push = PushServer { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                self.store.applyPush(event)
                self.afterUpdate()
            }
        }
        if push?.start() == true {
            health.clear(.pushServer)
        } else {
            health.report(.pushServer, "Completion hooks cannot reach the app")
        }
    }

    private func afterUpdate() {
        window?.refreshVisibility()
        let needs = store.sessions.contains { $0.state == .needsInput }
        if needs, !lastAttention { window?.flashForAttention() }
        lastAttention = needs
    }

    func applicationWillTerminate(_ notification: Notification) {
        push?.stop()
        claude?.stop()
        codex?.stop()
    }
}

// Top-level code is nonisolated; the delegate and NSApplication are both main-actor.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // LSUIElement is set in Info.plist; this covers running the raw binary directly.
    app.setActivationPolicy(.accessory)
    keepAlive = delegate
    app.run()
}
