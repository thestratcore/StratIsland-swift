import AppKit

enum Sound {
    case finished     // any CLI finished a turn
    case needsInput   // an agent is blocked on the user

    var path: String {
        switch self {
        case .finished:   return "/System/Library/Sounds/Funk.aiff"
        case .needsInput: return "/System/Library/Sounds/Ping.aiff"
        }
    }
}

@MainActor
protocol SoundPlaying: AnyObject {
    func play(_ sound: Sound)
}

/// macOS exposes no public API for Focus / Do Not Disturb state, so muting is manual —
/// a toggle in the status item rather than a private plist read that breaks each release.
@MainActor
final class SoundPlayer: SoundPlaying {
    private var cache: [String: NSSound] = [:]

    func play(_ sound: Sound) {
        let s: NSSound?
        if let cached = cache[sound.path] {
            s = cached
        } else {
            s = NSSound(contentsOfFile: sound.path, byReference: true)
            if let s { cache[sound.path] = s }
        }
        guard let s else { return }
        if s.isPlaying { s.stop() }
        s.play()
    }
}
