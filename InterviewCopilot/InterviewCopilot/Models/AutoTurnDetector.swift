import Foundation

// ══════════════════════════════════════════════════════════════════════════
// AutoTurnDetector — decides whether what was just heard is worth answering,
// so the answer can appear with nothing pressed.
//
// WHY THIS EXISTS: pressing a key while the interviewer watches is the exact
// thing this product exists to avoid. Manual push-to-talk means the candidate
// looks down, finds a key, and is visibly operating something mid-conversation.
//
// WHEN the speaker stopped is no longer decided here. The recogniser has the
// waveform and reports real acoustic silence; MainViewModel acts on that. The
// only judgement left is about MEANING — is this a question, and have we
// already answered it? — which is genuinely a text problem.
//
// A second, text-timing copy of the turn logic used to live in this file:
// silence thresholds, a growth clock, a submitting latch. Nothing has called it
// since the acoustic signal took over, so tuning those numbers changed nothing
// while looking exactly like it should. It is gone. What is left is the part
// that actually runs.
// ══════════════════════════════════════════════════════════════════════════

struct AutoTurnDetector {

    /// A repeat of the same question inside this window is the tail of the one already
    /// answered, not the interviewer asking twice.
    static let duplicateWindow: TimeInterval = 12

    // MARK: - State
    private(set) var lastSubmitted = ""
    private(set) var lastSubmittedAt = Date.distantPast

    /// Accept an utterance unless it repeats the one just answered.
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

    /// Forget what was last answered.
    ///
    /// A duplicate is only a duplicate within one continuous stretch of listening. After a
    /// mode change or a new session, the same question asked again is a genuine question —
    /// not the tail of the one before it. Carrying the guard across made switching from
    /// Interview Auto to Practice Auto and re-asking silently do nothing for 12 seconds.
    mutating func forgetLastAnswered() {
        lastSubmitted = ""
        lastSubmittedAt = .distantPast
    }

