import SwiftUI

/// The five states a session can be in, ordered by how much they demand of the user.
enum SessionState: String, Codable, CaseIterable {
    case needsInput
    case doneUnacked
    case working
    case idle
    case exited

    /// Lower rank == more urgent. Drives which session owns the left flank.
    var urgency: Int {
        switch self {
        case .needsInput:  return 0
        case .doneUnacked: return 1
        case .working:     return 2
        case .idle:        return 3
        case .exited:      return 4
        }
    }

    var label: String {
        switch self {
        case .needsInput:  return "NEEDS YOU"
        case .doneUnacked: return "DONE"
        case .working:     return "WORKING"
        case .idle:        return "IDLE"
        case .exited:      return "EXITED"
        }
    }

    /// Stratcore palette. State is the *only* thing hue encodes — CLI identity is a glyph.
    var color: Color {
        switch self {
        case .needsInput:  return Color(red: 0.910, green: 0.639, blue: 0.239) // amber-500
        case .doneUnacked: return Color(red: 0.498, green: 0.839, blue: 0.741) // green-200
        case .working:     return Color(red: 0.298, green: 0.604, blue: 1.000) // blue-500
        case .idle:        return Color(red: 0.420, green: 0.435, blue: 0.439) // text-tertiary
        case .exited:      return Color(red: 0.227, green: 0.239, blue: 0.243) // dim
        }
    }

    /// Flank form. `label` is what the expanded panel says; this is what fits beside the
    /// cutout, where 144 pt of OCR A is roughly twelve characters.
    var shortLabel: String {
        switch self {
        case .needsInput:  return "NEEDS"
        case .doneUnacked: return "DONE"
        case .working:     return "WORK"
        case .idle:        return "IDLE"
        case .exited:      return "EXIT"
        }
    }

    /// Whether a dot in this state should pulse.
    var pulses: Bool { self == .working || self == .needsInput }
}

/// One state and how many live sessions are in it. The collapsed island reads as a tally
/// rather than as a name, so this is the unit the flank is built from.
struct StateCount: Equatable, Identifiable {
    let state: SessionState
    let count: Int
    var id: SessionState { state }
}
