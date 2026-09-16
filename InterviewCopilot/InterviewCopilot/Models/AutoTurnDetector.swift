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

    /// The candidate reading the app's own answer aloud, rather than anyone asking something.
    ///
    /// With one listening mode the microphone is always open, so this is load-bearing: every
    /// answer the candidate reads comes straight back as a transcript, and without this the
    /// app answers its own answer, replaces the text they are half-way through reading, and
    /// charges for it.
    ///
    /// Judged by WORD ORDER, not vocabulary. Both earlier versions counted shared words, and
    /// a follow-up question shares words with the answer it follows by nature — "What
    /// blockers did you usually run into with the team" has five of its seven content words
    /// in the answer on screen and was discarded as an echo. Reading aloud reproduces
    /// sequence, even paraphrased and with recogniser errors; a follow-up borrows isolated
    /// words. A five-word phrase match was not safe either: "How do you make sure your
    /// changes don't break anything else" quotes a phrase straight out of the answer and is a
    /// real question.
    ///
    /// Share of adjacent word pairs that also occur in the previous question + answer,
    /// measured before choosing 0.66:
    ///
    ///     read-backs, incl. SESSION 62 and 66 verbatim     0.75 - 1.00
    ///     follow-ups and new questions                     0.00 - 0.57
    ///
    /// Filler words are dropped first, since the recogniser inserts them into read speech.
    /// Below five words it does not judge: too few pairs for a ratio to mean anything, and
    /// swallowing a real follow-up is worse than one repeated answer.
    static func isEchoOfPrevious(_ text: String, lastQuestion: String, lastAnswer: String) -> Bool {
        // The same question again, at any length, before the floor below. "So what is Java"
        // straight after "What is Java" has only four words and must still be caught.
        let a = strippedForRepeat(text), b = strippedForRepeat(lastQuestion)
        if !a.isEmpty, a == b { return true }

        let spoken = readBackTokens(text)
        guard spoken.count >= 5 else { return false }
        let ref = readBackTokens(lastQuestion + " " + lastAnswer)
        guard ref.count >= 2 else { return false }
        var refPairs = Set<String>()
        for i in 0..<(ref.count - 1) { refPairs.insert(ref[i] + " " + ref[i + 1]) }
        var shared = 0
        for i in 0..<(spoken.count - 1) where refPairs.contains(spoken[i] + " " + spoken[i + 1]) {
            shared += 1
        }
        return Double(shared) / Double(spoken.count - 1) >= 0.66
    }

    private static func readBackTokens(_ s: String) -> [String] {
        let fillers: Set<String> = ["um", "uh", "yeah", "so", "like", "okay", "ok", "hmm",
                                    "hey", "well", "actually"]
        return s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !fillers.contains($0) }
    }

    /// Normalised for repeat-detection: every word kept, leading filler removed. Unlike
    /// normWords this keeps short words — "is" and "of" are exactly what distinguishes
    /// "what is java" from "what of java", and dropping them is how a repeat became invisible.
    /// Remove an opening pleasantry, keeping whatever real question follows it.
    ///
    /// From SESSION 64: "Hello How are you What is Java" was answered "Doing really well,
    /// thanks! Excited to be here" — the greeting was answered and the question thrown
    /// away. The owner then asked twice more, and those repeats look like the bug but are
    /// the symptom: he was reacting to an answer that ignored him.
    ///
    /// A greeting alone is still a greeting and still gets a warm reply — this only strips
    /// when something substantial remains after it, so "Hello, how are you?" is untouched
    /// while "Hello, how are you, what is Java?" becomes "what is Java".
    static func stripLeadingPleasantries(_ text: String) -> String {
        // Longest first: "how are you doing" must be tried before "how are you".
        let openers = ["good morning", "good afternoon", "good evening",
                       "nice to meet you", "how are you doing today", "how are you today",
                       "how is your day going", "how's your day going", "how is your day",
                       "how's your day", "how are you doing", "how are you",
                       "how is it going", "hows it going", "thanks", "thank you",
                       "hello", "hi", "hey", "yeah", "okay", "ok", "so"]
        // The front is trimmed, never the end, and the words keep their own case. This used to
        // trim both ends of a lowercased copy and return THAT, so the question went to the
        // model as "today? tell me about yourself" — no capitals, and the question mark on
        // its last word gone. Measured live, 2026-09-15.
        let separators = CharacterSet(charactersIn: " .,!?-–—")
        func trimmingFront(_ s: Substring) -> Substring {
            s.drop(while: { $0.unicodeScalars.allSatisfy { separators.contains($0) } })
        }
        var out = trimmingFront(Substring(text))
        var changed = true
        while changed {
            changed = false
            let lead = out.lowercased()
            // Lowercasing can change the length of a few non-English letters, and the cut
            // below counts characters, so only strip when the two line up.
            guard lead.count == out.count else { break }
            for o in openers where lead.hasPrefix(o) {
                // Only a word boundary counts: "hi" must not eat the front of "history".
                let after = lead.dropFirst(o.count)
                guard after.isEmpty || after.first == " " || after.first == "," ||
                      after.first == "." || after.first == "?" || after.first == "!" else { continue }
                out = trimmingFront(out.dropFirst(o.count))
                changed = true
                break
            }
        }
        // Never strip everything: a pure greeting is a real thing to answer. Judged on what
        // is left once EVERY opener is gone — testing each step instead kept "how are you?"
        // from "Hello, how are you?", which is still only a greeting, now cut in half.
        let result = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.split(separator: " ").count >= 2 ? result : text
    }

    /// The candidate filling the silence while the answer loads — "good question", "let me
    /// think", "okay" — and nothing else.
    ///
    /// The microphone is open in the one mode, so this is heard, and it arrives in exactly
    /// the window where speech is now joined onto the question being answered. Joined, it
    /// re-asks the question with "let me think" glued on and spends a credit; judged on its
    /// own, "let me think about that" is a finished sentence and replaced the answer with a
    /// reply to itself. It is neither. Step past it.
    static func isStallPhrase(_ text: String) -> Bool {
        var s = " " + text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "'")))
            .filter { !$0.isEmpty }
            .joined(separator: " ") + " "
        guard s.split(separator: " ").count <= 12 else { return false }
        // Longest first, so "that's a good question" is removed before "good question".
        let stalls = ["that's a really good question", "that's a great question", "that's a good question",
                      "thats a great question", "thats a good question", "really good question",
                      "great question", "good question", "interesting question",
                      "let me think about that", "let me think about it", "let me think",
                      "give me a second", "give me a moment", "give me a sec", "just a second",
                      "just a moment", "one second", "one sec", "one moment", "hold on",
                      "let me see", "let me recall", "thank you", "got it", "i see", "sure"]
        // Until nothing changes: one pass leaves the second of "sure sure" behind.
        for p in stalls { while s.contains(" \(p) ") { s = s.replacingOccurrences(of: " \(p) ", with: " ") } }
        let fillers: Set<String> = ["um", "uh", "hmm", "mhm", "okay", "ok", "yeah", "yes", "yep",
                                    "so", "well", "right", "alright", "sure", "thanks", "and",
                                    "oh", "ah", "like", "that", "that's", "it", "is", "a"]
        let left = s.split(separator: " ").map(String.init)
        if left.allSatisfy({ fillers.contains($0) }) { return true }
        // A stall cut in half by the recogniser. Measured: "Sure. Let me" went out with the
        // question it followed, and the "think." that finished it arrived alone — joined onto
        // the question and re-answered. Too short to be anything but the rest of a stall,
        // and only words a stall is made of.
        let stallWords: Set<String> = ["let", "me", "think", "thinking", "second", "sec", "moment",
                                       "see", "question", "good", "great", "really", "give", "just",
                                       "hold", "on", "recall", "one", "interesting", "about"]
        // Words that carry no meaning of their own and only join the stall together. Measured:
        // "Give me a second to think about it." was NOT read as a stall — it opens with "give",
        // the way an interviewer says "Give me an example" — so it was joined onto the question
        // and the whole thing re-answered. Every word has to be stall vocabulary, and at least
        // one of them a real stall word, so "Give me an example." (example) is untouched.
        let joiners: Set<String> = ["to", "for", "it", "that", "this", "the", "a", "an", "of", "my"]
        guard left.count <= 8, left.contains(where: { stallWords.contains($0) }) else {
            return left.count <= 3 && left.allSatisfy { fillers.contains($0) || stallWords.contains($0) }
        }
        return left.allSatisfy { fillers.contains($0) || stallWords.contains($0) || joiners.contains($0) }
    }

    /// The same words twice in a row, kept once.
    ///
    /// With one mode the microphone is always open, and on a laptop without headphones it
    /// hears the interviewer through the speakers while the system tap hears them directly.
    /// The engine takes whichever is louder every 100ms and the two copies do not arrive
    /// together, so the recogniser is given the question twice: measured on this Mac,
    /// "What is Java? What is Java?" and "What is Docker? Is Docker?". Sent like that, the
    /// model is asked a stutter. Only runs of two or more words collapse, so "very very"
    /// stays as spoken.
    static func collapseRepeats(_ text: String) -> String {
        var words = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        func key(_ w: String) -> String { w.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" } }
        var i = 1
        while i < words.count {
            var collapsed = false
            var len = min(i, words.count - i)
            while len >= 1 {
                let first = (0..<len).map { key(words[i - len + $0]) }
                let second = (0..<len).map { key(words[i + $0]) }
                if len >= 2, first.contains(where: { !$0.isEmpty }), first == second {
                    // Keep the question mark if only the second copy had one.
                    let end = words[i + len - 1]
                    words.removeSubrange(i..<(i + len))
                    if let p = end.last, "?.!".contains(p),
                       let q = words[i - 1].last, !"?.!".contains(q) { words[i - 1].append(p) }
                    collapsed = true
                    break
                }
                // The recogniser seldom hears the same words identically twice: measured,
                // "used it in your project?" then "used it in your projects?". A long run whose
                // only difference is one word's ending is still one sentence said twice. Keep
                // the later copy, the fuller hearing. A different word is not an ending, so
                // "tell me about Java, tell me about Python" is left alone.
                // One long word said twice: "a production outage outage." A pair of short words
                // repeating is ordinary speech ("very very", "bye bye"), so only words of six
                // letters or more count, where a repeat is the recogniser and not the speaker.
                if len == 1, first[0] == second[0], first[0].count >= 6 {
                    let end = words[i]
                    words.removeSubrange(i..<(i + 1))
                    if let p = end.last, "?.!".contains(p),
                       let q = words[i - 1].last, !"?.!".contains(q) { words[i - 1].append(p) }
                    collapsed = true
                    break
                }
                if len >= 4, Self.differsByOneEnding(first, second) {
                    words.removeSubrange((i - len)..<i)
                    i = max(1, i - len)
                    collapsed = true
                    break
                }
                len -= 1
            }
            if !collapsed { i += 1 }
        }
        return words.joined(separator: " ")
    }

    /// Nothing but words from the question just asked, in the same order: the second copy of
    /// it arriving late (see collapseRepeats). Heard while its answer loads, it would now be
    /// joined on and the question re-answered with a stutter, for a second credit.
    static func repeatsQuestion(_ text: String, _ question: String) -> Bool {
        let t = readBackTokens(text), q = readBackTokens(question)
        guard !t.isEmpty, t.count <= q.count else { return false }
        for start in 0...(q.count - t.count) where Array(q[start..<(start + t.count)]) == t { return true }
        return false
    }

    /// Exactly one position differs, and only by an ending of up to two letters on a word of
    /// three or more: "project" / "projects", "use" / "used". Anything else is different words.
    private static func differsByOneEnding(_ a: [String], _ b: [String]) -> Bool {
        guard a.count == b.count else { return false }
        var diffs = 0
        for (x, y) in zip(a, b) where x != y {
            let (short, long) = x.count <= y.count ? (x, y) : (y, x)
            guard short.count >= 3, long.hasPrefix(short), long.count - short.count <= 2 else { return false }
            diffs += 1
        }
        return diffs == 1
    }

    /// The candidate's stall caught on the end of the question: "What is Kubernetes? Good
    /// question." Measured live — the stall began before the recogniser called the question
    /// finished, so it arrived inside the same turn and was sent to the model as part of it.
    /// Only whole trailing sentences go, and never the last one standing.
    static func stripTrailingStalls(_ text: String) -> String {
        var parts = sentences(text)
        let before = parts.count
        while parts.count > 1, let last = parts.last, isStallPhrase(last) { parts.removeLast() }
        return parts.count == before ? text : parts.joined(separator: " ")
    }

    /// The last sentence of what was heard.
    static func lastSentence(_ text: String) -> String { sentences(text).last ?? "" }

    /// Sentences, each with its own punctuation. A last one still being spoken is kept too.
    private static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if "?.!".contains(ch) {
                let s = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { out.append(s) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(tail) }
        return out
    }

    /// The candidate talking, not the interviewer asking: about themselves, to nobody, and
    /// not in the shape of a question. "So in my last project I used Java", "We had a
    /// database failure", "What I usually do is check the dashboards".
    ///
    /// The microphone is always open in the one mode, and the candidate starts answering the
    /// moment a question ends — often before the app has. Heard as a question it replaced the
    /// answer with a reply to their own words; heard as more of the question it was glued on.
    /// An interviewer talks about the listener ("you", "your") or asks outright, and the
    /// first-person ways of asking ("I'd like to hear about...", "I want to know...") are
    /// named so they are never mistaken for the candidate.
    /// - Parameter includePlural: also count "we", "our", "us" as the candidate. Only true in
    ///   the window after an answer. Before a question is asked, "we" is the interviewer
    ///   describing the company ("We are building a payments platform"); after the answer is
    ///   up, "we had a database failure at night" is the candidate answering. The same words,
    ///   and only WHEN they are said tells them apart.
    static func soundsLikeCandidate(_ text: String, includePlural: Bool = false) -> Bool {
        let lower = text.lowercased()
        let words = lower
            .components(separatedBy: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "'")))
            .filter { !$0.isEmpty }
        guard words.count >= 2, !text.contains("?") else { return false }
        let asking = ["i want to know", "i'd like to know", "i would like to know", "i want to hear",
                      "i'd like to hear", "i would like to hear", "i want to ask", "i wanted to ask",
                      "i'd like to ask", "i would like to ask", "i want to understand",
                      "i'd like to understand", "i'm curious", "i am curious", "i was wondering",
                      "i wonder", "let me ask", "i have a question", "i have one more question"]
        if asking.contains(where: { lower.contains($0) }) { return false }
        let listener: Set<String> = ["you", "your", "you're", "yours", "yourself", "you've", "you'd", "you'll"]
        if words.contains(where: { listener.contains($0) }) { return false }
        // Singular only. "We" and "our" are how an interviewer describes the company — measured:
        // "We are building a payments platform that handles 10,000 transactions per second" was
        // stepped past as the candidate, and only the question after it was answered.
        var speaker: Set<String> = ["i", "i'm", "im", "i've", "ive", "i'd", "id", "i'll", "my", "me",
                                    "mine", "myself"]
        if includePlural { speaker.formUnion(["we", "we're", "we've", "our", "us"]) }
        let fillers: Set<String> = ["so", "okay", "ok", "and", "um", "uh", "well", "yeah", "yes", "hmm",
                                    "like", "actually", "basically", "sure", "right", "alright"]
        var rest = words[...]
        while let f = rest.first, fillers.contains(f), rest.count > 1 { rest = rest.dropFirst() }
        let whWords: Set<String> = ["what", "why", "how", "when", "where", "who", "which"]
        let openers = whWords.union(["can", "could", "would", "will", "do", "does", "did", "are", "is",
            "was", "were", "have", "has", "should", "tell", "explain", "describe", "walk", "share",
            "discuss", "design", "implement", "compare", "define", "introduce", "summarize", "write",
            "create", "build", "code", "program", "solve", "develop", "generate", "show", "give"])
        if let first = rest.first, openers.contains(first) {
            // "What I usually do is..." opens like a question and is an answer.
            let second = rest.dropFirst().first
            return whWords.contains(first) && second.map { speaker.contains($0) } == true
        }
        return words.contains(where: { speaker.contains($0) })
    }

    /// Trailing sentences that are the candidate — a stall, or the start of their answer —
    /// taken off the end. Never the last one standing.
    static func withoutCandidateTail(_ text: String, includePlural: Bool = false) -> String {
        var parts = sentences(text)
        let before = parts.count
        while parts.count > 1, let last = parts.last,
              isStallPhrase(last) || soundsLikeCandidate(last, includePlural: includePlural) {
            parts.removeLast()
        }
        return parts.count == before ? text : parts.joined(separator: " ")
    }

    /// The finished question in front of the candidate starting to talk, or nil.
    ///
    /// The owner, 2026-09-15: "good question, let me think" after a question, and the answer
    /// came a long time later. The recogniser only reports the end of speech when the ROOM
    /// goes quiet, and the candidate talking keeps it from going quiet — so the answer waited
    /// for them to stop, which is exactly when they needed it. When a finished question is
    /// followed only by the candidate, the question is over and can be answered now.
    /// Demands a real question form, so a statement is never answered early on a guess.
    static func questionBeforeCandidateTail(_ text: String) -> String? {
        let question = withoutCandidateTail(text)
        // The last sentence counts too: context and then the question ("We use Kafka heavily.
        // How would you scale it?") opens with "we", which alone reads as no question at all.
        guard question != text,
              classifyTurnEnding(question) == .finished,
              isLikelyCompleteQuestion(question, requireInterrogative: true)
                || isLikelyCompleteQuestion(lastSentence(question), requireInterrogative: true) else { return nil }
        return question
    }

    private static func strippedForRepeat(_ s: String) -> String {
        var w = s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let filler: Set<String> = ["so", "okay", "ok", "and", "um", "uh", "well", "now",
                                   "alright", "right", "yeah", "hmm", "like", "just", "then",
                                   "also", "actually", "again", "sorry"]
        while let f = w.first, filler.contains(f), w.count > 1 { w.removeFirst() }
        return w.joined(separator: " ")
    }

    /// A "continuation" that is really chopped-up room audio.
    ///
    /// From the owner's log, merged onto a real question and answered at full price:
    ///
    ///   "Big boss . Because . Why ? What's wrong? On. Season two."
    ///   "Now . Which was. Agni. Pariksha . Season two. REST . Elimination. NE ."
    ///
    /// A television, not a person asking anything. isFragmentedNoise refuses to judge below
    /// twelve words and five stops — deliberately, so a real "Okay. Sure." is never caught —
    /// and both of these are nine words. They passed every test and cost a credit each.
    ///
    /// The bar can be stricter on the merge path than on the answer path, because refusing a
    /// merge discards nothing: the fragment is still judged on its own as a possible
    /// question. That asymmetry is what makes a tighter rule safe here and unsafe there.
    static func isChoppyFragment(_ text: String) -> Bool {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = q.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "'")))
            .filter { !$0.isEmpty }
        let stops = q.filter { $0 == "." || $0 == "!" || $0 == "?" }.count
        guard stops >= 3, words.count >= 4 else { return false }
        return Double(words.count) / Double(stops) < 2.5
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
            // "what I do" is not a question, "what is" and "what do you" are. In Practice
            // Auto the same wh-word opens both the question and the rehearsal of its answer,
            // so the word AFTER it is what separates them: a question is about the listener
            // or a subject, a rehearsal is about the speaker.
            if requireInterrogative, words.count >= 2,
               ["i", "we", "my", "our", "id", "ive", "im"].contains(words[1]) {
                return false
            }
            return words.count >= 2
        }

        if commands.contains(first) { return words.count >= 2 }

        if hasQuestionMark { return words.count >= 2 }

        // A question starter or command ANYWHERE in the opening still counts. Recognisers
        // punctuate mid-sentence ("So . Can you tell me what is difference between . C two")
        // so the interrogative often is not at index 0 even after filler is stripped.
        // The user answering, not asking. In Practice Auto they speak BOTH sides — they ask,
        // read the answer, then rehearse it in their own words — and a rehearsal that happens
        // to contain "what" or "how" in its first six words was being answered as a question.
        // "So what I usually do is check the dashboards" is not a question, and answering it
        // costs a credit and replaces the answer the user was in the middle of practising.
        //
        // First person after the filler is the tell. Real questions are about the listener
        // ("what do YOU do") or about a subject ("what is Spring Boot"); a rehearsal is about
        // the speaker. "I want to ask..." opens first-person and IS a question, which is why
        // those phrasings are stripped as restarts before this point.
        if requireInterrogative {
            let selfReferential: Set<String> = ["i", "my", "we", "our", "me", "mine",
                                                "basically", "usually", "generally"]
            if selfReferential.contains(first) { return false }
        }

        let opening = Set(words.prefix(6))
        let interrogative = whWords.union(commands).union(["difference", "between"])
        // In Practice Auto an interrogative buried mid-sentence is not enough — that is the
        // rule that let rehearsals through. Demand it at the front, where a question puts it.
        if !opening.isDisjoint(with: interrogative) {
            if requireInterrogative {
                let front = Set(words.prefix(2))
                return !front.isDisjoint(with: interrogative) && words.count >= 4
            }
            return words.count >= 4
        }

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
