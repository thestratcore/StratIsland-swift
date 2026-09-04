import Foundation
import CoreServices

/// Thin FSEvents wrapper. Costs nothing while the watched trees are quiet, which is what
/// keeps the app at ~0% CPU when no agent is running.
@MainActor
final class FSWatcher {
    private var stream: FSEventStreamRef?
    private let paths: [String]
    private let onChange: () -> Void

    init(paths: [String], onChange: @escaping () -> Void) {
        self.paths = paths
        self.onChange = onChange
    }

    @discardableResult
    func start() -> Bool {
        guard stream == nil else { return true }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FSWatcher>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.onChange() }
        }
        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1, // 100 ms coalescing
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else {
            Diagnostics.logger.error("Unable to create FSEvents stream")
            return false
        }
        FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
        guard FSEventStreamStart(s) else {
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            Diagnostics.logger.error("Unable to start FSEvents stream")
            return false
        }
        stream = s
        return true
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

}

/// The CLIs write these files without a trailing newline and we can catch one mid-write,
/// so every read tolerates a torn file and retries once.
func readJSONObject(at path: String) -> [String: Any]? {
    for attempt in 0..<2 {
        if let data = FileManager.default.contents(atPath: path),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }
        if attempt == 0 { Thread.sleep(forTimeInterval: 0.05) }
    }
    return nil
}

func processIsAlive(_ pid: Int32) -> Bool {
    guard pid > 0 else { return false }
    return kill(pid, 0) == 0 || errno == EPERM
}
