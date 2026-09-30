import AppKit

// ══════════════════════════════════════════════════════════════════════════
// Which sound the app listens to, and when to say something about it.
//
// Ported from Windows AudioSourceRules.cs (2026-09-20). The choice was a checkbox in
// Settings called "microphone", and people in a real interview left it on. The app then
// heard the candidate answering and treated their own words as the next question. The
// owner: "everyone attends interviews in meetings, and this is the main part" — so the
// choice belongs in the toolbar, named for the situation rather than the hardware:
//
//   Interview — the meeting only. Your own voice is never picked up.
//   Practice  — the meeting and your microphone, for practising alone.
// ══════════════════════════════════════════════════════════════════════════
enum AudioSourceRules {

    /// Meeting apps that can be seen from outside. Google Meet runs in a browser tab and
    /// cannot, which is what the second tip is for.
    ///
    /// Matched on the bundle identifier AND the process name, because the same app ships
    /// under different bundle ids across versions (Teams classic vs Teams, Webex vs
    /// Webex Meetings) and a name alone would miss a rename.
    static let meetingBundleFragments = [
        "us.zoom", "zoom.us", "com.microsoft.teams", "com.microsoft.skype.teams",
        "com.cisco.webex", "com.webex", "com.cisco.spark", "com.bluejeans",
        "com.logmein.gotomeeting", "com.skype", "com.ringcentral", "com.slack",
        "com.hnc.discord", "com.amazon.chime", "com.google.chrome.meet",
    ]

    static let meetingProcessNames = [
        "zoom", "zoom.us", "teams", "ms-teams", "msteams", "microsoft teams", "webex",
        "webexmta", "cisco webex meetings", "bluejeans", "gotomeeting", "skype", "lync",
        "ringcentral", "slack", "discord", "chime",
    ]

    static func isMeetingApp(bundleId: String?, name: String?) -> Bool {
        if let b = bundleId?.lowercased(), meetingBundleFragments.contains(where: { b.contains($0) }) {
            return true
        }
        guard let n = name?.lowercased().trimmingCharacters(in: .whitespaces), !n.isEmpty else { return false }
        return meetingProcessNames.contains(n)
    }

    /// True when a meeting app is running on this Mac right now.
    ///
    /// Running, not frontmost: the interviewer's window is in front during an interview,
    /// and this app never is.
    @MainActor
    static func meetingAppRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.activationPolicy != .prohibited &&
            isMeetingApp(bundleId: $0.bundleIdentifier, name: $0.localizedName)
        }
    }

    /// Offer to switch to Interview: the microphone is open and a meeting app is running,
    /// which is the exact setup where the app hears the candidate. Said once per run, so
    /// it never nags.
    static func shouldSuggestInterview(practiceOn: Bool, meetingAppRunning: Bool,
                                       alreadySuggested: Bool) -> Bool {
        practiceOn && meetingAppRunning && !alreadySuggested
    }

    /// Offer to switch to Practice: listening in Interview with no meeting app and nothing
    /// heard for a few minutes, which is what practising alone looks like from here.
    /// Anything shorter would fire during a quiet stretch of a real interview.
    static let quietBeforePracticeTip: TimeInterval = 3 * 60

    static func shouldSuggestPractice(interviewOn: Bool, listening: Bool, meetingAppRunning: Bool,
                                      quietFor: TimeInterval, alreadySuggested: Bool) -> Bool {
        interviewOn && listening && !meetingAppRunning && !alreadySuggested
            && quietFor >= quietBeforePracticeTip
    }

    /// What the toolbar says the app is hearing.
    static func hearingLine(practiceOn: Bool) -> String {
        practiceOn ? "Hearing the meeting and your microphone" : "Hearing the meeting only"
    }

    static let interviewHelp =
        "Interview. Hears the meeting only, so your own answers are never taken as questions. Use this for a real interview in Zoom, Teams or Meet."
    static let practiceHelp =
        "Practice. Hears the meeting and your microphone, for practising on your own or with someone in the room."
}
