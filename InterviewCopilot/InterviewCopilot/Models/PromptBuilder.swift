import Foundation

// MARK: - Question Type
enum QuestionType {
    case yesNo, intro, technical, behavioral, situational
    case weakness, whyRole, salary, availability, followUp
    case preference, memoryRecall, contextStatement, logistics, general
    case coding, candidateQuestions, interviewClosing
}

// MARK: - PromptBuilder
class PromptBuilder {

    static let shared = PromptBuilder()

    // Per-session conversation history (max 80 turns)
    private(set) var history: [(q: String, a: String)] = []
    private var coveredTopics: Set<String> = []
    private var mentionedExamples: Set<String> = []
    private var lockedFacts: [String: String] = [:]
    private var cachedSystemPrompt: String?
    private var cachedResumeFacts: String?

    // MARK: - Fact Patterns (same as C# FactPatterns)
    private let factPatterns: [(key: String, qTriggers: [String], aKeywords: [String])] = [
        ("best_language",
         ["language", "lang", "favorite lang", "best lang", "strongest lang",
          "code in", "coding language", "programming language"],
         ["Python", "Java", "JavaScript", "TypeScript", "Go", "Golang", "Rust",
          "C#", "C++", "Kotlin", "Swift", "Ruby", "PHP", "Scala", "Dart"]),

        ("years_experience",
         ["years", "experience", "how long", "long have you", "how many year", "total experience"],
         ["1 year", "2 year", "3 year", "4 year", "5 year", "6 year",
          "1.5", "2.5", "3.5", "4.5", "half a year", "one year", "two year",
          "three year", "four year", "five year"]),

        ("current_employer",
         ["current company", "current employer", "where do you work",
          "currently work", "working now", "current job", "current role"],
         ["Renasant", "Wipro", "Google", "Microsoft", "Amazon", "Apple",
          "Meta", "Netflix", "Uber", "Airbnb", "Stripe"]),

        ("salary_expectation",
         ["salary", "compensation", "pay", "ctc", "how much", "expected salary",
          "rate expectation", "pay expectation"],
         ["$", "k ", "thousand", "lakh", "USD"]),

        ("best_strength",
         ["strength", "best at", "strongest", "excel at", "good at", "top skill", "superpower"],
         ["Java", "Python", "leadership", "problem solving", "architecture",
          "backend", "frontend", "DevOps", "cloud", "communication"]),

        ("education",
         ["education", "degree", "study", "university", "college",
          "school", "master", "bachelor", "graduate"],
         ["Bachelor", "Master", "MS", "BS", "PhD", "B.Tech", "M.Tech",
          "Computer Science", "Engineering", "Roosevelt"]),

        ("relocation",
         ["relocat", "move", "open to moving", "willing to move"],
         ["yes", "no", "absolutely", "open to", "not willing"]),

        ("visa_status",
         ["visa", "stem opt", "work authorization", "sponsorship",
          "authorized to work", "citizen", "green card", "h1b", "h-1b"],
         ["STEM OPT", "H-1B", "citizen", "green card", "EAD", "F-1"]),

        ("start_date",
         ["start date", "when can you start", "notice period",
          "available to join", "earliest start", "join us"],
         ["week", "month", "immediately", "right away", "2 weeks", "4 weeks", "30 days"]),
    ]

    private init() {}

    // MARK: - Public API

    /// Replace fenced code with a marker, keeping the prose around it.
    ///
    /// Every prompt replays the recent turns, so one coding answer rides along in every
    /// question after it — a behavioural question reaching the model with sixty lines of
    /// C++ attached, charged for on every request from then on, against a budget of eight
    /// thousand tokens a minute. Only the NEWEST turn keeps its code, because "can you
    /// optimise that?" needs the thing being optimised.
    ///
    /// The fence count is deliberately not required to be even: streaming produces
    /// unclosed fences constantly, and a half-arrived block is exactly the one most likely
    /// to still be in the newest turn when the next question is asked.
    /// The section titles whose contents are CODE.
    ///
    /// One list, used both to render a section as a code panel and to collapse it out of
    /// history. They were briefly separate and immediately drifted: the collapse knew only
    /// about SOLUTION, so a SQL answer under QUERY rendered as code on screen and still
    /// rode along in every later prompt as code. Two lists of the same thing is how that
    /// happens, so there is one.
    ///
    /// Screen answers are told NOT to use fences — rule 5 sends code straight under these
    /// headers — so collapsing fences alone misses the biggest blocks the app produces.
    static let codeSectionTitles: Set<String> = ["SOLUTION", "QUERY", "FIX", "CODE"]

