import AppKit
import CoreGraphics

/// A fixed cadence and bounded movement keep pointer changes predictable.
@MainActor
final class MouseJiggler {
    private(set) var enabled = false
    private(set) var permissionDenied = false
    private var timer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    private var direction: CGFloat = 1

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            })
        }
    }

    func start() {
        guard !enabled else { return }
        guard CGPreflightPostEventAccess() || CGRequestPostEventAccess() else {
            permissionDenied = true
            Diagnostics.logger.error("Mouse jiggler requires Accessibility permission")
            return
        }
        permissionDenied = false
        enabled = true
        direction = 1
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(1))
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer = source
        source.resume()
        Diagnostics.logger.notice("Mouse jiggler enabled")
    }

    func stop() {
        timer?.cancel()
        timer = nil
        if enabled { Diagnostics.logger.notice("Mouse jiggler disabled") }
        enabled = false
    }

    func shutdown() {
        stop()
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
    }

    private func tick() {
        guard CGPreflightPostEventAccess() else {
            stop()
            permissionDenied = true
            Diagnostics.logger.error("Mouse jiggler permission was revoked")
            return
        }
        guard let current = CGEvent(source: nil)?.location else {
            stop()
            Diagnostics.logger.error("Mouse jiggler could not read pointer position")
            return
        }
        let buttons = NSEvent.pressedMouseButtons != 0
        // UInt32.max is the kCGAnyInputEventType sentinel, not imported into Swift.
        let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: UInt32.max)!)
        let displays = NSScreen.screens.compactMap { screen -> CGRect? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return CGDisplayBounds(number.uint32Value)
        }
        guard let target = jiggleTarget(current: current, displays: displays, idleSeconds: idle,
                                        buttonDown: buttons, direction: direction) else { return }
        guard let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                  mouseCursorPosition: target, mouseButton: .left) else {
            stop()
            Diagnostics.logger.error("Mouse jiggler could not create mouse event")
            return
        }
        event.post(tap: .cghidEventTap)
        direction = -direction
    }
}

/// Quartz coordinates are used throughout; the top strip excludes notch/menu hover targets.
func jiggleTarget(current: CGPoint, displays: [CGRect], idleSeconds: Double,
                  buttonDown: Bool, direction: CGFloat) -> CGPoint? {
    guard idleSeconds >= 10, !buttonDown,
          let display = displays.first(where: { $0.contains(current) }),
          current.y >= display.minY + 80 else { return nil }
    let step: CGFloat = direction < 0 ? -1 : 1
    let candidate = CGPoint(x: current.x + step, y: current.y)
    if display.contains(candidate) { return candidate }
    let reverse = CGPoint(x: current.x - step, y: current.y)
    return display.contains(reverse) ? reverse : nil
}
