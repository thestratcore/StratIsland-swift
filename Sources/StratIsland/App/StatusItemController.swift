import AppKit

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
        i.button?.title = "◉"
        i.button?.font = NSFont(name: FontRegistry.ocrFamily ?? "Menlo", size: 12)
        i.menu = buildMenu()
        item = i
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
}

extension StatusItemController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        menu.items.first { $0.identifier?.rawValue == "mute" }?.state = store.muted ? .on : .off
        let lines = health.menuLines
        menu.items.first { $0.identifier?.rawValue == "health" }?.title = lines.isEmpty
            ? "Health: OK"
            : "Health: " + lines.map { "\($0.0.rawValue): \($0.1)" }.joined(separator: "; ")
    }
}
