import Foundation

// ══════════════════════════════════════════════════════════════════════════
// ListeningMode — WHEN the app answers. Never which audio it hears.
//
// There used to be three modes: Manual, Interview Auto (system audio only) and Practice
// Auto (microphone too). The two automatic modes differed in exactly one thing, which
// audio source was open, and getting that choice wrong failed silently: a real interview
// left on Practice listened to the candidate instead of the interviewer, nothing errored,
// the mic ring lit, and no answer ever arrived. Three names were tried for that choice on
// Windows and renaming a trap does not disarm it, so the choice was deleted instead.
//
// Both sources are now always open. That is only safe because read-back detection
// (AutoTurnDetector.isEchoOfPrevious) stops the app answering the candidate reading an
// answer aloud. The microphone survives as one Settings switch, micCaptureEnabled, which
// is a preference rather than a mode. Matches Windows 178fe36.
// ══════════════════════════════════════════════════════════════════════════

enum ListeningMode: String, CaseIterable, Identifiable {
    case auto
    case manual

    var id: String { rawValue }

    /// Does the app decide when the question ended, rather than the user pressing Space?
    var isAutomatic: Bool { self == .auto }

    /// Settings written before the merge stored "interviewAuto" or "practiceAuto". Both
    /// were automatic, so both become Auto; anything unrecognised is left to the caller.
    static func fromStored(_ raw: String?) -> ListeningMode? {
        switch raw {
        case "auto", "interviewAuto", "practiceAuto": return .auto
        case "manual":                                return .manual
        default:                                      return nil
        }
    }
}
