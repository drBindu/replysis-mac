import Foundation

// ══════════════════════════════════════════════════════════════════════════
// ListeningMode — how each question starts.
//
// The distinction that matters is not "auto vs manual" but WHOSE VOICE is
// being listened to. In a real interview the candidate's own mic must stay
// shut: the orange macOS mic indicator is visible, and anything the candidate
// says would otherwise be transcribed and answered as though the interviewer
// had asked it. When practising alone there is no meeting audio to capture, so
// the mic is the only possible source.
// ══════════════════════════════════════════════════════════════════════════

enum ListeningMode: String, CaseIterable, Identifiable {
    case manual
    case interviewAuto
    case practiceAuto

    var id: String { rawValue }

    /// Does the app decide when the question ended, rather than the user pressing Space?
    var isAutomatic: Bool { self != .manual }

    /// Should the microphone be captured in this mode?
    ///
    ///   Manual          mic + system  — the user drives it, and may be speaking themselves
    ///   Interview Auto  system only   — the ONLY mode that closes the mic, on purpose: the
    ///                                   candidate's own voice must never be transcribed and
    ///                                   answered as though the interviewer had asked it
    ///   Practice Auto   mic + system  — rehearsing alone, so the user's voice is the only input
    ///
    /// If two modes ever agree on BOTH this and isAutomatic, they are the same mode.
    var usesMicrophone: Bool { self != .interviewAuto }

    var title: String {
        switch self {
        case .manual:        return "Manual"
        case .interviewAuto: return "Interview Auto"
        case .practiceAuto:  return "Practice Auto"
        }
    }

    var subtitle: String {
        switch self {
        case .manual:        return "Press Space to listen, then Space to answer"
        case .interviewAuto: return "Meeting audio only · microphone stays off"
        case .practiceAuto:  return "Ask with your voice · no meeting required"
        }
    }

    /// Short label for the header pill.
    var pillLabel: String {
        switch self {
        case .manual:        return "MANUAL"
        case .interviewAuto: return "INTERVIEW AUTO"
        case .practiceAuto:  return "PRACTICE AUTO"
        }
    }

    var icon: String {
        switch self {
        case .manual:        return "play.fill"
        case .interviewAuto: return "display"
        case .practiceAuto:  return "mic.fill"
        }
    }
}
