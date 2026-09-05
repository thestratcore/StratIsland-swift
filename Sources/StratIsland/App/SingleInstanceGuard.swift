import Darwin
import Foundation

/// Holds an advisory lock for the process lifetime so raw-binary, Finder, and LaunchAgent
/// launches cannot create overlapping island windows.
final class SingleInstanceGuard {
    private let descriptor: Int32

    static var defaultPath: String {
        NSString(
            string: "~/Library/Application Support/StratIsland/instance.lock"
        ).expandingTildeInPath
    }

    /// Returns `nil` only when another process owns the lock. Infrastructure failures throw
    /// so launch cannot silently continue without single-instance protection.
    static func acquire(at path: String = defaultPath) throws -> SingleInstanceGuard? {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let descriptor = Darwin.open(
            path,
            O_CREAT | O_RDWR | O_EXLOCK | O_NONBLOCK,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            if errno == EWOULDBLOCK { return nil }
            throw SingleInstanceError(operation: "open", code: errno)
        }

        return SingleInstanceGuard(descriptor: descriptor)
    }

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        Darwin.close(descriptor)
    }
}

private struct SingleInstanceError: Error, CustomStringConvertible {
    let operation: String
    let code: Int32

    var description: String {
        "Single-instance \(operation) failed: errno \(code) (\(String(cString: strerror(code))))"
    }
}