    static func collapseCodeBlocks(_ text: String) -> String {
        var out = text
        if out.contains("```") {
            let parts = out.components(separatedBy: "```")
            var rebuilt = ""
            for (i, part) in parts.enumerated() {
                // The fence toggles: even parts are prose, odd parts are code. A trailing
                // odd part is an unclosed block, and collapses the same way.
                rebuilt += (i % 2 == 0) ? part : "[code given]"
            }
            out = rebuilt
        }
        // Collapse each code section: everything from its header up to the next header, or
        // to the end when it is the last section. The surrounding PROBLEM / APPROACH /
        // COMPLEXITY prose is what makes the turn worth remembering at all, so it stays.
        var lines = out.components(separatedBy: "\n")
        var kept: [String] = []
        var droppingCode = false
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("━━━") && t.hasSuffix("━━━") && t.count > 6 {
                let title = t.replacingOccurrences(of: "━", with: "")
                    .trimmingCharacters(in: .whitespaces).uppercased()
                droppingCode = codeSectionTitles.contains(title)
                if droppingCode { kept.append("[code given]") ; continue }
                kept.append(line)
                continue
            }
            if !droppingCode { kept.append(line) }
        }
        lines = kept
        out = lines.joined(separator: "\n")
        return out
    }

    // ── Is this question about the screen, or about the person? ───────────────

    /// Phrases that mean the screenshot IS the question. Answering these from the
    /// transcript alone cannot work, however good the model is.
    private static let screenReferencePhrases = [
        "on the screen", "on my screen", "on your screen", "on screen",
        "look at this", "look at the screen", "have a look", "take a look",
        
        "sharing my screen", "share my screen", "shared my screen",
        "in front of you", "shown here", "displayed here", "up on the",
        "solve this", "fix this", "debug this", "explain this",
        "this code", "this error", "this problem", "this question",
        "this diagram", "this snippet", "this function", "this output",
        "what is this", "what's this", "read this", "walk me through this",
        // Added to match the Windows list exactly — these are the ones that make the
        // difference between "what website is open?" being answered from a screenshot and
        // being answered from nothing at all.
        "website is open", "website open", "what website", "which website",
        "what tab", "which tab", "what app", "which app", "what application",
        "what program", "what's open", "what is open", "currently open",
        "currently on your screen", "in your browser", "in your editor",
        "in your ide", "what ide", "which ide",
        // The plainest forms were missing: the list had "on my screen" but not "my
        // screen", so "what is there in my screen now, you tell me" matched NOTHING and
        // was answered from speech by a model that then denied having eyes.
        //
        // Matched by DETERMINER rather than by listing every preposition, which is the
        // Windows rule: "screen" preceded by my/your/the/this/that. That keeps out the
        // screens this app must NOT treat as the desktop — a phone screen, a screening
        // round, screen sharing as a topic — without needing to enumerate them.
        "what am i looking at", "what do i have open",
    ]

    /// "screen" with a determiner in front of it. See screenReferencePhrases.
    private static let screenDeterminers = ["my", "your", "the", "this", "that"]

    /// Questions about the PERSON, which no screenshot can help with.
    ///
    /// Watching a screen was forcing every question down the vision path, so "which
    /// language do you prefer?" came back as an answer about a code editor: a non-answer,
    /// in the wrong shape, having paid to read a picture nobody asked about — and it
    /// quietly tells the interviewer that something is looking at the screen. Behavioural
    /// questions do not stop being asked because a screen is being shared; they are most
    /// of an interview.
    private static let personalQuestionPhrases = [
        "tell me about yourself", "about yourself", "walk me through your",
        "your experience", "your background", "your resume", "your cv",
        "your strength", "your weakness", "your biggest", "your greatest",
        "why do you want", "why are you leaving", "why did you leave",
        "where do you see yourself", "your career", "your goal",
        "do you prefer", "which language do you", "favourite", "favorite",
        "how are you", "salary", "expectation", "notice period",
        "c2c", "w2", "full time", "relocat", "visa", "sponsor",
        "any questions for", "tell me a time", "tell me about a time",
        "have you worked with", "how many years", "comfortable with",
    ]

    static func refersToScreen(_ question: String) -> Bool {
        let q = question.lowercased()
        if screenReferencePhrases.contains(where: { q.contains($0) }) { return true }
        // "<determiner> screen" in any phrasing — in my screen, on your screen, read the
        // screen — without enumerating the prepositions that can precede it.
        //
        // A REGEX, not a substring scan with a next-character check.
        //
        // The trailing \b is the rule actually meant. Substring matching turned "tell me
        // about the screening round" into a screen question — photographing the desktop to
        // answer a question about a phone interview — and patching that with a
        // next-character test is a special case of the boundary that would need extending
        // again the first time somebody says "screen-share". Same result today; the regex
        // is the version that stays correct.
        let pattern = "\\b(?:my|your|the|this|that)\\s+screens?\\b"
        if let re = try? NSRegularExpression(pattern: pattern),
           re.firstMatch(in: q, range: NSRange(q.startIndex..., in: q)) != nil {
            return true
        }
        // "SEE" ONLY WHEN IT POINTS AT SOMETHING. "do you see" and "can you see" were plain
        // substrings, so "Where do you see yourself in five years?" — asked in nearly every
        // interview — took a screenshot and was answered from the desktop, and so was "How do
        // you see a role like this fitting into that path?". Same pattern as Windows cdc86c3.
        return q.range(of: Self.seesSomething, options: .regularExpression) != nil
    }

    private static let seesSomething =
        #"\b(?:can|do|could) you see (?:this|that|it|what i|anything|my|the (?:code|error|output|diagram|question|page|window|chart|problem))\b"#
        + #"(?!\s+(?:role|position|job|team|company|opportunity|as|fitting|working|going|yourself))"#
        + #"|\bwhat do you see\b(?!\s+(?:yourself|as|in|for|when))"#

    /// Deliberately NARROW: anything it is unsure about stays on the screen path, because
    /// while a screen is being shared most questions really are about it.
    static func isPersonalQuestion(_ question: String) -> Bool {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if refersToScreen(trimmed) { return false }   // "this code" always wins
        let q = trimmed.lowercased()
        return personalQuestionPhrases.contains { q.contains($0) }
    }

    // ══════════════════════════════════════════════════════════════════════════
    // MARKDOWN STRIPPING THAT DOES NOT DESTROY CODE
    //
    // The old rule was `\*([^*\n]+)\*` -> `$1`: any paired asterisk, anywhere. Code is
    // full of paired asterisks, so it shredded every code answer the app produced:
    //
    //   ListNode* insertionSortList(ListNode* head)  ->  ListNode insertionSortList(ListNode head)
    //   int *a, *b;                                  ->  int a, b;
    //   def f(*args, **kwargs):                      ->  def f(args, *kwargs):
    //   area = w * h * depth;                        ->  area = w  h  depth;
    //   /* copy */                                   ->  / copy /
    //
    // Not a C++ bug — a paired-delimiter bug. It hit Python, arithmetic and C comments
    // alike, and the candidate was handed code that would not compile with nothing on
    // screen saying it had been altered.
    //
    // Two layers, matching the Windows implementation exactly so the two apps cannot
    // drift on something this expensive:
    //
    //   1. Code regions are lifted out first — fenced blocks AND the ━━━ SOLUTION ━━━
    //      style sections this app actually uses. UNFENCED is the case that bites,
    //      because the prompt asks for section headers rather than fences, so masking
    //      fences alone protects only the answers that happen to arrive fenced.
    //   2. Emphasis is then stripped with delimiters that require real markdown context.
    //
    // Requiring only whitespace around the delimiter is NOT enough — `\S` matches `*`
    // itself, so `**kwargs` survives the whitespace test and is still eaten. The
    // character classes must exclude the delimiter, which is what `[^*\s]` does here.
    //
    // KNOWN ACCEPTED GAP: `__init__` in bare prose still strips, because it is
    // indistinguishable in shape from `__strong__`. Inside a code region it survives.

    private static let mdBold   = "\\*\\*([^*\\s](?:[^*\\n]*[^*\\s])?)\\*\\*"
    private static let mdItalic = "(?<![*\\w])\\*([^*\\s](?:[^*\\n]*[^*\\s])?)\\*(?![*\\w])"
    private static let mdUnder2 = "(?<![A-Za-z0-9_])__([^_\\s](?:[^_\\n]*[^_\\s])?)__(?![A-Za-z0-9_])"
    private static let mdUnder1 = "(?<![A-Za-z0-9_])_([^_\\s](?:[^_\\n]*[^_\\s])?)_(?![A-Za-z0-9_])"

    /// Dunders that are indistinguishable in SHAPE from __strong__, so the underscore
    /// rules cannot tell them apart. Masked before those rules run and restored after.
    /// An allowlist can never misfire on __strong__, because __strong__ is not in it.
    /// Kept identical to the Windows list (ScreenAnalyzer.cs, PythonDunder).
    private static let pythonDunders = [
        "__init__", "__repr__", "__str__", "__len__", "__main__", "__name__",
        "__doc__", "__dict__", "__file__", "__all__", "__enter__", "__exit__",
        "__new__", "__call__", "__iter__", "__next__", "__eq__", "__hash__",
        "__getitem__", "__setitem__", "__contains__", "__slots__",
    ]

    private static func stripEmphasis(_ line: String) -> String {
        var t = line
        // Mask dunders first. U+FFFC is Object Replacement Character — it cannot appear in
        // an answer and carries no markdown meaning, so it survives the rules untouched.
        var masked: [String] = []
        for d in pythonDunders where t.contains(d) {
            t = t.replacingOccurrences(of: d, with: "\u{FFFC}\(masked.count)\u{FFFC}")
            masked.append(d)
        }
        defer { }
        // Order matters: UNDER2 before UNDER1, or __strong__ loses one underscore.
        for p in [mdBold, mdItalic, mdUnder2, mdUnder1] {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t),
                                            withTemplate: "$1")
        }
        for (i, d) in masked.enumerated() {
            t = t.replacingOccurrences(of: "\u{FFFC}\(i)\u{FFFC}", with: d)
        }
        return t
    }

    /// Strip markdown emphasis from prose, leaving every code region byte-identical.
    static func stripMarkdownPreservingCode(_ text: String) -> String {
        var out: [String] = []
        var inFence = false
        var inCodeSection = false
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") {
                inFence.toggle()
                out.append(line)          // the fence line itself is not prose
                continue
            }
            if !inFence, t.hasPrefix("━━━"), t.hasSuffix("━━━"), t.count > 6 {
                let title = t.replacingOccurrences(of: "━", with: "")
                    .trimmingCharacters(in: .whitespaces).uppercased()
                inCodeSection = codeSectionTitles.contains(title)
                out.append(line)
                continue
            }
            out.append(inFence || inCodeSection ? line : stripEmphasis(line))
        }
        return out.joined(separator: "\n")
    }

    func addToHistory(question: String, answer: String) {
        history.append((q: question, a: answer))
        if history.count > 80 { history.removeFirst() }
        trackCoveredContent(text: question + " " + answer)
        if !question.lowercased().contains("screen") {
            extractAndLockFacts(question: question, answer: answer)
        }
    }

    func lastEntryWasScreenAnalysis() -> Bool {
        guard let last = history.last else { return false }
        return last.q.lowercased().contains("screen")
    }

    func clearHistory() {
        history.removeAll()
        coveredTopics.removeAll()
        mentionedExamples.removeAll()
        lockedFacts.removeAll()
        cachedSystemPrompt = nil
        cachedResumeFacts = nil
    }

    func isGreeting(_ q: String) -> Bool {
        let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,").union(.whitespaces))
        let singleWords = ["hi","hello","hey","hi there","good morning","good afternoon",
                           "good evening","greetings","hey there"]
        if singleWords.contains(t) { return true }
        // Catch Speechmatics artifacts: "hello hello", "hello .", "hi hi", "hey hey"
        let baseGreetings = ["hi","hello","hey","greetings"]
        let words = t.split(separator: " ")
            .map { $0.trimmingCharacters(in: CharacterSet.letters.inverted) }
            .filter { !$0.isEmpty }
        if words.count >= 1 && words.count <= 4 && words.allSatisfy({ baseGreetings.contains($0) }) { return true }
        return false
    }

    /// Is this WHOLE utterance small talk — not a question that happens to contain the words?
    ///
    /// It used to ask whether the text CONTAINED "how are you", or contained "how" and "going"
    /// anywhere at all. So "How would you handle a whole region going down?" was answered "Doing
    /// really well, thanks! Excited to be here" — measured in sessions 77 to 83 — and "Hello, how
    /// are you, what is Java" got the same, with the Java question thrown away. A rule that
    /// matches the middle of a sentence cannot tell small talk from an interview question that
    /// shares three ordinary words. The whole thing has to BE the pleasantry.
    func isSmallTalk(_ q: String) -> Bool {
        let phrases: Set<String> = [
            "how are you", "how are you doing", "how r u", "how are u",
            "how is it going", "how's it going", "hows it going", "how goes it",
            "how you doing", "how are things", "how have you been", "how you been",
            "how's everything", "how is everything", "how's your day", "how is your day",
            "how is your day going", "how's your day going",
            "nice to meet you", "good to meet you", "great to meet you", "pleasure to meet you",
            "nice meeting you", "thanks for coming", "thank you for coming",
            "thanks for joining", "thank you for joining", "thanks for having me",
        ]
        var words = q.lowercased()
            .split(whereSeparator: { !$0.isLetter && $0 != "'" })
            .map(String.init)
        // A greeting in front and a politeness behind are part of the same pleasantry.
        let openers: Set<String> = ["hi", "hello", "hey", "yo", "good", "morning", "afternoon",
                                    "evening", "greetings", "there", "so", "okay", "ok", "um",
                                    "uh", "well", "and", "oh"]
        while let f = words.first, openers.contains(f) { words.removeFirst() }
        let trailing: Set<String> = ["today", "sir", "maam", "ma'am", "man", "then", "please",
                                     "though", "yeah", "okay", "ok", "now", "so", "well"]
        while let l = words.last, trailing.contains(l) { words.removeLast() }
        guard !words.isEmpty, words.count <= 5 else { return false }
        return phrases.contains(words.joined(separator: " "))
    }

    /// A pleasantry of either kind, so the answer path can wait for the real question behind it.
    func isGreetingOrSmallTalk(_ q: String) -> Bool { isGreeting(q) || isSmallTalk(q) }

    func isOffTopic(_ q: String) -> Bool {
        let t = q.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,"))
        let words = t.split(separator: " ").map(String.init).filter { !$0.isEmpty }

        let interviewKeywords = ["experience","role","job","work","project","team",
            "skill","salary","company","yourself","background","strength","weakness",
            "why","how do you","tell me","describe","explain","what is","what are",
            "can you","have you","do you","would you","technology","language","framework",
            "start date","visa","relocat","introduce","education","degree","hire",
            "interest","available","notice","relocate"]

        let hasInterviewKeyword = interviewKeywords.contains { t.contains($0) }
        if !hasInterviewKeyword && words.count <= 4 { return true }

        let fillers = ["or really","oh really","really","oh ok","oh okay","ok ok",
            "haha","lol","wow","hmm","uh huh","i see","oh i see","got it",
            "sure sure","alright","ok cool","cool cool","that's funny",
            "that's interesting","interesting","noted","sounds good","makes sense",
            "fair enough","no worries","never mind","nevermind","forget it",
            "my bad","oops"]
        for f in fillers {
            if t == f || t.hasPrefix(f + " ") || t.hasSuffix(" " + f) { return true }
        }
        return false
    }

    func getOffTopicResponse() -> String { "Sorry, could you say that again?" }
    // ROTATED, not fixed. One hard-coded sentence each meant every "how are you" in every
    // interview produced the same words — which is exactly what a canned answer sounds like to
    // the person listening, and the owner heard it come back identically every time.
    private var greetingIndex = 0
    private var smallTalkIndex = 0
    func getGreetingResponse() -> String {
        let options = [
            "Hey, great to be here, really looking forward to this conversation!",
            "Hi! Thanks for making the time, glad to be here.",
            "Hello! Good to meet you, looking forward to it.",
        ]
        defer { greetingIndex += 1 }
        return options[greetingIndex % options.count]
    }
    func getSmallTalkResponse() -> String {
        let options = [
            "Doing really well, thanks! Excited to be here and learn more about the role.",
            "I'm good, thanks for asking. Looking forward to the conversation.",
            "Doing great, thank you. Glad we could set this up.",
            "All good here, thanks! Ready when you are.",
        ]
        defer { smallTalkIndex += 1 }
        return options[smallTalkIndex % options.count]
    }

    // MARK: - Closing turns
    //
    // Ported from Windows PromptBuilder (f0ea569 "Stop asking new questions every time the
    // interviewer says 'anything else?'", and d3a0606 / fbca2c6 after an external review).
    // Same phrases, same order, same test sentences — see tools/regression.
    //
    // The first "do you have any questions for me?" still goes to the model, which asks ONE
    // relevant question. Only repeats and the final sign-off are answered here: a candidate
    // who keeps asking new questions every time the interviewer says "anything else?" is the
    // clearest sign that something is answering for them.

    private static func normalizedTurn(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    /// Words that begin a genuine question or task. When one appears AFTER a closing phrase,
    /// the turn did not end there. Judged on the words after the phrase, never on sentence
    /// punctuation, which speech recognition often drops: "does that answer your question so
    /// how would you test this service" arrives with no punctuation at all.
    private static let requestCue =
        #"\b(how|what|why|when|where|which|who|can you|could you|would you|will you|tell me|tell us|walk me|walk us|explain|describe|design|write|implement|build|create|solve|show me|let's|let us)\b"#

    private static func requestFollows(_ t: String, after end: Int) -> Bool {
        guard end >= 0, end < t.count else { return false }
        let from = t.index(t.startIndex, offsetBy: end)
        return t.range(of: requestCue, options: .regularExpression, range: from..<t.endIndex) != nil
    }

    /// Character offset where the LAST occurrence of any phrase ends, or -1.
    private static func lastEnd(ofPhrases phrases: [String], in t: String) -> Int {
        var end = -1
        for p in phrases {
            if let r = t.range(of: p, options: .backwards) {
                end = max(end, t.distance(from: t.startIndex, to: r.upperBound))
            }
        }
        return end
    }

    /// Character offset where the last match of a pattern ends, or -1.
    private static func lastEnd(ofPattern pattern: String, in t: String) -> Int {
        var end = -1
        var from = t.startIndex
        while from < t.endIndex,
              let r = t.range(of: pattern, options: .regularExpression, range: from..<t.endIndex) {
            end = max(end, t.distance(from: t.startIndex, to: r.upperBound))
            from = r.isEmpty ? t.index(after: r.lowerBound) : r.upperBound
        }
        return end
    }

    /// "Is there another angle on the role, the tech, or the team that you'd like me to focus
    /// on?" is a repeat invitation; "What other angle would you take to reduce the latency?" is
    /// a technical question. The first is about the role or team and asks what to focus on.
    private static let anotherAngleOnRole =
        #"\banother angle\b[^?.!]{0,60}\b(role|team|company|position|job|tech|product)\b[^?.!]{0,60}\b(focus on|like to know|want to know|like me to cover)\b"#

    /// The general forms. The exact-phrase list below caught 7 of 20 ordinary wordings on
    /// Windows. Not "any questions on the approach before you start coding?": that is about a
    /// task, and a wrap-up reply to it ends the exercise.
    private static let invitationPattern =
        #"\bany (?:other |more |further |final |last |additional |follow[- ]?up )?questions?\b(?![^?.!]*\b(?:approach|problem|task|exercise|code|coding|design|requirements?|solution|assignment|start|begin)\b)"#
        + #"|\bany (?:other )?thing (?:else )?(?:you|u) (?:want|like|would like|wanna) to (?:ask|know)\b"#
        + #"|\b(?:do|would|did) (?:you|u) (?:want|wanna|like|have anything) to ask\b"#
        + #"|\b(?:want|like) to ask (?:me |us )?(?:anything|something)\b"#
        + #"|\b(?:anything|something) (?:else )?(?:that )?(?:you|you'd|you would|u) (?:like|want|wanna|would like) to (?:ask|know)\b"#
        + #"|\bis there (?:anything|something) (?:else )?(?:you|you'd|you would|u)\b[^?.!]{0,30}\b(?:ask|know)\b"#
        + #"|\bquestions? for (?:me|us)\b"#

    private static let invitationPhrases = [
        "do you have any questions", "have any questions for me",
        "have any questions for us", "any questions for me", "any questions for us",
        "are there any questions", "is there any questions", "is there any question you have",
        "is there any question do you have", "any question you have",
        "do you still have questions", "do you have still questions", "still have any questions",
        "any other questions", "anything you'd like to ask", "anything you would like to ask",
        "anything you want to ask", "is there anything you want to ask",
        "anything else you'd like to ask", "anything else you would like to ask",
        "what questions do you have", "what else would you like to know",
        "what else do you want to know", "what else do you want to ask",
        // Not "what other angle" or "would you like me to focus on": those are ordinary
        // technical questions and were answered with a fixed sign-off on Windows.
        "is that the level of detail", "did that answer your question",
        "does that answer your question", "did that cover your question",
        "does that cover your question", "do you want me to go deeper",
        "would you like me to go deeper", "want me to go a bit deeper",
        "want me to go deeper", "do you want more detail",
    ]

    /// The answer ends on its last point. Owner, 2026-10-06 (Windows): "it is asking a reverse question".
    /// AnswerClosers is the net under this rule, because a prompt is a request and the model sometimes ignores it.
    static let stopOnLastPointRule = "Stop on your last point. Never end an answer with a question to the interviewer or an offer to say more, such as \"let me know if you want more detail\", \"would you like me to go deeper\", \"does that make sense\" or \"what does your team use\". The only time you ask anything is when the interviewer invites your questions."

    /// The interviewer has handed the conversation to the candidate for questions, or is
    /// checking that an earlier candidate question was answered — and nothing new follows.
    static func isCandidateQuestionInvitation(_ question: String) -> Bool {
        let t = normalizedTurn(question)
        guard !t.isEmpty else { return false }
        let end = max(lastEnd(ofPhrases: invitationPhrases, in: t),
                      lastEnd(ofPattern: anotherAngleOnRole, in: t),
                      lastEnd(ofPattern: invitationPattern, in: t))
        return end >= 0 && !requestFollows(t, after: end)
    }

    /// A real sign-off. Thanking someone for their time is how interviews START as often as
    /// how they end — "Thank you for taking the time... Can you start by telling me about
    /// yourself?" carries on — so a thank-you counts only when nothing follows it.
    static func isInterviewEndStatement(_ question: String) -> Bool {
        let t = normalizedTurn(question)
        guard !t.isEmpty else { return false }

        // Strong closings end the interview unless a question follows them: "We'll be in
        // touch with next steps, but first can you explain your testing approach?" is not one.
        let strong = ["we'll be in touch", "we will be in touch", "we'll follow up",
                      "we will follow up", "that concludes the interview",
                      "this concludes the interview", "that wraps up the interview",
                      "this wraps up the interview"]
        let strongEnd = lastEnd(ofPhrases: strong, in: t)
        if strongEnd >= 0, !requestFollows(t, after: strongEnd) {
            let after = t.index(t.startIndex, offsetBy: strongEnd)
            if !t[after...].contains("?") { return true }
        }

        // Judged from the LAST thank-you onward, so a recap of earlier questions before the
        // thank-you still reads as a goodbye.
        var thanksAt = -1
        for word in ["thank you", "thanks"] {
            if let r = t.range(of: word, options: .backwards) {
                thanksAt = max(thanksAt, t.distance(from: t.startIndex, to: r.lowerBound))
            }
        }
        guard thanksAt >= 0 else { return false }
        let tail = String(t[t.index(t.startIndex, offsetBy: thanksAt)...])
        let signOff = ["taking the time", "for your time", "speaking with me", "speaking with us",
                       "meeting with me", "meeting with us", "joining us today",
                       "talking with me", "talking with us"]
        guard signOff.contains(where: { tail.contains($0) }) else { return false }
        if tail.contains("?") || tail.range(of: requestCue, options: .regularExpression) != nil { return false }
        let carriesOn = ["start", "begin", "move on", "next question", "next round",
                         "next one", "now ", "go ahead", "welcome", "introduce",
                         "background", "coding", "anything", "any final", "thoughts"]
        return !carriesOn.contains(where: { tail.contains($0) })
    }

    /// Short follow-ups that only mean "any more questions?" once the candidate has already
    /// been invited to ask. Earlier in an interview "Anything else?" asks for more on the last
    /// answer, so these are never matched on their own.
    private static let candidateQuestionFollowUp =
        #"^(?:(?:ok|okay|sure|great|cool|alright|all right|perfect|good|yeah|yes|so|and|right|got it)[,.!]?\s+)*"#
        + #"(?:anything else|anything more|something else|is that all|is there anything else"#
        + #"|anything else i can (?:answer|help|clarify|tell)[^?.!]*"#
        + #"|did that help|does that help|was that clear|was that helpful|does that make sense|that make sense|did that make sense)"#
        + #"(?:\s+(?:for you|you want to know|you'd like to know|at all|then))?\s*[?.!]*\s*$"#

    static func isCandidateQuestionFollowUp(_ question: String) -> Bool {
        normalizedTurn(question).range(of: candidateQuestionFollowUp, options: .regularExpression) != nil
    }

    private var priorCandidateQuestionInvitations: Int {
        history.filter { Self.isCandidateQuestionInvitation($0.q) }.count
    }

    private var priorClosingTurns: Int {
        history.filter { Self.isCandidateQuestionInvitation($0.q) || Self.isCandidateQuestionFollowUp($0.q) }.count
    }

    /// A short, human reply to a repeat invitation or a sign-off, or nil when the turn should
    /// go to the model. Varied so the same sentence is never said twice in a row, and never a
    /// new question.
    func closingResponse(to question: String) -> String? {
        let followUp = priorCandidateQuestionInvitations > 0 && Self.isCandidateQuestionFollowUp(question)
        if Self.isCandidateQuestionInvitation(question) || followUp {
            guard priorCandidateQuestionInvitations > 0 else { return nil }
            let checkingItHelped = question.lowercased().range(
                of: #"\b(help|helpful|clear|make sense|answer your question|cover your question|level of detail|go deeper|more detail)\b"#,
                options: .regularExpression) != nil
            let prior = priorClosingTurns
            if checkingItHelped {
                return prior <= 1
                    ? "Yes, that was really helpful, thank you. That covers my questions."
                    : "Yes, it did, thank you. That's everything from me."
            }
            switch prior {
            case ...1: return "That answered what I wanted to know, thank you. I think that covers my questions."
            case 2:    return "No, I'm all set. Thank you for walking me through it."
            default:   return "No, that's everything from me. Thanks again for your time."
            }
        }
        guard Self.isInterviewEndStatement(question) else { return nil }
        return "Thank you for your time. I enjoyed learning more about the role and the team."
    }

    // MARK: - Question Classification

    func classifyQuestion(_ q: String) -> (type: QuestionType, isDrillDown: Bool) {
        return (detectType(q), isDrillDown(q))
    }

    static func isCodingRequest(_ question: String) -> Bool {
        let text = question.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return false }
        let patterns = [
            #"\b(write|show|provide|create|build|implement|develop|generate|code|program|solve)\b.{0,80}\b(code|program|function|method|class|algorithm|solution|snippet|application|api|query|sql)\b"#,
            #"\b(code|program)\s+(this|that|it|me|for me|a|an|the)\b"#,
            #"\bimplement\s+(a|an|the)?\s*[a-z0-9+#. -]{2,60}$"#,
            // Tasks named rather than commanded: "for this next exercise I want a function
            // that...", "the next exercise is a SQL query returning..."
            #"\b(i want|i'd like|i would like|please|next exercise|next task|next problem|coding exercise|coding problem|exercise is|task is|problem is)\b.{0,80}\b(function|method|class|algorithm|query|sql|api|endpoint|program|script|code)\b"#,
        ]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    /// The thing a definition question asks about: "What is a REST API?" gives "REST API".
    /// Empty when there is nothing usable, including "What is Kafka and how have you used
    /// it?" and "What is the difference between X and Y?", which are not "What is X?".
    static func definitionTerm(_ question: String) -> String {
        guard let re = try? NSRegularExpression(
                pattern: #"(?:^|[?.!]\s*)(?:what is|what are|define)\s+(?:an?\s+|the\s+)?(.+?)(?:[?!]|\.(?=\s|$)|$)"#,
                options: [.caseInsensitive]),
              let m = re.firstMatch(in: question, range: NSRange(question.startIndex..., in: question)),
              let r = Range(m.range(at: 1), in: question) else { return "" }
        let raw = String(question[r])
        if raw.range(of: #"\b(and|or|how|why|where|when|which|that|you|your|between|versus|vs|differ|difference|differences|compared|pros|cons|advantages?|disadvantages?)\b|,"#,
                     options: [.regularExpression, .caseInsensitive]) != nil { return "" }
        let term = raw.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"\s+(?:exactly|actually|again|then|really|about)$"#, with: "",
                                  options: [.regularExpression, .caseInsensitive])
        return term.count > 60 ? String(term.prefix(60)).trimmingCharacters(in: .whitespaces) : term
    }

    private static let termFillerWords: Set<String> =
        ["a", "an", "the", "of", "in", "on", "for", "to", "and", "or", "with", "is", "are", "vs", "versus"]

    private static func hasFacts(_ resumeFacts: String) -> Bool {
        let f = resumeFacts.trimmingCharacters(in: .whitespacesAndNewlines)
        return !f.isEmpty && f != "[NO RESUME]" && f != "No resume provided."
    }

    /// True when every meaningful word of the term appears in the candidate's facts, so the
    /// answer may say where it sits in their work. One- and two-letter words ("Go", "C", "R")
    /// must match with a capital, or "go" in ordinary resume prose would count as Go.
    static func factsMention(_ resumeFacts: String, _ term: String) -> Bool {
        guard hasFacts(resumeFacts), !term.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        let words = term.split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ",;:\"'")) }
            .filter { !$0.isEmpty && !termFillerWords.contains($0.lowercased()) }
        guard !words.isEmpty, words.count <= 3 else { return false }
        for word in words {
            let stem = word.count > 3 && word.lowercased().hasSuffix("s") ? String(word.dropLast()) : word
            let short = stem.count <= 2
            let body = short
                ? NSRegularExpression.escapedPattern(for: stem.prefix(1).uppercased()) + NSRegularExpression.escapedPattern(for: String(stem.dropFirst()))
                : NSRegularExpression.escapedPattern(for: stem)
            let pattern = "(?<![A-Za-z0-9])" + body + "(?:e?s)?(?![A-Za-z0-9])"
            let opts: String.CompareOptions = short ? [.regularExpression] : [.regularExpression, .caseInsensitive]
            if resumeFacts.range(of: pattern, options: opts) == nil { return false }
        }
        return true
    }

    /// The format line for "What is X?", chosen in code by whether X is in the candidate's
    /// facts, because only then may the answer say they use it. Told to check the resume
    /// itself, the model still said "Rust's the language I use" for a candidate without it.
    /// Wording copied from Windows, where it was measured against the live model: change it
    /// by testing, not by feel.
    static func definitionReminder(term: String, resumeFacts: String) -> String {
        let t = term.trimmingCharacters(in: .whitespaces).isEmpty ? "it" : term
        let opening =
            "Begin the answer with the words \"\(t) is\" written out in full, starting with a capital letter and with A, An or The in front when English needs it, as in A hash map is. Never write \"\(t)'s\". " +
            "4 or 5 spoken sentences, about 30-40 seconds, with real substance, the way an experienced engineer answers in an interview. " +
            "Cover what it is in plain words, how it actually works underneath with the real mechanism names, and why it matters in real work. " +
            "Sound like a person talking, not an encyclopedia: no filler such as basically, pretty smooth or super, no phrases such as general-purpose, " +
            "is known for or the big advantage is, and never a bare lets you sentence standing in for the explanation. "
        let more =
            "The MORE TO SAY lines are what an experienced engineer would add if pushed: a deeper mechanism, a gotcha, a trade-off, " +
            "or when you'd pick something else. Never claim a tool, project or incident that is not in the verified facts."
        if factsMention(resumeFacts, term) {
            return opening +
                "\(t) is in the verified facts, so the first or second sentence says where it sits in your work, " +
                "without inventing a project or detail that is not in the facts. " +
                "Shape only, never reuse its words: Kafka is a distributed event streaming platform, and at work it's what carries events between our services. " +
                "Producers write to topics, each topic is split into partitions, and every partition is an append-only log that consumers read at their own pace by offset. " +
                "That's what makes it durable, because a consumer that falls over just picks up from its last offset. " +
                "And partitions are how it scales, since consumers in a group split them between them. " +
                more
        }
        let facts = hasFacts(resumeFacts)
        return opening +
            "\(t) is NOT in the verified facts, so never say you use it, have used it, or work with it. " +
            (facts
                ? "End with one honest sentence connecting it to what the verified facts show you do work with, for example your main language or tools, " +
                  "and how the idea carries over. Never imply you have used the term itself. "
                : "") +
            "Shape only, never reuse its words: Rust is a systems language built so the compiler catches memory bugs before the code ever runs. " +
            "It does that with ownership, where every value has exactly one owner, and borrowing rules the compiler checks for you. " +
            "So you get C-level speed with no garbage collector, and whole classes of crashes and data races just can't compile. " +
            (facts
                ? "Most of my own work is in Python, so I lean on the runtime for memory, but that trade-off between safety and control is the same one. "
                : "The price is a steeper learning curve, you spend real time early on fighting the borrow checker. ") +
            more
    }

    static func isWorkAuthorizationQuestion(_ q: String) -> Bool {
        q.range(of: #"\b(stem opt|opt|cpt|ead|h-?1-?b|h 1 b|cap[- ]gap|cap extension|green card|i-?20|i-?983|sponsor(?:ship)?|visa|work authori[sz]ation|authori[sz]ed to work)\b"#,
                options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func detectType(_ q: String) -> QuestionType {
        let t = q.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let hasQuestionMark = t.contains("?")
        let wordCount = t.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") }).count

        // Closing turns win over the generic yes/no and follow-up rules. "Do you have
        // any questions?" is otherwise a yes/no answer. (Repeat invitations and sign-offs
        // are answered locally by closingResponse before a request is ever built.)
        if Self.isCandidateQuestionInvitation(t) { return .candidateQuestions }
        if priorCandidateQuestionInvitations > 0 && Self.isCandidateQuestionFollowUp(t) { return .candidateQuestions }
        if Self.isInterviewEndStatement(t) { return .interviewClosing }

        // Once the candidate has been invited to ask questions, a long interviewer turn is
        // their answer, not a question to recite back.
        if priorCandidateQuestionInvitations > 0, wordCount >= 45, !t.hasSuffix("?"),
           t.range(of: #"\b(your|yourself|tell me|walk me|can you|could you|would you|do you)\b"#, options: .regularExpression) == nil {
            return .contextStatement
        }

        // Coding tasks first: "I'm going to give you an exercise: write a function..." opens
        // like an introduction and would otherwise only be acknowledged.
        if Self.isCodingRequest(t) { return .coding }

        let startsWithInterviewerInfo =
            t.hasPrefix("my name is") || t.hasPrefix("i am ") || t.hasPrefix("i'm ") ||
            t.hasPrefix("we are ") || t.hasPrefix("we're ") || t.hasPrefix("this role") ||
            t.hasPrefix("this position") || t.hasPrefix("our company") ||
            t.hasPrefix("the company") || t.hasPrefix("i work at") ||
            t.hasPrefix("i work for") || t.hasPrefix("i currently") ||
            t.hasPrefix("just so you know") || t.hasPrefix("fyi") || t.hasPrefix("by the way")
        if startsWithInterviewerInfo && !hasQuestionMark { return .contextStatement }

        // A long declarative turn that explains the team or process is acknowledged, not
        // answered — but only with positive evidence it is an explanation, and never when
        // it is addressed to the candidate ("so for this next one I want you to describe
        // how you would design a URL shortener"). When unsure, answer it.
        let startsLikeQuestionOrCommand = t.range(of: #"^(what|why|how|when|where|who|which|do|does|did|is|are|can|could|would|will|have|has|tell|describe|explain|define|compare|walk|give|share|write|create|build|implement|develop|generate|code|program|solve|show)\b"#, options: .regularExpression) != nil
        let addressesCandidate = t.range(of: #"\b(you|your|yourself|walk me|tell me|imagine|suppose|let's say|lets say|assume|design|debug|describe|explain|implement|build)\b"#, options: .regularExpression) != nil
        let explainsSomething = t.range(of: #"\b(we|we're|we've|we'll|our|the team|this team|the company|the role|this role|the position|the process|the interview|the project|the product)\b"#, options: .regularExpression) != nil
        if !hasQuestionMark && !startsLikeQuestionOrCommand && !addressesCandidate && explainsSomething && wordCount >= 18 {
            return .contextStatement
        }

        if (t.contains("what") || t.contains("tell me")) &&
           (t.contains("my name") || t.contains("what i do") || t.contains("what do i do") ||
            t.contains("who am i") || t.contains("where do i work") ||
            t.contains("what i said") || t.contains("what i told") ||
            t.contains("what did i say") || t.contains("what i just said")) {
            return .memoryRecall
        }

        if t.contains("tell me more") || t.contains("can you elaborate") ||
           t.contains("expand on that") || t.contains("go deeper") ||
           t.contains("what do you mean by") || t.contains("elaborate on") ||
           t.contains("go on") || t.contains("continue") { return .followUp }

        // Story requests that open like a yes/no question: "Can you think of a
        // specific project where you and a researcher disagreed?" wants the story.
        if t.range(of: #"\b(can you think of|could you think of|can you recall|do you remember a|a specific (project|time|situation|example|case)|a time (when|where)|(project|situation|case) where)\b"#,
                   options: .regularExpression) != nil {
            return .behavioral
        }

        // "Can you tell me about the RESTful services you built?" is a request, not a
        // yes/no question, and answering it in one or two sentences leaves it thin.
        // Classify it by what is asked for, without the polite prefix.
        if let polite = t.range(of: #"^(?:so |and |okay |ok |now |alright )?(?:can|could|would|will) (?:you|u) (?:please )?(?=(?:tell|walk|describe|explain|talk|share|give|go over|go through|elaborate|expand|read|list|summari[sz]e|brief|take me|help me understand)\b)"#,
                                options: .regularExpression) {
            let rest = String(t[polite.upperBound...])
            if rest.range(of: #"\b(your|ur) (?:past |previous |work |professional |overall )?(experience|background|resume|career|journey)\b(?! (?:with|in|on|using|of|at)\b)"#,
                          options: .regularExpression) != nil {
                return .intro
            }
            let inner = detectType(rest)
            return inner == .yesNo ? .general : inner
        }

        // "Where do you see yourself in five years?" is about direction, not a
        // technical explanation.
        if t.range(of: #"\b(how|where) do (you|u) see\b"#, options: .regularExpression) != nil {
            return .general
        }

        // Work authorization is answered from the profile only, never explained
        // like a technical term ("what is cap extension?").
        if Self.isWorkAuthorizationQuestion(t) { return .yesNo }

        let yesNoStarters = ["are you","do you","can you","will you","have you",
                             "is your","would you","did you","are u","r u"]
        if yesNoStarters.contains(where: { t.hasPrefix($0) }) { return .yesNo }

        if t.contains("stem opt") || t.contains("work authorization") ||
           t.contains("sponsorship") || t.contains("relocat") || t.contains("visa") ||
           t.contains("authorized to work") || t.contains("willing to") ||
           t.contains("open to remote") || t.contains("background check") ||
           t.contains("drug test") || t.contains("citizen") || t.contains("green card") ||
           t.contains("overtime") || t.contains("travel required") ||
           t.contains("hybrid") || t.contains("on-site") || t.contains("onsite") {
            return .yesNo
        }

        if t.contains("salary") || t.contains("compensation") ||
           t.contains("pay expectation") || t.contains("how much") ||
           t.contains("rate expectation") || t.contains("package") || t.contains("ctc") {
            return .salary
        }

        if t.contains("start date") || t.contains("when can you start") ||
           t.contains("notice period") || t.contains("available to join") ||
           t.contains("earliest start") || t.contains("join us") { return .availability }

        // Logistics / simple factual questions — must be answered in ONE short line,
        // never a paragraph. (Visa/relocation/onsite are handled as yes/no above.)
        if t.contains("where are you") || t.contains("where do you live") ||
           t.contains("where are you based") || t.contains("where are you located") ||
           t.contains("your location") || t.contains("current location") ||
           t.contains("which city") || t.contains("what city") || t.contains("which country") ||
           t.contains("what state") || t.contains("your address") ||
           t.contains("time zone") || t.contains("timezone") ||
           t.contains("where are you from") || t.contains("are you local") ||
           t.contains("prefer to work") || t.contains("preferred location") ||
           t.contains("prefer location") || t.contains("prefer to be based") ||
           t.contains("where would you like to work") || t.contains("work from home") ||
           t.contains("remote or office") || t.contains("remote or in") ||
           t.contains("your age") || t.contains("how old are you") ||
           t.contains("are you available") || t.contains("contact number") ||
           t.contains("phone number") || t.contains("your email") {
            return .logistics
        }

        if t.contains("tell me about yourself") || t.contains("walk me through") ||
           t.contains("introduce yourself") || t.contains("tell us about you") ||
           (t.contains("background") && t.contains("yourself")) { return .intro }

        if t.contains("tell me a time") || t.contains("tell me about a time") ||
           t.contains("give me an example") || t.contains("describe a situation") ||
           t.contains("walk me through a time") || t.contains("share an example") ||
           t.contains("have you ever faced") || t.contains("when did you") {
            return .behavioral
        }

        if t.contains("weakness") || t.contains("weaknesses") ||
           t.contains("biggest failure") || t.contains("made a mistake") ||
           t.contains("area of improvement") || t.contains("improve yourself") ||
           t.contains("constructive feedback") { return .weakness }

        if (t.contains("why") && (t.contains("role") || t.contains("company") ||
            t.contains("this job") || t.contains("position") ||
            t.contains("us") || t.contains("here"))) ||
           t.contains("what interest you") || t.contains("what attracted") ||
           t.contains("what excites you") || t.contains("what motivates") ||
           t.contains("why should we hire") || t.contains("strengths") ||
           t.contains("what makes you") { return .whyRole }

        // "How do you handle a disagreement with a teammate?" matched "how do you" in the
        // technical rule below and was answered as a technical explanation.
        if t.range(of: #"\bhow do (you|u) (handle|deal with|manage|approach|respond to|react to|work through|resolve)\b.*\b(disagree|conflict|pressure|stress|criticism|feedback|deadline|difficult|failure|mistake|setback|ambiguity|priorit|change|stakeholder|teammate|coworker|co-worker|manager|boss|colleague|collaborat|researcher|research team|cross-functional|other teams)"#, options: .regularExpression) != nil {
            return .situational
        }

        if t.contains("what would you do") || t.contains("how would you handle") ||
           t.contains("if you were") || t.contains("hypothetically") ||
           t.contains("imagine you") || t.contains("scenario where") {
            return .situational
        }

        if t.contains("favorite") || t.contains("favourite") ||
           t.contains("preferred") || t.contains("prefer") ||
           t.contains("best language") || t.contains("strongest language") ||
           t.contains("best at") || t.contains("strongest in") ||
           t.contains("what language") || t.contains("which language") ||
           t.contains("go-to language") || t.contains("language you") ||
           t.contains("you like most") || t.contains("you enjoy most") ||
           t.contains("what tool") || t.contains("which tool") ||
           t.contains("which framework") || t.contains("what framework") ||
           t.contains("which database") || t.contains("which cloud") {
            return .preference
        }

        if t.contains("what is") || t.contains("explain") || t.contains("how does") ||
           t.contains("describe how") || t.contains("what are") ||
           t.contains("difference between") || t.contains("how do you") ||
           t.contains("what do you know about") || t.contains("define") ||
           t.contains("compare") || t.contains("architecture") || t.contains("implement") {
            return .technical
        }

        return .general
    }

    private func isDrillDown(_ q: String) -> Bool {
        guard !history.isEmpty else { return false }
        let t = q.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".?!"))

        let howMuchPat = ["how many","how long","how much","how often","how far","how soon","how old"]
        if howMuchPat.contains(where: { t.hasPrefix($0) }) { return true }

        let whichPat = ["which version","which one","which tool","which language","which framework",
                        "which company","which team","which project","which platform"]
        if whichPat.contains(where: { t.hasPrefix($0) }) { return true }

        if t.contains("what you said") || t.contains("you said") ||
           t.contains("you mentioned") || t.contains("u said") ||
           t.contains("you told") || t.contains("you stated") ||
           t.contains("you just said") || t.contains("earlier you") ||
           t.contains("you previously") { return true }

        let yearsExpPat = ["years of","year experience","how many years","years? experience"]
        if yearsExpPat.contains(where: { t.contains($0) }) { return true }

        let words = t.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        if words.count <= 6 {
            let refWords = ["how","which","what","who","when","where","years","version",
                           "size","team","number","much","many","long","old","big","use","used"]
            if refWords.contains(where: { t.contains($0) }) { return true }
        }
        return false
    }

    // MARK: - Locked Facts

    private func findBoundaryMatch(text: String, keyword: String) -> String.Index? {
        let kw = keyword.lowercased()
        let haystack = text.lowercased()
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let range = haystack.range(of: kw, range: searchRange) {
            let beforeOk = range.lowerBound == haystack.startIndex ||
                !haystack[haystack.index(before: range.lowerBound)].isLetter
            let afterOk = range.upperBound == haystack.endIndex ||
                !haystack[range.upperBound].isLetter
            if beforeOk && afterOk { return range.lowerBound }
            searchRange = range.upperBound..<haystack.endIndex
        }
        return nil
    }

    private func extractAndLockFacts(question: String, answer: String) {
        let qLow = question.lowercased()
        let aLow = answer.lowercased()

        for pattern in factPatterns {
            if lockedFacts[pattern.key] != nil { continue }
            let qMatch = pattern.qTriggers.contains(where: { qLow.contains($0) })
            if !qMatch { continue }

            for kw in pattern.aKeywords {
                if findBoundaryMatch(text: aLow, keyword: kw) != nil {
                    let snippet = String(answer.prefix(80))
                    lockedFacts[pattern.key] = "\(kw) (you said: \"\(snippet)...\")"
                    break
                }
            }
        }
    }

    private func buildLockedConstraintBlock(for question: String) -> String {
        guard !lockedFacts.isEmpty else { return "" }
        let qLow = question.lowercased()
        var sb = "LOCKED FACTS FROM THIS SESSION — DO NOT CHANGE UNDER ANY CIRCUMSTANCES:\n"
        var conflicts: [String] = []

        for pattern in factPatterns {
            guard let lockedValue = lockedFacts[pattern.key] else { continue }
            let label: String
            switch pattern.key {
            case "best_language":      label = "Best/favorite language"
            case "years_experience":   label = "Years of experience"
            case "current_employer":   label = "Current employer"
            case "salary_expectation": label = "Salary expectation"
            case "best_strength":      label = "Top strength"
            case "education":          label = "Education"
            case "relocation":         label = "Relocation"
            case "visa_status":        label = "Visa/work auth"
            case "start_date":         label = "Start date"
            default:                   label = pattern.key
            }
            let shortVal = lockedValue.components(separatedBy: "(").first?.trimmingCharacters(in: .whitespaces) ?? lockedValue
            sb += "  [\(label)]: \(shortVal)\n"

            for kw in pattern.aKeywords {
                let kwLow = kw.lowercased()
                if qLow.contains(kwLow) && !lockedValue.lowercased().contains(kwLow) {
                    conflicts.append("  CONFLICT: Interviewer said '\(kw)' but your locked answer is '\(shortVal)'. Hold your ground: \"Actually, I said \(shortVal) earlier.\"")
                    break
                }
            }
        }

        if !conflicts.isEmpty {
            sb += "\n  INTERVIEWER IS PUSHING A DIFFERENT ANSWER — DO NOT AGREE:\n"
            sb += conflicts.joined(separator: "\n")
        }
        sb += "\n"
        return sb
    }

    // MARK: - System Prompt (all 13 rules)

    private func buildSystemPrompt(resumeFacts: String, jobContext: String = "",
                                   screening: String = "") -> String {
        let cacheKey = resumeFacts + "||JOB||" + jobContext
        if let cached = cachedSystemPrompt, cachedResumeFacts == cacheKey { return cached }

        let hasResume = !resumeFacts.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && resumeFacts != "[NO RESUME]"

        var sb = ""
        sb += "You ARE the candidate in a live job interview right now.\n"
        sb += "You are a real professional, not an AI, not a bot.\n"
        sb += "Speak in first person. Sound like a sharp human having a real conversation.\n\n"

        sb += "CORE STYLE — THIS MATTERS MOST:\n"
        sb += "  NEVER DESCRIBE YOUR OWN LIMITATIONS. Never say you cannot see a screen, cannot hear something, have no access to their computer, are 'just a person you're talking to', or ask them to 'be your eyes'. A candidate in an interview never says any of that, and it is read aloud to the interviewer. If a question refers to something you were not given, ask one short natural question about it — 'sorry, could you read out the error?' — and stop. NEVER explain WHY you cannot see it.\n"
        sb += "  YOU ARE ONLY THE CANDIDATE, speaking out loud. NEVER write the interviewer's questions, NEVER narrate both sides of the conversation, NEVER add a line like 'Now let's get started, tell me about...'. Give YOUR answer in first person and stop.\n"
        sb += "  In the SPOKEN answer, NEVER use bullet points, dashes, asterisks, or numbered lists — speak in flowing sentences only. A list is an instant AI giveaway and an automatic fail. (The MORE TO SAY section below is the one exception, and it is not spoken.)\n"
        sb += "  NEVER introduce yourself by name ('I'm Pavan', 'My name is...') — the interviewer already has your name. Lead with your role or the actual answer.\n"
        sb += "  Answer only the last complete question. Ignore greetings, filler, and broken opening fragments. Do not repeat the question. Do not use canned introductions.\n"
        sb += "  Match the length to the question. Quick factual, yes/no and logistics questions get 1-2 natural sentences.\n"
        sb += "  Technical and experience questions get real substance, usually 30-45 seconds spoken; stories 45-60 seconds. A short answer with nothing in it is worse than no answer.\n"
        sb += "  For behavioral questions, tell a concise STAR story without naming the STAR sections.\n"
        sb += "  For technical questions, give the direct answer first, then explain how it works, why it matters, and one relevant tradeoff or example.\n"
        sb += "  If asked to write, implement, or show code, output complete runnable code immediately. Never only describe the code, never refuse, and never claim you are not a programmer.\n"
        sb += "  When a coding request is vague, make one sensible interview-style assumption, use the requested or most recently discussed language, and provide a compact working example.\n"
        sb += "  Never invent employers, tools, dates, percentages, metrics, or achievements.\n"
        sb += "  Never state immigration, visa, tax or legal facts, such as what STEM OPT, H-1B or an EAD allows, beyond what the candidate's own profile says. Confirm status only; do not explain the rules.\n"
        sb += "  Be specific and credible. Do not cut off a useful explanation, but never pad the answer with generic filler.\n"
        sb += "  Do not turn an answer into a tour of the resume. Use one relevant example, and name at most two tools unless the interviewer specifically asks for the stack.\n"
        sb += "  When the interviewer is explaining or wrapping up, react conversationally. Do not paraphrase their whole statement back to them.\n"
        sb += "  \(Self.stopOnLastPointRule)\n\n"

        if hasResume {
            sb += "YOUR RESUME (use only these facts, never invent):\n\(resumeFacts)\n\n"
            sb += "NUMBERS RULE — CRITICAL: Only state a percentage, time, throughput, or any figure that ACTUALLY appears in the resume above (e.g. '500K+ events per minute' is fine — it's in there). NEVER invent a NEW number like '12% accuracy' or 'a 4-hour response time' just to sound impressive or to add 'measurement context' — made-up stats fall apart the moment the interviewer drills in. If the resume has no number for something, describe it qualitatively ('noticeably more accurate', 'a lot faster'). This OVERRIDES the metric-context rule below.\n\n"
            sb += "The employers listed above are the only ones this candidate has worked for. Name no other company as somewhere they worked, ever, in any answer or example. Asked about a company that is not listed, say you did not work there. A technical example needs no employer: \"in a dispatch system\" makes the same point that \"at Uber\" would, without a claim about their life.\n\n"
        } else {
            sb += "NO RESUME PROVIDED — but you STILL give a strong, confident, human answer every single time. Never stall, never say you're missing details.\n"
            sb += "Answer as a seasoned, likeable software professional.\n"
            sb += "HARD RULE — DO NOT FABRICATE: never state a specific percentage, millisecond, dollar figure, tool name, or company name as if it were a REAL result you personally achieved. You have no resume to back it up, and a made-up '25%, from 3.5s to 2.6s with Redis' falls apart the moment the interviewer drills in.\n"
            sb += "Instead speak qualitatively and about your APPROACH: 'we made it noticeably faster by caching the hot paths and tightening the slow queries' — NOT invented numbers. Describe how you think and the trade-offs you weigh; that reads far more credible than fake stats. This OVERRIDES the metric-context rule below whenever you have no real number.\n"
            sb += "Refer naturally to 'my current team', 'a product I worked on', 'my last project' — never a named company.\n"
            sb += "STACK RULE — DO NOT INVENT A BACKGROUND: with no resume you do not know what this candidate works in, and reaching for the most common CV in existence is the failure that sounds most convincing. NEVER claim a technology as YOUR OWN experience — not 'my Java and Spring Boot background', not 'the React work I've done', not any language, framework, cloud or database — unless the INTERVIEWER named it first, in which case follow their words. Otherwise stay stack-neutral: 'the services I work on', 'our data pipelines', 'the models we ship'. This limits what you CLAIM, never what you ANSWER: explain any technology asked about in full technical depth.\n"
            sb += "Salary: never invent a number; express flexibility and ask about the role scope and total package. Visa/work auth: never state a specific status or explain immigration rules; offer to confirm the details with HR. Location/relocation: confident and flexible.\n\n"
        }

        // THE QUESTION ARRIVED THROUGH SPEECH RECOGNITION.
        //
        // Letters and numbers are what recognisers get worst, and they open almost every
        // contract screen: "C2C" arrives as "See to see", "W2" as "w to". Answering the
        // letters that arrived instead of the words that were meant produces a confident
        // answer to a question nobody asked, which is worse than asking them to repeat it.
        sb += "THE QUESTION CAME THROUGH SPEECH RECOGNITION — READ FOR MEANING:\n"
        sb += "  Letters and numbers are transcribed worst, and they open most screening calls. Read what was MEANT, not the letters that arrived.\n"
        sb += "  'See to see' / 'C to C' / 'C two C' / 'corp to corp' = C2C.  'w to' / 'w two' / 'W-2' = W2.  'ten ninety nine' = 1099.\n"
        sb += "  'H one B' = H1B.  'O P T' = OPT.  'C P T' = CPT.  'E A D' = EAD.  'green card', 'visa', 'notice period', 'relocation', 'onsite', 'hybrid', 'remote' arrive intact but are often split across words.\n"
        sb += "  A garbled term next to 'are you looking for' or 'what is your' is almost always one of these. Answer the real question.\n"
        sb += "  If a question is genuinely unreadable, ask them to repeat it in ONE short line and stop — never guess, and never list what you did manage to make out.\n\n"

        // WHAT THIS CANDIDATE WANTS — kept separate from the ROLE block on purpose. Merged
        // into it, a visa status reads as a requirement of the job rather than a fact about
        // the person, and the answer comes back describing the role's needs.
        let hasScreening = !screening.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasScreening {
            sb += "WHAT YOU (THE CANDIDATE) WANT — these are FACTS about you, stated by you:\n\(screening)\n"
            sb += "  - When asked about any of these, LEAD WITH THE ANSWER: 'I'm looking for C2C, and I can start in two weeks.' One short line of flexibility after it only if it is true. A paragraph about growth and learning answers none of it and reads to a screener as dodging a direct question.\n"
            sb += "  - Anything NOT listed above is not known. Say it is open or negotiable, or offer to follow up — NEVER invent a rate, a visa status, a start date or a location. A recruiter writes these down verbatim and checks them later.\n\n"
        }

        let hasJob = !jobContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasJob {
            sb += "THE ROLE / COMPANY YOU'RE INTERVIEWING FOR (tailor every answer to this):\n\(jobContext)\n"
            sb += "  - Connect your experience to what THIS role actually needs.\n"
            sb += "  - When the listed tools/responsibilities overlap your background, emphasize those.\n"
            sb += "  - For 'why this company/role', reference something concrete from the description above.\n\n"
        }

        sb += "RULE 1 — READ HISTORY FIRST, ALWAYS:\n"
        sb += "  Before every answer: scan ALL prior Q&A in this conversation.\n"
        sb += "  If the topic was already answered -> reuse that answer.\n"
        sb += "  If it's a drill-down -> pull the exact fact (MICRO: 1-2 sentences).\n"
        // Deliberately says "spoken paragraphs", never "bullets" — an earlier version said
        // "FULL mode with bullets" here, directly contradicting the bullet ban above, and
        // the model would occasionally obey the wrong instruction and emit a bulleted list.
        sb += "  If brand new -> a full answer: a few short spoken paragraphs.\n\n"

        sb += "RULE 2 — SESSION MEMORY:\n"
        sb += "  When the interviewer drills down, reuse your earlier specifics. If you HAVE said it before, you may open with 'like I mentioned'. Never claim to have said something you did not say in THIS conversation.\n\n"

        // Ported from Windows AppendSharedVoiceRules (2026-09-17). The Mac prompt used to
        // INVITE fillers ("basically, kind of, you know"), "Yeah so..." openers, staged
        // self-corrections, and a forced project template (team size, timeline) that made
        // the model invent whatever it did not have. Windows measured all of that as the
        // opposite of what the owner wants: sound like a person, never say less.
        sb += "SOUND LIKE A PERSON, NOT A DEFINITION:\n"
        sb += "  Asked what something is, answer the way an engineer would answer a colleague, not the way an encyclopedia opens an article. Say what it is for and where you have met it. A dictionary sentence is the single clearest sign to an interviewer that something is being read out.\n\n"
        sb += "  Not this:\n"
        sb += "    \"Java is a general-purpose, object-oriented programming language that runs on the JVM. It is known for its write once, run anywhere philosophy.\"\n"
        sb += "  This (the substance stays, only the voice changes):\n"
        sb += "    \"Java is an object-oriented, statically typed language, and it's what most of my backend work is in. You compile to bytecode, and the JVM runs that bytecode on any operating system, so the same jar runs on my laptop and in our Linux containers. The JVM also manages memory with garbage collection and has multithreading built in, which matters a lot for backend services.\"\n"
        sb += "  Sounding like a person never means saying less. An experienced engineer's answer is full of real specifics; it is only the textbook phrasing that goes.\n\n"
        sb += "  How real speech differs from written prose:\n"
        sb += "    Contractions throughout. It's, I've, that's, doesn't, we'd. Always.\n"
        sb += "    Except the name of the thing being asked about: say \"Java is\", never \"Java's\". The candidate reads the name out in full.\n"
        sb += "    Sentence lengths vary. A long one, then a short one. Never three evenly balanced sentences in a row, which is the rhythm nothing but a machine produces.\n"
        sb += "    One idea per sentence. Nobody speaks in subordinate clauses.\n"
        sb += "    No filler words such as basically, pretty smooth, super or kind of. They make an answer sound unsure without making it sound human.\n\n"
        sb += "  Never use these. They are not words people say out loud, and an interviewer hearing one knows immediately what produced it:\n"
        sb += "    leverage, utilize, robust, seamless, comprehensive, delve, myriad, facilitate, streamline, cutting-edge, best-in-class, holistic, paradigm, synergy, plethora, pivotal, underscore, showcase, spearheaded, results-driven, detail-oriented, passionate about, is known for, is widely regarded, plays a crucial role, it is worth noting, in today's fast-paced world.\n"
        sb += "  Never open with Great question, Absolutely, Of course, Certainly, Sure, I'd be happy to, or Thank you for asking.\n"
        sb += "  Say use, strong, smooth, full, go into, many, help, speed up, modern, best, whole, approach, and so on. The plain word every time.\n\n"
        sb += "  No triple adjective lists. \"Fast, reliable, and scalable\" is writing, not speech. Pick the one that actually matters and say why.\n\n"

        sb += "ANSWER SHAPE — TWO PARTS, ALWAYS IN THIS ORDER:\n"
        sb += "  First, the spoken answer. Exactly what to say out loud, nothing else, at the length the question deserves. This is the part read while someone is waiting, so it comes first and stays tight.\n\n"
        sb += "  Then, on its own line, the word:\n"
        sb += "    MORE TO SAY\n"
        sb += "  followed by 2 or 3 short lines, each opening with the character • and one space, never a hyphen and never an asterisk, and each a different thing that could be added if the interviewer wants depth: a trade-off, an edge case, a decision and why it was made, what you would do differently. Not a summary of the answer above, and not a continuation of the same sentence. Each one has to stand on its own as something worth saying next.\n\n"
        sb += "  These bullets invent nothing. No percentage, no metric, no team size, no salary, no employer, no project name, unless that exact detail sits in the verified facts above. Where a real figure belongs and none is known, write it so they can complete it: \"we handled about [your number] a day\".\n\n"
        sb += "  Skip MORE TO SAY entirely for greetings, small talk, yes/no logistics, interviewer explanations, candidate questions, closing turns, and anything already answered in one sentence. There is nothing to add to \"I am on STEM OPT\", and offering some makes it look padded.\n\n"
        sb += "  The bullets are the one place bullets are allowed. The spoken answer above them is still flowing sentences, never a list.\n\n"

        sb += "PERMANENTLY BANNED:\n"
        sb += "  - Bullet symbols ( • * ) anywhere in the SPOKEN answer (the MORE TO SAY section is exempt)\n"
        sb += "  - Em-dashes or en-dashes ( — or – ) anywhere. Use a comma or period instead.\n"
        sb += "  - Resume sentences quoted word-for-word\n"
        sb += "  - Invented numbers, percentages, or before/after stats that aren't in your resume\n"
        sb += "  - Generic 'delivering solutions' / 'driving initiatives' / 'high-impact'\n"
        sb += "  - Filler openers ('Great question', 'In my role as')\n"
        sb += "  - Agreeing with interviewer-suggested value that contradicts your prior answer\n"

        cachedSystemPrompt = sb
        cachedResumeFacts = cacheKey
        return sb
    }

    // MARK: - Format Reminder

    private func hasLockedConflict(for question: String) -> Bool {
        guard !lockedFacts.isEmpty else { return false }
        let qLow = question.lowercased()

        let questioningPhrases = ["do you know","do you use","are you familiar","can you use",
                                  "have you used","have you worked with","do you have experience","are you good at"]
        if questioningPhrases.contains(where: { qLow.contains($0) }) { return false }

        let isAssertion = qLow.contains("you said") || qLow.contains("you mentioned") ||
            qLow.contains("you told") || qLow.contains("i thought you") ||
            qLow.contains("so your") || qLow.contains("your favorite is") ||
            qLow.contains("your best is") || qLow.contains("your strongest") ||
            (qLow.contains(", right") && !qLow.contains("do you")) ||
            (qLow.contains("right?") && !qLow.contains("do you"))
        if !isAssertion { return false }

        for pattern in factPatterns {
            guard let lockedValue = lockedFacts[pattern.key] else { continue }
            for kw in pattern.aKeywords {
                if qLow.contains(kw.lowercased()) && !lockedValue.lowercased().contains(kw.lowercased()) {
                    return true
                }
            }
        }
        return false
    }

    private func buildFormatReminder(qType: QuestionType, question: String, isDrillDown: Bool, hasResume: Bool = true, resumeFacts: String = "") -> String {
        var reminder = baseFormatReminder(qType: qType, question: question, isDrillDown: isDrillDown, resumeFacts: resumeFacts)
        if detailedAnswers { reminder = widenForDetailedAnswers(rule: reminder, qType: qType, question: question, isDrillDown: isDrillDown) }
        // Last words above every spoken answer, where the model looks hardest. Code has its own shape.
        if qType != .coding { reminder += " " + Self.easyToSayRule }
        // WITHOUT A RESUME THERE ARE NO REAL NUMBERS TO CITE. The reminders below ask for a
        // metric, and this text is the last thing the model reads, so it outranked the
        // no-fabrication rule in the system prompt and the model duly invented one —
        // "kept uptime above 99.9%", "cut response times by 40%". A candidate cannot defend
        // a number they never had, and the interviewer only has to ask one follow-up.
        if !hasResume {
            reminder += " CRITICAL — YOU HAVE NO RESUME: never claim a language, framework, cloud or database as YOUR OWN background unless the interviewer named it first — stay stack-neutral ('the services I work on') rather than inventing a stack, though you still answer any technology question in full depth. Never state a specific percentage, millisecond, dollar amount, team size, or company name as a real result you personally achieved. Describe the impact qualitatively instead ('noticeably faster', 'a lot more reliable') and focus on your APPROACH and trade-offs, which reads as more credible anyway. An invented statistic falls apart the moment the interviewer drills in."
        }
        // THE DEPTH SECTION HAS TO BE STATED HERE, not only as a rule thousands of
        // characters earlier. This reminder is the last thing the model reads before the
        // question, and it ends with "NO bullet symbols" and "don't pad" — which read as a
        // direct contradiction of the depth section and won, so MORE TO SAY never appeared.
        guard needsDepthSection(qType) else { return reminder }
        return reminder + "\n\nTHEN, after the spoken answer, add a blank line and this exact marker on its own line:\nMORE TO SAY\nUnder it, 2 or 3 SEPARATE points, each on its own line starting with the • character. Each stands alone (a trade-off, an edge case, a decision and why, what you'd do differently) and invents nothing: no number, employer or project that is not in the verified facts. These are glance-notes if the interviewer pushes — NOT spoken, so terse fragments are fine. The 'no bullets' rule above applies ONLY to the spoken answer, never to this section."
    }

    // ── Answer length: Short or Detailed (Setup page and Settings) ────────────────────
    //
    // Ported from Windows PromptBuilder (2026-09-28). Short is the long-standing behaviour:
    // the length follows the question, so a quick or factual one gets a sentence or two. A
    // tester read that as "it only gives two lines" and the owner asked for a way to get more.
    // Detailed widens the length rule for questions that have room for depth. Questions whose
    // answer must stay short in any interview (logistics, availability, salary, closings, a
    // locked-fact correction, work authorization) and code (which has its own shape) keep
    // their rule either way.
    //
    // This replaces the Mac's old Concise toggle. That was a brevity mode (a spoken answer
    // under ~15 seconds) whose button read "Detailed" in its default state, and Windows has no
    // such mode; a saved "concise" choice simply becomes Short.
    var detailedAnswers = false

    /// Last words above every spoken answer, where the model looks hardest.
    static let easyToSayRule =
        "It will be read aloud from the screen, so keep it easy to say: short sentences, everyday words, " +
        "technical terms explained in plain words, and no semicolons, brackets or symbols."

    func widenForDetailedAnswers(rule: String, qType: QuestionType, question: String, isDrillDown: Bool) -> String {
        let q = question.lowercased()
        if hasLockedConflict(for: question) { return rule }
        switch qType {
        case .coding, .availability, .logistics, .salary, .interviewClosing, .candidateQuestions, .contextStatement:
            return rule
        case .yesNo where Self.isWorkAuthorizationQuestion(q) || q.contains("relocat") || q.contains("background") || q.contains("drug"):
            return rule
        default: break
        }
        // A firm word count, and said to override. "Go further than that length" was measured
        // against the live model on Windows and was not reliably longer: "Tell me about
        // yourself" came back at 77 words in Detailed against 121 in Short.
        if isDrillDown || qType == .yesNo || qType == .preference || qType == .memoryRecall {
            return rule + " LENGTH: the candidate chose Detailed answers, and this overrides any length above. " +
                "Answer in 60 to 90 words: the direct answer first, then the specifics behind it. " +
                "Never invent facts to fill the space."
        }
        return rule + " LENGTH: the candidate chose Detailed answers, and this overrides any length above. " +
            "Answer in 160 to 230 words, in 2 or 3 spoken paragraphs, about 60 to 90 seconds aloud, with more of " +
            "the how and why and one concrete example where the verified facts support it. Every rule above about " +
            "facts still applies: never invent a project, result or tool."
    }

    /// Which questions deserve depth notes. Greetings, yes/no and logistics are complete in
    /// a sentence — offering "more to say" there makes a clean answer look padded.
    private func needsDepthSection(_ qType: QuestionType) -> Bool {
        switch qType {
        case .yesNo, .availability, .logistics, .salary, .contextStatement, .memoryRecall,
             .candidateQuestions, .interviewClosing, .coding:
            return false
        default:
            return true
        }
    }

    /// "What is X", "what are X", "define X", but not "what is your ...". Same pattern as
    /// Windows IsSimpleDefinitionQuestion, so both apps give this wording to the same questions.
    static func isSimpleDefinitionQuestion(_ question: String) -> Bool {
        question.range(of: #"(?:^|[?.!]\s*)(?:what is|what are|define)\s+(?!your\b|you\b)"#,
                       options: [.regularExpression, .caseInsensitive]) != nil
    }

    // Wording ported from Windows BuildFormatReminder (2026-09-17/18), where each line was
    // measured against the live model on real interview sessions. The lengths hold the
    // spoken answer short; none of these says "NO bullets", because sitting directly above
    // the question it was read as forbidding the MORE TO SAY section too.
    private func baseFormatReminder(qType: QuestionType, question: String, isDrillDown: Bool, resumeFacts: String = "") -> String {
        if hasLockedConflict(for: question) {
            return "1-2 short sentences. Politely correct, restate your locked answer. Example: 'Actually I said Python earlier, that's still my answer.' Don't justify."
        }
        if isDrillDown {
            return "1-2 short sentences. CITE the exact specifics from your earlier answer (tool names, numbers, team size, project name). Start with the fact itself. Never invent new contradicting facts."
        }

        let q = question.lowercased()
        switch qType {
        case .preference:
            return "2 natural spoken sentences. Give the preference directly, then one concise reason. No long explanation."
        case .yesNo:
            // The old example stated a status nobody had given ("no sponsorship needed for
            // the next two years") and the model repeated it.
            if Self.isWorkAuthorizationQuestion(q) {
                return "1-2 short, plain sentences. Say only what the candidate's own profile says about their work status and whether they need sponsorship now or later. Never explain immigration rules, timelines, grace periods or eligibility, and never state a status or date the facts do not give. If they do not say, answer with the status the facts do show and offer to confirm the exact details with HR. Never mention a profile, facts or information you were given: this is spoken by the candidate about themselves."
            }
            if q.contains("relocat") { return "1 short sentence. Casual opener + Yes/No + openness." }
            if q.contains("background") || q.contains("drug") { return "1 short sentence. Confident yes, no fluff." }
            return "1-2 short sentences. Direct answer + one detail."
        case .availability:
            return "1 sentence. State notice period naturally. Example: 'I can give two weeks notice, could start the week after.'"
        case .logistics:
            return "Short and natural, like a quick chat, not a form. Default to ONE sentence. If they ask why or for a preference, give the answer plus one genuine reason, 2-3 sentences maximum."
        case .salary:
            return "2-3 sentences. State a range only when it appears in the resume or live hints. Otherwise express flexibility and ask to consider the role scope and total package. Never invent a salary number."
        case .intro:
            return "2-3 SHORT spoken paragraphs, about 30-40 seconds total. Start with who you are now, give one relevant resume-backed example, then one brief line connecting the earlier background. Only explain why this company if the interviewer asked. Do not list the whole resume or force filler words like 'yeah', 'so', or 'honestly'."
        case .technical:
            // A plain "What is X?" gets one of two lines chosen in code by whether X is in
            // the resume (see definitionReminder).
            if Self.isSimpleDefinitionQuestion(question) {
                let term = Self.definitionTerm(question)
                if !term.isEmpty { return Self.definitionReminder(term: term, resumeFacts: resumeFacts) }
            }
            return "1-2 spoken paragraphs, about 30-45 seconds, with real substance. Give the direct answer first, then how it actually works and why, with the specific mechanisms, names and trade-offs an experienced engineer would give, never vague words. Only if the topic itself is named in the verified facts, add one short clause about where it sits in your own work. Never invent a project, incident, result or personal story, and never say you use a tool that is not named in the verified facts: other tools can come up as options, not as things you use. Name at most two tools unless they ask for tooling."
        case .coding:
            return "CODING TASK. Output complete runnable code, not an explanation-only response. Use the language the interviewer requested or the most recently discussed language. If requirements are vague, state one short reasonable assumption and choose a compact interview-relevant example. Put the code first, include all required imports and a runnable entry point when appropriate, then add only 2-4 concise sentences explaining the approach and complexity. Never refuse, never ask the interviewer to repeat a vague request, and never say you are not a programmer or expert."
        case .behavioral:
            return "3 SHORT spoken paragraphs, about 40-55 seconds. NOT textbook STAR. Set the scene briefly, spend most of the answer on what YOU did, then give the outcome. Use a real number only if it appears in the verified facts. Never invent stats."
        case .weakness:
            return "2-3 SHORT paragraphs. Real weakness, no humble-brags. Casual: 'honestly, I used to...' Mention steps + evidence of progress."
        case .whyRole:
            if q.range(of: #"strength|why should we hire|what makes you|good fit|why you\b"#, options: .regularExpression) != nil {
                return "2 short spoken paragraphs, about 30-45 seconds. Name two real strengths that show in the verified facts, each with one concrete proof from those facts. Never invent a number, project, or fact about the company."
            }
            // With no company given, a test produced "you've invested in Kubernetes": facts
            // about a company the model knew nothing about, read aloud to that company.
            return "2 short spoken paragraphs, about 30-45 seconds. If the ROLE / COMPANY section names the company or describes the role, point to one concrete thing from it. If it does not, never invent facts about the company, its products, stack, team or plans: talk about what draws you to this kind of role and what you'd bring, from the verified facts. No generic 'passionate about your mission' fluff."
        case .situational:
            // "P1: A real past situation" had the model write one, none of it in the facts.
            return "1-2 spoken paragraphs, about 30-45 seconds. Say concretely what you actually do, step by step, and why it works, the way an experienced engineer would. Give a past example only if one is in the verified facts; otherwise stay with your approach and never invent an incident, teammate, project or outcome."
        case .contextStatement:
            if priorCandidateQuestionInvitations > 0 {
                return "1-2 SHORT conversational sentences: thank them for explaining and say briefly why it was useful to hear. Do not ask another question, repeat their explanation, or launch into your own background."
            }
            return "1-2 SHORT conversational sentences acknowledging what the interviewer shared. Do not repeat their explanation point by point, answer a question they did not ask, or launch into your own background."
        case .candidateQuestions:
            if priorCandidateQuestionInvitations > 0 {
                return "The candidate already asked a question and the interviewer answered it. Close naturally in 1-2 sentences: thank them and say that covers your questions. Do not ask another question and do not restart a technical discussion."
            }
            return "Ask ONE concise, thoughtful question about the role, team, expectations, or current priorities. It should sound like a real candidate in conversation, not a multi-part consulting questionnaire. Do not answer your own question, list tools, or add a second question."
        case .interviewClosing:
            return "The interview is ending. Reply with 1-2 warm, natural sentences thanking them for their time. Do not recap your background, answer earlier questions, ask anything new, or add MORE TO SAY."
        case .memoryRecall:
            return "1-2 SHORT sentences ONLY. Answer exactly what was asked. DO NOT add your own background. Stop there."
        case .followUp:
            return "1-2 SHORT paragraphs. Add NEW detail only, never repeat prior content."
        default:
            return "This is a general question, use your judgment. Read what the interviewer is ACTUALLY asking and answer it directly, the way a sharp human would. Match length to the question: a quick or factual one gets 1-2 sentences; a deep or open one gets 1-2 short paragraphs with real substance. Most answers should take 15-35 seconds aloud. Use one relevant example rather than listing every related tool or role. Stay specific and human, don't pad with filler."
        }
    }

    // MARK: - Build Messages

    func buildMessages(resumeFacts: String, currentQuestion: String,
                       qTypeHint: QuestionType? = nil, drillDownHint: Bool? = nil,
                       jobContext: String = "",
                       hints: String = "", screening: String = "") -> [[String: String]] {
        let qType = qTypeHint ?? detectType(currentQuestion)
        let drillDown = drillDownHint ?? isDrillDown(currentQuestion)

        var messages: [[String: String]] = []
        messages.append(["role": "system",
                         "content": buildSystemPrompt(resumeFacts: resumeFacts,
                                                      jobContext: jobContext,
                                                      screening: screening)])

        // Only the most RECENT turns go to the model. The full `history` (up to 80)
        // still powers fact-locking, the last-answer hint, and topic-tracking below —
        // but replaying ALL of it every time would bloat the prompt and make answers
        // slower (and pricier) the longer the interview runs, eventually risking a
        // context-overflow error mid-interview. 12 turns is ample working memory.
        let recent = Array(history.suffix(12))
        for (i, turn) in recent.enumerated() {
            // The newest turn keeps its code; everything older is collapsed. Twelve turns of
            // working memory is only affordable if they are not each carrying a code block.
            let answer = (i == recent.count - 1) ? turn.a : Self.collapseCodeBlocks(turn.a)
            messages.append(["role": "user", "content": turn.q])
            messages.append(["role": "assistant", "content": answer])
        }

        let lockBlock = buildLockedConstraintBlock(for: currentQuestion)
        let hasResumeFacts = !resumeFacts.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && resumeFacts != "[NO RESUME]"
        let formatReminder = buildFormatReminder(qType: qType, question: currentQuestion,
                                                 isDrillDown: drillDown,
                                                 hasResume: hasResumeFacts, resumeFacts: resumeFacts)
        let contextNote = buildContextNote()

        var historyHint = ""
        if let last = history.last {
            let preview = String(last.a.prefix(250)) + (last.a.count > 250 ? "..." : "")
            historyHint = "[Last question was: \"\(last.q)\"]\n[Your last answer: \(preview)]\n\nCHECK BEFORE ANSWERING:\n  - Already answered this topic? -> reuse that answer consistently.\n  - Drill-down on last answer? -> MICRO: pull exact fact, 1-2 sentences.\n  - Brand new topic? -> use format reminder above.\n\n"
        }

        let userMsg = hintsBlock(hints) + lockBlock + "FORMAT (read BEFORE answering): " + formatReminder + "\n\n" + contextNote + historyHint + "QUESTION: " + currentQuestion
        messages.append(["role": "user", "content": userMsg])
        return messages
    }

    // Live hints the candidate typed RIGHT NOW — highest-priority facts to build the
    // answer around. Treated as true even when there's no resume.
    private func hintsBlock(_ hints: String) -> String {
        let h = hints.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty else { return "" }
        return "CANDIDATE'S LIVE HINTS (the candidate just typed these to steer your answer — treat them as TRUE facts about the candidate and build the answer around them; blend with the resume if present, otherwise use them alone, never contradict them):\n\(h)\n\n"
    }

    // MARK: - Context Note

    private func buildContextNote() -> String {
        guard !coveredTopics.isEmpty || !mentionedExamples.isEmpty else { return "" }
        var sb = "[INTERNAL — DO NOT REPEAT TO INTERVIEWER]\n"
        if !coveredTopics.isEmpty {
            sb += "Topics used this session: \(Array(coveredTopics.prefix(15)).joined(separator: ", ")). Use different angles.\n"
        }
        if !mentionedExamples.isEmpty {
            sb += "Companies/examples used: \(Array(mentionedExamples.prefix(10)).joined(separator: ", ")). Prefer fresh ones.\n"
        }
        sb += "\n"
        return sb
    }

    // MARK: - Topic Tracking

    private func trackCoveredContent(text: String) {
        let lower = text.lowercased()
        let topics = ["kubernetes","kafka","terraform","gitops","prometheus","grafana",
            "opentelemetry","docker","spring boot","microservices","aws","api","rest",
            "database","sql","nosql","mongodb","postgres","ci/cd","jenkins","github actions",
            "iam","security","secrets","agile","scrum","leadership","communication","conflict",
            "performance","testing","deployment","observability","streaming","lakehouse",
            "iceberg","spark","trino","service mesh","eks","linux","bash","python","java",
            "node","react","s3","ec2","lambda","api gateway","ecs","fargate","vpc"]
        for t in topics { if lower.contains(t) { coveredTopics.insert(t) } }

        let entities = ["freight pipeline","observability engine","real-time pipeline",
                       "distributed monitoring","event-driven","message queue","data lake","feature store"]
        for e in entities { if lower.contains(e) { mentionedExamples.insert(e) } }
    }
}
