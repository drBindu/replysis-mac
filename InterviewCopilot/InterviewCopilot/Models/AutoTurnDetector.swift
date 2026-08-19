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

    /// Quiet required after a QUESTION MARK. Only "?" earns the fast path: it is the one
    /// mark that means the recogniser heard a complete interrogative.
    static let punctuatedSilence: TimeInterval = 0.38
    /// Quiet required otherwise — including after "." and "!".
    ///
    /// A full stop deliberately does NOT get the fast path here. This recogniser emits
    /// periods MID-SENTENCE constantly ("C2C c two. C or w two or full time . Tell me ."),
    /// so treating every "." as a finished thought fired an answer partway through the
    /// question, every time, and the user watched it answer a fragment.
    static let naturalSilence: TimeInterval = 1.0
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

    /// Accept an utterance unless it repeats the one just answered. Timing is no longer
    /// decided here — the recogniser reports that from the audio — so this is only the
    /// duplicate guard plus a record of what was last sent.
    mutating func acceptUtterance(_ question: String, now: Date = Date()) -> Bool {
        let normalized = Self.normalize(question)
        if normalized.caseInsensitiveCompare(lastSubmitted) == .orderedSame,
           now.timeIntervalSince(lastSubmittedAt) < Self.duplicateWindow {
            return false
        }
        lastSubmitted = normalized
        lastSubmittedAt = now
        return true
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

        // "…c two c or" / "…and" / "…between" — the speaker is plainly mid-sentence, no
        // matter how long the pause. Never answer a dangling clause.
        let danglers: Set<String> = ["or", "and", "but", "the", "a", "an", "to", "for",
                                     "with", "of", "in", "on", "at", "is", "are", "was",
                                     "between", "about", "like", "than", "that", "if",
                                     "what", "how", "when", "so"]
        let tailWords = normalized.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        if let lastWord = tailWords.last, danglers.contains(lastWord), !normalized.hasSuffix("?") {
            return false
        }

        // Only a question mark earns the fast path — see the threshold comments.
        let required = normalized.hasSuffix("?") ? Self.punctuatedSilence : Self.naturalSilence
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

        let allWords = q.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "'")))
            .filter { !$0.isEmpty }
        guard !allWords.isEmpty else { return false }

        // Drop leading filler before deciding what kind of sentence this is. People open
        // with "so", "okay", "and", "um" constantly — "So, can you tell me..." is a
        // question, but testing only the literal first word saw "so", matched nothing, and
        // fell through to the multi-sentence rule below, which threw the question away.
        let leadingFiller: Set<String> = ["so", "okay", "ok", "and", "um", "uh", "well",
                                          "now", "alright", "right", "yeah", "hmm", "like",
                                          "just", "then", "also", "actually"]
        var words = allWords
        while let f = words.first, leadingFiller.contains(f), words.count > 1 {
            words.removeFirst()
        }
        guard let first = words.first else { return false }

        // Pure acknowledgement — never worth answering.
        let normalized = words.joined(separator: " ")
        let backchannel: Set<String> = ["okay", "okay sir", "yes", "yes sir", "no", "no sir",
                                        "thanks", "thank you", "hello", "hi", "yeah", "right",
                                        "mhm", "uh huh", "got it", "sure", "correct"]
        if backchannel.contains(normalized) { return false }

        // A self-correction is only a REJECTION when it is all the speaker has said. The
        // transcript accumulates across a turn, so "no, no, I'm asking . you're looking
        // for C2C or W2 . are you there?" begins with a correction and then contains the
        // real question — rejecting on the prefix threw the whole question away and the
        // user sat waiting while nothing happened. Strip the correction, judge what is
        // left, and only reject when nothing substantial remains.
        let restarts = ["no no", "no i am asking", "no i'm asking", "sorry", "wait",
                        "let me rephrase", "i mean", "actually no", "hold on", "one sec",
                        "what i meant", "let me ask", "i want to ask", "i wanted to ask"]
        var remainder = normalized
        var strippedSomething = true
        while strippedSomething {
            strippedSomething = false
            for r in restarts {
                if remainder == r { return false }              // nothing but a correction
                if remainder.hasPrefix(r + " ") {
                    remainder = String(remainder.dropFirst(r.count + 1))
                    strippedSomething = true
                }
            }
        }
        // Re-derive the words from what actually remains after the correction.
        if remainder != normalized {
            let rest = remainder.components(separatedBy: " ").filter { !$0.isEmpty }
            guard rest.count >= 3 else { return false }         // only a fragment left
            words = rest
        }

        let hasQuestionMark = q.contains("?")

        let questionStarters: Set<String> = ["what", "why", "how", "when", "where", "who",
            "which", "can", "could", "would", "will", "do", "does", "did", "are", "is",
            "was", "were", "have", "has", "should", "tell"]
        let commands: Set<String> = ["explain", "describe", "walk", "share", "discuss",
            "design", "implement", "compare", "define", "introduce", "summarize", "write",
            "create", "build", "code", "program", "solve", "develop", "generate", "show"]

        if questionStarters.contains(first) {
            // "tell me" alone is the start of "tell me about..." — still incoming.
            if first == "tell" && words.count <= 2 { return false }
            return words.count >= 2
        }

        if commands.contains(first) { return words.count >= 2 }

        if hasQuestionMark { return words.count >= 2 }

        // A question starter or command ANYWHERE in the opening still counts. Recognisers
        // punctuate mid-sentence ("So . Can you tell me what is difference between . C two")
        // so the interrogative often is not at index 0 even after filler is stripped.
        let opening = Set(words.prefix(6))
        let interrogative = questionStarters.union(commands).union(["difference", "between"])
        if !opening.isDisjoint(with: interrogative) { return words.count >= 4 }

        // Only NOW treat several finished sentences as background talk. This rule exists to
        // skip the interviewer introducing themselves, but recognisers sprinkle periods, so
        // running it before the check above rejected genuine questions for being punctuated.
        if q.filter({ $0 == "." }).count >= 2 { return false }

        // Anything else needs to at least look like a finished, substantial statement.
        guard let last = q.last, last == "." || last == "!" else { return false }
        return words.count >= 5 && q.count >= 20
    }
}