    /// Speech that has been judged, is not a question, and never will become one — so the
    /// app must step PAST it instead of carrying it into the next turn.
    ///
    /// The transcript accumulates by design. Inside one turn that is right: a speaker who
    /// pauses mid-question must still get their whole question answered. Across turns it is
    /// fatal. In Practice Auto the candidate says the answer out loud — that is the entire
    /// point of the mode — and none of it is a question, so none of it is ever consumed. The
    /// pile grows, and the moment it carries two full stops with no interrogative in its
    /// opening six words, `isLikelyCompleteQuestion` rejects it and keeps rejecting it: every
    /// later question is glued on and thrown out with it. The app goes permanently deaf until
    /// New Session, which from the user's chair looks like a 7KB latest.txt holding their
    /// entire rehearsal and an app that stopped responding.
    ///
    /// Two ways to be sure the speech is spent, both deliberately conservative so half a
    /// question in flight is never discarded:
    static func isSpentSpeech(_ text: String) -> Bool {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return false }
        let words = q.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "'")))
            .filter { !$0.isEmpty }
        // A question still being formed is SHORT. Speech this long has been running for a
        // while and is not the first half of something incoming — and this is the bound that
        // makes an unbounded pile impossible no matter what the recogniser does with its file.
        if words.count >= 25 { return true }
        // Otherwise only step past it once the speaker has plainly finished the sentence.
        guard let last = q.last, last == "." || last == "!" else { return false }
        return words.count >= 6
    }

    /// Is this transcript shredded into one- and two-word fragments — the shape the
    /// recogniser produces when what it is hearing is not the language it was told to
    /// expect, or is a conversation happening somewhere in the room?
    ///
    /// The engine is configured for English and will map ANY speech onto English words. Talk
    /// to it in Telugu, or let a phone call carry across the room, and it emits confident
    /// nonsense: "CST. Slot. Oh . evening on the . All 12 . Morning. Slot . All . 12 p m on .
    /// Okay." Nothing in the question heuristics rejects that — it is punctuated, it has
    /// plenty of words — so it was answered, and every one of those answers cost a credit.
    ///
    /// Real speech, however badly punctuated, still runs several words between full stops.
    /// Counting that ratio catches the noise without needing to know which language it was.
    static func isFragmentedNoise(_ text: String) -> Bool {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = q.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "'")))
            .filter { !$0.isEmpty }
        // Too short to judge — a genuine "Okay. Sure." is not evidence of anything.
        guard words.count >= 12 else { return false }
        let stops = q.filter { $0 == "." || $0 == "!" || $0 == "?" }.count
        guard stops >= 5 else { return false }
        let wordsPerSentence = Double(words.count) / Double(stops)
        // Even a recogniser that sprinkles full stops mid-sentence leaves ~4+ words between
        // them. Below three, the transcript is confetti.
        return wordsPerSentence < 3.0
    }

    // MARK: - Heuristics

    static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Words that cannot end a finished sentence. "…c two c or", "…difference between",
    /// "…experience with" — the speaker is plainly mid-thought no matter how long they
    /// paused, and answering a dangling clause answers half a question.
    private static let danglers: Set<String> = [
        "or", "and", "but", "the", "a", "an", "to", "for", "with", "of", "in", "on", "at",
        "is", "are", "was", "between", "about", "like", "than", "that", "if", "what",
        "how", "when", "so"
    ]

    /// Is this a real question worth spending a credit and an answer on, rather than
    /// backchannel ("okay", "yes sir") or half a sentence still being spoken?
    /// - Parameter requireInterrogative: demand a real question FORM, refusing statements
    ///   however finished they sound. Practice Auto sets this: the user is alone and phrases
    ///   questions as questions, so every statement it hears is them rehearsing the answer
    ///   out loud — the entire point of the mode — and answering that put the app in a loop
    ///   of answering its own answers, one credit at a time. An interviewer, by contrast,
    ///   really does ask in statements ("I'd like to hear about your Kafka work."), so
    ///   Interview Auto keeps the looser reading.
    static func isLikelyCompleteQuestion(_ question: String, requireInterrogative: Bool = false) -> Bool {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return false }

        let allWords = q.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "'")))
            .filter { !$0.isEmpty }
        guard !allWords.isEmpty else { return false }

        // A trailing joining word means the sentence is not over. Silence proves the speaker
        // PAUSED, never that they finished, so this is the one signal that separates the
        // two — and it was previously unreachable, sitting in the text-timing path that
        // nothing called. A question mark overrides it: the recogniser only emits one when
        // it heard a complete interrogative.
        if let lastWord = allWords.last, danglers.contains(lastWord), !q.hasSuffix("?") {
            return false
        }

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

        // Wh-words and commands mean "question" wherever they appear. Auxiliaries do NOT:
        // they invert only when they LEAD. "Was it hard?" is a question; "I was on an
        // offshore team" is the candidate answering, and counting `was` anywhere in the
        // opening made almost every first-person sentence read as an interrogative — which
        // is precisely how Practice Auto ended up answering the user's own delivery.
        let whWords: Set<String> = ["what", "why", "how", "when", "where", "who", "which"]
        let auxiliaries: Set<String> = ["can", "could", "would", "will", "do", "does", "did",
            "are", "is", "was", "were", "have", "has", "should"]
        let questionStarters = whWords.union(auxiliaries).union(["tell"])
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
        let interrogative = whWords.union(commands).union(["difference", "between"])
        if !opening.isDisjoint(with: interrogative) { return words.count >= 4 }

        // Only NOW treat several finished sentences as background talk. This rule exists to
        // skip the interviewer introducing themselves, but recognisers sprinkle periods, so
        // running it before the check above rejected genuine questions for being punctuated.
        if q.filter({ $0 == "." }).count >= 2 { return false }

        // Anything else needs to at least look like a finished, substantial statement —
        // and in a mode where every statement is the user rehearsing, not even that.
        if requireInterrogative { return false }
        guard let last = q.last, last == "." || last == "!" else { return false }
        return words.count >= 5 && q.count >= 20
    }
}
