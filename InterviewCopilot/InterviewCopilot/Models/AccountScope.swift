import Foundation

// ══════════════════════════════════════════════════════════════════════════
// One person's resume, job details, hints and interviews must not be there for the next person
// to sign in on the same Mac.
//
// Found by testing as a second account (2026-10-02): signing out and signing in as someone else
// left the first person's resume, company, pay expectation and work authorization in the Setup
// page, every earlier interview in Past Sessions, and their last answer on screen. The app
// cleared the sign-in and the debug log and nothing else.
//
// The rule is about the PERSON, not the sign-out: the same person signing out and back in keeps
// their saved resumes and sessions, and a session that merely expired must never wipe them.
// A different account id is what means the files belong to someone else.
// ══════════════════════════════════════════════════════════════════════════
enum AccountScope {
    /// Whether the data on this Mac belongs to someone other than `current`.
    /// When no account was ever recorded, whatever is here is kept: it could only be this person's,
    /// and a first launch after this change must not delete anybody's interviews.
    static func isDifferentPerson(previous: String?, current: String) -> Bool {
        let p = (previous ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let c = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty, !c.isEmpty else { return false }
        return p != c
    }

    /// Whether a file or folder in the app's data folder is one person's own.
    /// Settings, onboarding and engine state are the machine's, not a person's.
    static func isPersonal(_ name: String) -> Bool {
        if ["resume.txt", "job.json", "hints.txt", "vocab.txt", "resumes"].contains(name) { return true }
        if name.hasPrefix("interview_") && name.hasSuffix(".txt") { return true }   // transcripts
        if name.hasPrefix("recording") { return true }                              // session audio
        return false
    }
}
