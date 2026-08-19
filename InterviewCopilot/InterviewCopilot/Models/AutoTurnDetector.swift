import Foundation

// ══════════════════════════════════════════════════════════════════════════
// AutoTurnDetector — decides when the interviewer has FINISHED asking, so the
// answer can appear with nothing pressed.
//
// WHY THIS EXISTS: pressing a key while the interviewer watches is the exact
// thing this product exists to avoid. Manual push-to-talk means the candidate
// looks down, finds a key, and is visibly operating something mid-conversation.
//
// The signal is the live transcript file the engine already writes: while
// somebody is speaking it keeps growing, and when they stop it goes still.
// "Still for long enough, and it reads as a complete question" is the trigger.
//
// Firing slightly EARLY is recoverable — the question is deduplicated, and the
// user can interrupt. Firing LATE is not, because the candidate has already sat
// silent in front of the person deciding whether to hire them. The thresholds
// lean early on purpose.
// ══════════════════════════════════════════════════════════════════════════

struct AutoTurnDetector {

    /// Quiet required after a sentence that already ended in ? . or ! — punctuation is
    /// itself strong evidence the thought finished, so little extra waiting is justified.
    static let punctuatedSilence: TimeInterval = 0.38
    /// Quiet required after a trailing-off pause with no closing punctuation, where the
    /// speaker may simply be mid-thought.
    static let naturalSilence: TimeInterval = 0.82
    /// Ignore bursts shorter than this — a click or a cough is not a question.
    static let minimumSpeechDuration: TimeInterval = 0.5
    static let minimumCharacters = 4
    /// A repeat of the same question inside this window is the tail of the one already
    /// answered, not the interviewer asking twice.
    static let duplicateWindow: TimeInterval = 12

    // MARK: - State
    private(set) var lastTranscript = ""
    private(set) var transcriptChangedAt = Date()
    private(set) var listeningStartedAt = Date()
    private(set) var lastSubmitted = ""
    private(set) var lastSubmittedAt = Date.distantPast
    private(set) var isSubmitting = false
    private var lastRejected = ""

    mutating func reset() {
        lastTranscript = ""
        transcriptChangedAt = Date()
        listeningStartedAt = Date()
        isSubmitting = false
    }

    mutating func markSubmitting(_ question: String) {
        isSubmitting = true
        lastSubmitted = Self.normalize(question)
        lastSubmittedAt = Date()
    }

    /// Feed the latest transcript. Returns true when the turn looks finished and the
    /// question should be sent now.
    mutating func shouldSubmit(transcript: String, now: Date = Date()) -> Bool {
        let question = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

        // ANY change means they are still talking — restart the quiet clock.
        //
        // This used to test `question.count > lastTranscript.count`, i.e. growth only. But
        // a recogniser revises: "i work on a p i s" becomes "I work on APIs", which is
        // CHANGED and SHORTER. With a growth-only test that revision was invisible, so the
        // quiet clock kept running from an older timestamp and the turn could fire while
        // the sentence was still being corrected — and lastTranscript stayed stuck on the
        // longer stale text. Comparing content catches every revision, in both directions.
        if question != lastTranscript {
            lastTranscript = question
            transcriptChangedAt = now
        }
        guard !isSubmitting else { return false }
        guard question.count >= Self.minimumCharacters else { return false }
        guard now.timeIntervalSince(listeningStartedAt) >= Self.minimumSpeechDuration else { return false }

        let normalized = Self.normalize(question)
        guard Self.isLikelyCompleteQuestion(normalized) else {
            // Only log a given rejected text once, or this fires ~7x/second.
            if normalized != lastRejected {
                lastRejected = normalized
                Task { @MainActor in
                    dlog("AUTO: waiting — not a complete question yet: '\(normalized.prefix(60))'", tag: "AUTO")
                }
            }
            return false
        }

        // The same question again within the window is the tail of the one just answered.
        if normalized.caseInsensitiveCompare(lastSubmitted) == .orderedSame,
           now.timeIntervalSince(lastSubmittedAt) < Self.duplicateWindow {
            return false
        }

        let last = normalized.last
        let punctuated = (last == "?" || last == "." || last == "!")
        let required = punctuated ? Self.punctuatedSilence : Self.naturalSilence
        return now.timeIntervalSince(transcriptChangedAt) >= required
    }

    // MARK: - Heuristics

    static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Is this a real question worth spending a credit and an answer on, rather than
    /// backchannel ("okay", "yes sir") or half a sentence still being spoken?
    static func isLikelyCompleteQuestion(_ question: String) -> Bool {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return false }

        let words = q.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "'")))
            .filter { !$0.isEmpty }
        guard let first = words.first else { return false }

        // Pure acknowledgement — never worth answering.
        let normalized = words.joined(separator: " ")
        let backchannel: Set<String> = ["okay", "okay sir", "yes", "yes sir", "no", "no sir",
                                        "thanks", "thank you", "hello", "hi", "yeah", "right",
                                        "mhm", "uh huh", "got it", "sure", "correct"]
        if backchannel.contains(normalized) { return false }

        // A speaker correcting or restarting themselves is mid-thought, never finished.
        // Recognisers add a "?" on rising intonation, so "no, no I am asking?" would
        // otherwise pass the question-mark test and fire on a fragment while the real
        // question was still coming.
        let restarts = ["no no", "no i am asking", "no i'm asking", "sorry", "wait",
                        "let me rephrase", "i mean", "actually no", "hold on", "one sec",
                        "what i meant", "let me ask", "i want to ask", "i wanted to ask"]
        for r in restarts where normalized == r || normalized.hasPrefix(r + " ") {
            return false
        }

        let hasQuestionMark = q.contains("?")

        let questionStarters: Set<String> = ["what", "why", "how", "when", "where", "who",
            "which", "can", "could", "would", "will", "do", "does", "did", "are", "is",
            "was", "were", "have", "has", "should", "tell"]
        if questionStarters.contains(first) {
            // "tell me" alone is the start of "tell me about..." — still incoming.
            if first == "tell" && words.count <= 2 { return false }
            return words.count >= 2
        }

        let commands: Set<String> = ["explain", "describe", "walk", "share", "discuss",
            "design", "implement", "compare", "define", "introduce", "summarize", "write",
            "create", "build", "code", "program", "solve", "develop", "generate", "show"]
        if commands.contains(first) { return words.count >= 2 }

        if hasQuestionMark { return words.count >= 2 }

        // Several finished sentences with no question marker is usually the interviewer
        // talking about themselves or the company, not asking anything.
        if q.filter({ $0 == "." }).count >= 2 { return false }

        // Anything else needs to at least look like a finished, substantial statement.
        guard let last = q.last, last == "." || last == "!" else { return false }
        return words.count >= 5 && q.count >= 20
    }
}
