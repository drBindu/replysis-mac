import Foundation

// MARK: - Question Type
enum QuestionType {
    case yesNo, intro, technical, behavioral, situational
    case weakness, whyRole, salary, availability, followUp
    case preference, memoryRecall, contextStatement, logistics, general
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
        "what do you see", "can you see", "do you see", "you can see",
        "sharing my screen", "share my screen", "shared my screen",
        "in front of you", "shown here", "displayed here", "up on the",
        "solve this", "fix this", "debug this", "explain this",
        "this code", "this error", "this problem", "this question",
        "this diagram", "this snippet", "this function", "this output",
        "what is this", "what's this", "read this", "walk me through this",
    ]

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
        return screenReferencePhrases.contains { q.contains($0) }
    }

    /// Deliberately NARROW: anything it is unsure about stays on the screen path, because
    /// while a screen is being shared most questions really are about it.
    static func isPersonalQuestion(_ question: String) -> Bool {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if refersToScreen(trimmed) { return false }   // "this code" always wins
        let q = trimmed.lowercased()
        return personalQuestionPhrases.contains { q.contains($0) }
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

    func isSmallTalk(_ q: String) -> Bool {
        let t = q.lowercased()
        return t.contains("how are you") ||
               (t.contains("how") && t.contains("going")) ||   // how's it going / how it going
               t.contains("how you doing") || t.contains("how have you been") ||
               t.contains("how's everything") || t.contains("how is everything") ||
               t.contains("nice to meet") || t.contains("thanks for coming") ||
               t.contains("pleasure to meet")
    }

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
    func getGreetingResponse() -> String { "Hey, great to be here, really looking forward to this conversation!" }
    func getSmallTalkResponse() -> String { "Doing really well, thanks! Excited to be here and learn more about the role." }

    // MARK: - Question Classification

    func classifyQuestion(_ q: String) -> (type: QuestionType, isDrillDown: Bool) {
        return (detectType(q), isDrillDown(q))
    }

    private func detectType(_ q: String) -> QuestionType {
        let t = q.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let hasQuestionMark = t.contains("?")

        let startsWithInterviewerInfo =
            t.hasPrefix("my name is") || t.hasPrefix("i am ") || t.hasPrefix("i'm ") ||
            t.hasPrefix("we are ") || t.hasPrefix("we're ") || t.hasPrefix("this role") ||
            t.hasPrefix("this position") || t.hasPrefix("our company") ||
            t.hasPrefix("the company") || t.hasPrefix("i work at") ||
            t.hasPrefix("i work for") || t.hasPrefix("i currently") ||
            t.hasPrefix("just so you know") || t.hasPrefix("fyi") || t.hasPrefix("by the way")
        if startsWithInterviewerInfo && !hasQuestionMark { return .contextStatement }

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
        sb += "  YOU ARE ONLY THE CANDIDATE, speaking out loud. NEVER write the interviewer's questions, NEVER narrate both sides of the conversation, NEVER add a line like 'Now let's get started, tell me about...'. Give YOUR answer in first person and stop.\n"
        sb += "  In the SPOKEN answer, NEVER use bullet points, dashes, asterisks, or numbered lists — speak in flowing sentences only. A list is an instant AI giveaway and an automatic fail. (The MORE TO SAY section below is the one exception, and it is not spoken.)\n"
        sb += "  NEVER introduce yourself by name ('I'm Pavan', 'My name is...') — the interviewer already has your name. Lead with your role or the actual answer.\n"
        sb += "  Answer ONLY what the interviewer actually asked. No lectures, no theory dumps, no padding.\n"
        sb += "  Match length to the question: a simple / logistics / yes-no question gets ONE natural sentence;\n"
        sb += "  a deep question gets a few short spoken paragraphs. When unsure, shorter wins.\n"
        sb += "  Lead with the actual answer first, then at most one crisp supporting detail.\n"
        sb += "  Sound like a warm, confident, likeable human talking out loud — the kind of answer that makes\n"
        sb += "  the interviewer quietly think 'I like this person.' Never a textbook, never a brochure, never an AI.\n\n"

        if hasResume {
            sb += "YOUR RESUME (use only these facts, never invent):\n\(resumeFacts)\n\n"
            sb += "NUMBERS RULE — CRITICAL: Only state a percentage, time, throughput, or any figure that ACTUALLY appears in the resume above (e.g. '500K+ events per minute' is fine — it's in there). NEVER invent a NEW number like '12% accuracy' or 'a 4-hour response time' just to sound impressive or to add 'measurement context' — made-up stats fall apart the moment the interviewer drills in. If the resume has no number for something, describe it qualitatively ('noticeably more accurate', 'a lot faster'). This OVERRIDES the metric-context rule below.\n\n"
        } else {
            sb += "NO RESUME PROVIDED — but you STILL give a strong, confident, human answer every single time. Never stall, never say you're missing details.\n"
            sb += "Answer as a seasoned, likeable software professional.\n"
            sb += "HARD RULE — DO NOT FABRICATE: never state a specific percentage, millisecond, dollar figure, tool name, or company name as if it were a REAL result you personally achieved. You have no resume to back it up, and a made-up '25%, from 3.5s to 2.6s with Redis' falls apart the moment the interviewer drills in.\n"
            sb += "Instead speak qualitatively and about your APPROACH: 'we made it noticeably faster by caching the hot paths and tightening the slow queries' — NOT invented numbers. Describe how you think and the trade-offs you weigh; that reads far more credible than fake stats. This OVERRIDES the metric-context rule below whenever you have no real number.\n"
            sb += "Refer naturally to 'my current team', 'a product I worked on', 'my last project' — never a named company.\n"
            sb += "STACK RULE — DO NOT INVENT A BACKGROUND: with no resume you do not know what this candidate works in, and reaching for the most common CV in existence is the failure that sounds most convincing. NEVER claim a technology as YOUR OWN experience — not 'my Java and Spring Boot background', not 'the React work I've done', not any language, framework, cloud or database — unless the INTERVIEWER named it first, in which case follow their words. Otherwise stay stack-neutral: 'the services I work on', 'our data pipelines', 'the models we ship'. This limits what you CLAIM, never what you ANSWER: explain any technology asked about in full technical depth.\n"
            sb += "Salary: a calm range like $100k-$130k base, open to total comp. Visa/work auth: authorized to work, happy to share specifics. Location/relocation: confident and flexible.\n\n"
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

        if hasResume {
            sb += "RULE 2 — CURRENT JOB FIRST:\n"
            sb += "  Always lead with your most recent role from the resume above.\n"
            sb += "  Never mention an older role or education first.\n\n"
            sb += "RULE 3 — TELL ME ABOUT YOURSELF structure:\n"
            sb += "  1. Who you are NOW (current role + what you do)\n"
            sb += "  2. One key win at current company (specific metric from resume)\n"
            sb += "  3. Previous role briefly (years, key technologies)\n"
            sb += "  4. Education briefly (one sentence)\n"
            sb += "  5. Side projects if any\n"
            sb += "  6. Why THIS company specifically\n"
            sb += "  NEVER start with education. NEVER start with oldest job.\n\n"
        } else {
            sb += "RULE 2 — CURRENT JOB FIRST:\n"
            sb += "  Lead with a generic current role. Never invent a specific company name.\n\n"
            sb += "RULE 3 — TELL ME ABOUT YOURSELF structure (no resume mode):\n"
            sb += "  1. Generic current role + what you do day to day\n"
            sb += "  2. One generic win (no company name)\n"
            sb += "  3. Previous experience briefly (technologies — no company name)\n"
            sb += "  4. Education briefly — 'Computer Science background' without naming a school\n"
            sb += "  5. Why THIS opportunity interests you\n"
            sb += "  NEVER invent specific employer names, school names, or project names.\n\n"
        }

        sb += "RULE 4 — FORMAT (scannable but human, NO bullet symbols):\n"
        sb += "  Write 3-4 SHORT paragraphs separated by ONE blank line.\n"
        sb += "  Each paragraph = ONE theme (2-3 sentences max).\n"
        sb += "  NEVER use bullet symbols ( • * or numbers ).\n"
        sb += "  Mix sentence length: some 3-word fragments, some longer flowing ones.\n"
        sb += "  Sound spoken — like you're explaining to a smart friend over coffee.\n"
        sb += "  For drill-downs / yes-no / preferences / availability: 1-2 short sentences only.\n\n"

        sb += "RULE 5 — YES/NO ANSWERS:\n"
        if hasResume {
            sb += "  Use facts from your resume. 1-2 short sentences. No setup phrases.\n\n"
        } else {
            sb += "  Visa/work auth: authorized to work, can discuss details. 1-2 sentences.\n"
            sb += "  Relocation: Yes/No + openness. 1 sentence.\n"
            sb += "  Background check / drug test: Confident yes. 1 sentence.\n"
            sb += "  Start date: notice period (e.g. '2 weeks'). 1 sentence.\n\n"
        }

        sb += "RULE 6 — BANNED OPENERS (instant AI tell):\n"
        sb += "  Never start with: Great question / Absolutely / Of course / Certainly / Sure /\n"
        sb += "  I'd be happy to / I'm happy to / That's a great question / Thank you for asking /\n"
        sb += "  In my role as / Throughout my career / As a [adjective] professional /\n"
        sb += "  I'm a detail-oriented / I'm a results-driven / I have experience in.\n"
        sb += "  GOOD openers: 'Yeah so...' / 'Honestly...' / 'So...' / 'Basically...' / 'Yeah honestly...'\n\n"

        sb += "RULE 7 — SOUND HUMAN (kill corporate-speak completely):\n"
        sb += "  USE contractions everywhere: I'm, I've, I'd, didn't, wasn't, it's, that's, we'd, won't, can't.\n"
        sb += "  USE natural fillers: yeah, so, honestly, basically, kind of, sort of, you know, I mean, like.\n"
        sb += "  USE self-correction: 'actually, let me back up' / 'I mean, more specifically...'\n\n"
        sb += "  BANNED corporate words (these flag AI in 2026 — NEVER use):\n"
        sb += "    detail-oriented, results-driven, results-oriented, results-focused,\n"
        sb += "    cross-functional, driving initiatives, driving results, driving growth,\n"
        sb += "    operational efficiency, organizational goals, organizational success,\n"
        sb += "    high-impact, mission-critical, business-critical, value-add, value-driven,\n"
        sb += "    key stakeholders, key drivers, key initiatives, strategic alignment,\n"
        sb += "    leverage, leveraging, synergy, synergistic, holistic, paradigm, ecosystem,\n"
        sb += "    optimize, optimization, maximize, facilitate, facilitation, transform,\n"
        sb += "    foster, cultivate, enable, empower, dynamic, motivated, passionate,\n"
        sb += "    dedicated, hardworking, team player, robust, comprehensive, spearheaded,\n"
        sb += "    streamlined, innovative, strategic, end-to-end, best-in-class, world-class,\n"
        sb += "    cutting-edge, deliverables, deliver value, proactive, seamless, seamlessly,\n"
        sb += "    utilize, utilization, delve, deep dive, 'with a focus on', 'passionate about'.\n\n"
        sb += "  REPLACE corporate-speak with plain words:\n"
        sb += "    'facilitate' -> 'help' / 'run' / 'set up'\n"
        sb += "    'utilize' -> 'use'\n"
        sb += "    'leverage' -> 'use' / 'lean on'\n"
        sb += "    'optimize' -> 'make faster' / 'cut down'\n"
        sb += "    'spearheaded' -> 'led' / 'ran'\n"
        sb += "    'robust' -> 'solid' / 'reliable'\n"
        sb += "    'comprehensive' -> 'full' / 'covers everything'\n"
        sb += "    'drive results' -> 'get results' / 'ship stuff'\n"
        sb += "    'key stakeholders' -> 'my manager and the client' / 'the people I worked with'\n\n"

        sb += "RULE 8 — FORCED SPECIFICITY (kill generic answers):\n"
        if hasResume { sb += "  Use facts from your resume above as your factual base.\n" }
        sb += "  For ANY project question, include ALL of these:\n"
        sb += "    1. What the project actually did\n"
        sb += "    2. Real tools used\n"
        sb += "    3. Team size\n"
        sb += "    4. Your SPECIFIC role\n"
        sb += "    5. Rough timeline\n"
        sb += "  Generic phrases like 'delivering technology solutions' are FORBIDDEN.\n\n"

        sb += "RULE 9 — NUMBERS (do NOT fabricate):\n"
        sb += "  Use ONLY numbers that actually appear in your resume or hints. NEVER invent a percentage, a 'before X seconds / after Y seconds', or a 'tracked over N months' — do NOT force that template with made-up figures. That fake before/after pattern is the #1 way these answers get caught.\n"
        sb += "  If you have a REAL number, state it plainly and naturally. If you don't, describe the impact qualitatively ('noticeably faster', 'a lot more accurate', 'big improvement'). No number is far better than a fake one.\n\n"

        sb += "RULE 10 — SESSION MEMORY + DRILL-DOWN MEMORY (CRITICAL):\n"
        sb += "  You have perfect recall of everything said in this interview.\n"
        sb += "  When interviewer drills down: REUSE your earlier specifics.\n"
        sb += "  If you HAVE said it before, open with a callback: 'yeah so like I mentioned...' / 'going back to that...'\n"
        sb += "  NEVER use a callback for something you have not actually said in THIS conversation. Claiming 'as I mentioned' when you didn't reads as evasion to the one person who knows exactly what was said.\n"
        sb += "  If you can't remember an exact detail: 'I'd have to check the exact number but it was around X'\n\n"

        sb += "RULE 11 — NEVER ECHO YOUR RESUME WORD-FOR-WORD:\n"
        sb += "  Your resume is reference data, NOT a script. Always paraphrase.\n\n"

        sb += "RULE 12 — NEVER REPEAT THE SAME PHRASING TWICE:\n"
        sb += "  Every answer must feel freshly spoken. VARY starters, word choices, story angles.\n"
        sb += "  Rotate: 'Yeah so...' / 'Honestly...' / 'So basically...' / 'I mean...' / 'Actually...'\n\n"

        sb += "RULE 13 — IMPERFECT IS HUMAN:\n"
        sb += "  Occasionally self-correct: 'actually wait, let me rephrase that'\n"
        sb += "  Occasionally add uncertainty: 'I think it was around 3 months, maybe 4'\n"
        sb += "  Real candidates aren't perfectly polished. Too perfect = AI.\n\n"

        sb += "RULE 14 — TWO PARTS: THE SPOKEN ANSWER, THEN DEPTH:\n"
        sb += "  Give the spoken answer FIRST, exactly as long as the question deserves — that is what gets read while somebody is waiting, and it must not get longer.\n"
        sb += "  Then, on its own line, the marker: MORE TO SAY\n"
        sb += "  Under it, 4-6 SEPARATE points, each starting with the • character (use • literally, never a hyphen or asterisk).\n"
        sb += "  Each point stands alone — it does NOT continue the sentence above. Use: a specific example, a trade-off, a real number, an edge case, what you would do differently.\n"
        sb += "  These are notes to glance at if the interviewer pushes for more. They are NOT spoken aloud, so they may be terse fragments.\n"
        sb += "  SKIP the MORE TO SAY section entirely for greetings, small talk, yes/no answers, logistics, and anything already complete in one sentence — there is nothing to add to 'I am on STEM OPT', and offering some makes a clean answer look padded.\n\n"

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

    private func buildFormatReminder(qType: QuestionType, question: String, isDrillDown: Bool, concise: Bool = false, hasResume: Bool = true) -> String {
        var reminder = baseFormatReminder(qType: qType, question: question, isDrillDown: isDrillDown)
        // WITHOUT A RESUME THERE ARE NO REAL NUMBERS TO CITE. The reminders below ask for a
        // metric, and this text is the last thing the model reads, so it outranked the
        // no-fabrication rule in the system prompt and the model duly invented one —
        // "kept uptime above 99.9%", "cut response times by 40%". A candidate cannot defend
        // a number they never had, and the interviewer only has to ask one follow-up.
        if !hasResume {
            reminder += " CRITICAL — YOU HAVE NO RESUME: never claim a language, framework, cloud or database as YOUR OWN background unless the interviewer named it first — stay stack-neutral ('the services I work on') rather than inventing a stack, though you still answer any technology question in full depth. Never state a specific percentage, millisecond, dollar amount, team size, or company name as a real result you personally achieved. Describe the impact qualitatively instead ('noticeably faster', 'a lot more reliable') and focus on your APPROACH and trade-offs, which reads as more credible anyway. An invented statistic falls apart the moment the interviewer drills in."
        }
        if concise {
            // Brevity mode is explicitly "just the spoken answer" — no depth section.
            return "BREVITY MODE (this is a SPOKEN answer — keep it under ~15 seconds, at most 2-3 short sentences, no lists, cut all preamble): " + reminder
        }
        // THE DEPTH SECTION HAS TO BE STATED HERE, not only as a rule thousands of
        // characters earlier. This reminder is the last thing the model reads before the
        // question, and it ends with "NO bullet symbols" and "don't pad" — which read as a
        // direct contradiction of the depth section and won, so MORE TO SAY never appeared.
        guard needsDepthSection(qType) else { return reminder }
        return reminder + "\n\nTHEN, after the spoken answer, add a blank line and this exact marker on its own line:\nMORE TO SAY\nUnder it, 4-6 SEPARATE points, each on its own line starting with the • character. Each stands alone (a specific example, a trade-off, a real number, an edge case, what you'd do differently). These are glance-notes if the interviewer pushes — NOT spoken, so terse fragments are fine. The 'no bullets' rule above applies ONLY to the spoken answer, never to this section."
    }

    /// Which questions deserve depth notes. Greetings, yes/no and logistics are complete in
    /// a sentence — offering "more to say" there makes a clean answer look padded.
    private func needsDepthSection(_ qType: QuestionType) -> Bool {
        switch qType {
        case .yesNo, .availability, .logistics, .salary, .contextStatement, .memoryRecall:
            return false
        default:
            return true
        }
    }

    private func baseFormatReminder(qType: QuestionType, question: String, isDrillDown: Bool) -> String {
        if hasLockedConflict(for: question) {
            return "1-2 short sentences. NO bullets. Politely correct, restate your locked answer. Example: 'Actually I said Python earlier, that's still my answer.' Don't justify."
        }
        if isDrillDown {
            return "1-2 short sentences. NO bullets. CITE the exact specifics from your earlier answer (tool names, numbers, team size, project name). If it genuinely IS in your earlier answer, open with 'yeah so like I mentioned...' or 'going back to that...' - otherwise just answer plainly, never claim to have said something you did not. Never invent new contradicting facts."
        }

        let q = question.lowercased()
        switch qType {
        case .preference:
            return "ONE short sentence with a casual filler. Example: 'Honestly, Java. That's what I've used the most.' NO bullets. NO long explanation."
        case .yesNo:
            if q.contains("stem") || q.contains("visa") || q.contains("sponsorship") {
                return "2-3 short sentences in plain language. NO bullets. Example: 'Yeah I'm on STEM OPT, so no sponsorship needed for the next two years.'"
            }
            if q.contains("relocat") { return "1 short sentence. NO bullets. Casual opener + Yes/No + openness." }
            if q.contains("background") || q.contains("drug") { return "1 short sentence. NO bullets. Confident yes, no fluff." }
            return "1-2 short sentences. NO bullets. Direct answer + one detail."
        case .availability:
            return "1 sentence. NO bullets. State notice period naturally. Example: 'I can give two weeks notice, could start the week after.'"
        case .logistics:
            return "Short and natural, like a quick chat — not a form. Default to ONE sentence. BUT if they ask you to 'explain', say 'why', or ask your preference, give the answer + ONE genuine reason (2-3 sentences max, no lecture). Warm and confident. Examples: 'Yeah, I'm based in Dallas, but totally open to relocating for the right role.' / 'Honestly I lean toward hybrid, a couple days in the office for the in-person stuff and the rest remote so I get my focused deep-work time.'"
        case .salary:
            return "2-3 sentences. NO bullets. Range + total comp openness. Example: 'I'm targeting around $120-140k base depending on total package. Open to discussing equity and bonus.'"
        case .intro:
            return "3-4 SHORT scannable paragraphs separated by blank lines. NO bullet symbols. P1: Who you are now + current role. P2: One specific win — cite a metric ONLY if your resume actually contains one, otherwise describe the result qualitatively and name the tools used. P3: Previous role briefly. P4: Why this company (something specific). Mix sentence length. Use 'yeah', 'so', 'honestly'."
        case .technical:
            return "3-4 SHORT paragraphs separated by blank lines. NO bullet symbols. P1: One-sentence definition in plain words. P2: REAL example from YOUR work. P3: Something tricky and how you handled it. P4 (optional): Result or lesson."
        case .behavioral:
            return "3-5 SHORT paragraphs separated by blank lines. NO bullet symbols. NOT textbook STAR. P1: Scene casually. P2: Concrete problem. P3: What YOU personally did. P4: How it turned out — use a real number ONLY if your resume has one, otherwise describe the result qualitatively. NEVER invent stats."
        case .weakness:
            return "2-3 SHORT paragraphs. NO bullets. Real weakness, no humble-brags. Casual: 'honestly, I used to...' Mention steps + evidence of progress."
        case .whyRole:
            return "2-3 SHORT paragraphs. NO bullets. Name something CONCRETE about THIS company. No generic 'I'm passionate about your mission' fluff."
        case .situational:
            return "2-3 SHORT paragraphs. NO bullets. P1: A real past situation. P2: How it applies. Concrete specifics."
        case .contextStatement:
            return "1-2 SHORT conversational sentences acknowledging what the interviewer shared. DO NOT launch into your own intro. NO bullets."
        case .memoryRecall:
            return "1-2 SHORT sentences ONLY. Answer exactly what was asked. DO NOT add your own background. Stop there."
        case .followUp:
            return "1-2 SHORT paragraphs. NO bullets. Add NEW detail only — never repeat prior content."
        default:
            // Catch-all for ANY question type not explicitly handled above. Don't force
            // a fixed shape — let the model judge what THIS specific question needs.
            return "This is a general question — use your judgment. Read what the interviewer is ACTUALLY asking and answer it directly, the way a sharp human would. Match the length to the question: a quick or factual one gets 1-2 sentences; a deep or open one gets 2-4 short paragraphs. Answer from your real background (or hints), stay specific and human, NO bullet symbols, and don't pad."
        }
    }

    // MARK: - Build Messages

    func buildMessages(resumeFacts: String, currentQuestion: String,
                       qTypeHint: QuestionType? = nil, drillDownHint: Bool? = nil,
                       jobContext: String = "", concise: Bool = false,
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
                                                 isDrillDown: drillDown, concise: concise,
                                                 hasResume: hasResumeFacts)
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
