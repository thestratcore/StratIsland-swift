import Foundation
import Observation
import os

enum HealthComponent: String, CaseIterable, Comparable {
    case claudeWatcher = "Claude watcher"
    case codexWatcher = "Codex watcher"
    case fileEvents = "File events"
    case pushServer = "Push server"

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

enum Diagnostics {
    static let logger = Logger(subsystem: "com.stratcore.stratisland", category: "runtime")
}

/// User-visible health for runtime components whose failure would otherwise look like
/// an ordinary empty session list.
@MainActor
@Observable
final class AppHealth {
    private(set) var issues: [HealthComponent: String] = [:]

    func report(_ component: HealthComponent, _ message: String) {
        guard issues[component] != message else { return }
        issues[component] = message
        Diagnostics.logger.error("\(component.rawValue, privacy: .public): \(message, privacy: .public)")
    }

    func clear(_ component: HealthComponent) {
        guard issues.removeValue(forKey: component) != nil else { return }
        Diagnostics.logger.info("\(component.rawValue, privacy: .public): recovered")
    }

    var menuLines: [(HealthComponent, String)] {
        issues.sorted { $0.key < $1.key }
    }
}
