import Foundation
import AppKit      // NSSpellChecker — the system dictionary

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
    /// Speech that is not English, transcribed as English anyway.
    ///
    /// The recogniser is configured for English and maps whatever it hears onto English
    /// words, so a Telugu conversation across the room arrives as confident nonsense with
    /// ordinary punctuation. Every structural test passes it: it has words, a verb-ish
    /// shape, a full stop. isFragmentedNoise only catches the confetti case — twelve words
    /// and five full stops — so a six-word burst went straight through and was answered,
    /// at a credit each time.
    ///
    /// This asks a different question: are these English WORDS at all? Foreign speech
    /// forced through an English recogniser produces tokens no dictionary contains, while a
    /// technical question is made of real words even when the jargon is unusual.
    ///
    /// Measured before choosing 0.40, on real phrasings rather than invented ones:
    ///
    ///     worst legitimate     0.22   "Tell me about your work at Zomato and Swiggy"
    ///                          0.11   "How does OAuth2 PKCE differ from the implicit flow"
    ///                          0.10   "Explain gRPC protobuf serialization ..."
    ///     best foreign         0.56   "cara na the me la vata cheppu ela unnav"
    ///                          1.00   "ela unnaru meeru cheppandi konchem"
    ///
    /// Proper nouns and jargon are what would make a dictionary test misfire, so they are
    /// what it was tuned against. An earlier attempt using function-word ratio was discarded
    /// because it could not separate them: "Explain TCP three way handshake" scored 0.20
    /// and the worst nonsense 0.22, so any threshold rejected real questions.
    ///
    /// Below five words this abstains. A short burst has too few tokens for a ratio to mean
    /// anything, and a wrongly discarded question mid-interview is worse than a wasted credit.
    static func looksLikeForeignSpeech(_ text: String) -> Bool {
        let words = text.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 }
        guard words.count >= 5 else { return false }
        let checker = NSSpellChecker.shared
        var unknown = 0
        for w in words {
            let r = checker.checkSpelling(of: w, startingAt: 0, language: "en",
                                          wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
            if r.location != NSNotFound { unknown += 1 }
        }
        return Double(unknown) / Double(words.count) >= 0.40
    }

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

    // ── How the transcript ends ───────────────────────────────────────────────
    //
    // One wait for every question cannot be right: too short and it answers while the
    // interviewer is still asking, too long and the candidate sits in silence after a
    // question that plainly ended. Both were reported on Windows, days apart, from the
    // same setting. So the endings are told apart rather than averaged.
    //
    // This REPLACES a guard that rejected any trailing joining word outright. That was the
    // same instinct pointed too far: it could never answer "What are you looking for?",
    // where the right behaviour is to answer it a little later, not never.

    enum TurnEnding {
        /// Ended on a word no sentence can end on. Never submit — their next word will.
        case unfinished
        /// Punctuated and landing on a real word. Answer quickly.
        case finished
        /// Could go either way. Give them room.
        case unclear
    }

    /// Words no English sentence can end on, whatever the punctuation. The recogniser
    /// punctuates the moment it hears "for", and the options arrive after — "What are you
    /// looking for?" is grammatical and was still followed by "C2C or W2 or full time".
    ///
    /// Conjunctions, prepositions and determiners only. Pronouns are deliberately absent:
    /// "How would you scale this?" and "Have you done that?" are finished questions, and
    /// slowing the ordinary case to guard against a rare one is what went wrong first time.
    private static let neverEndsSentence: Set<String> = [
        "or", "and", "but", "nor", "plus", "versus", "vs",
        "to", "of", "for", "with", "without", "from", "into", "onto",
        "in", "on", "at", "by", "about", "over", "under", "between",
        "the", "a", "an", "my", "our", "your", "their", "its",
        "than", "because", "while", "if", "such", "like", "per",
    ]

    /// Words that, with no punctuation after them, mean the sentence is still running.
    /// Wider than the list above, because without a full stop even "do you" or "have they"
    /// is plainly mid-air.
    private static let danglingTailWords: Set<String> = [
        "is", "are", "was", "were", "be", "been", "being", "am",
        "do", "does", "did", "have", "has", "had",
        "can", "could", "would", "should", "will", "shall", "may", "might", "must",
        "you", "we", "they", "he", "she", "it", "i", "that", "this",
        "any", "some", "more", "most", "very", "really", "so",
        "when", "then", "what", "which", "who", "how",
    ]

    static func classifyTurnEnding(_ question: String) -> TurnEnding {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return .unclear }
        let punctuated = (last == "?" || last == "." || last == "!")

        let words = trimmed.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "'")))
            .filter { !$0.isEmpty }
        guard let tail = words.last else { return .unclear }

        // Nothing can follow these and still be a finished sentence, so the speaker is
        // mid-air no matter what the recogniser punctuated.
        if neverEndsSentence.contains(tail) { return punctuated ? .unclear : .unfinished }

        // No full stop yet, and hanging on an auxiliary or a pronoun: still going. Waiting
        // costs nothing, because their next word submits it.
        if !punctuated && danglingTailWords.contains(tail) { return .unfinished }

        // Punctuated and landing on a real word. The ordinary case, and it should feel
        // immediate.
        if punctuated { return .finished }
        return .unclear
    }

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
