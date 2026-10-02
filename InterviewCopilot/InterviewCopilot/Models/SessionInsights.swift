import Foundation

// ══════════════════════════════════════════════════════════════════════════
// What Past Sessions shows about an interview, worked out from its transcript: how long it
// lasted, how many questions, the longest answer, and what KIND of question each was, so a long
// transcript can be skimmed. Windows has the same chips (4b of the handoff).
//
// The kind is guessed from cue words, so it is a hint, never a promise.
// ══════════════════════════════════════════════════════════════════════════
enum QuestionKind: String, CaseIterable {
    case fromScreen = "FROM SCREEN"
    case behavioural = "BEHAVIOURAL"
    case systemDesign = "SYSTEM DESIGN"
    case coding = "CODING"
    case general = "GENERAL"
}

struct QAPair: Identifiable, Equatable {
    let id = UUID()
    let question: String
    let answer: String
    var kind: QuestionKind { SessionInsights.kind(of: question) }
    /// The spoken answer. What follows "MORE TO SAY" is the extra points, not the answer.
    var spokenAnswer: String { SessionInsights.spoken(answer) }
    var moreToSay: String { SessionInsights.extra(answer) }
    var answerWords: Int { spokenAnswer.split(whereSeparator: { $0.isWhitespace }).count }
}

enum SessionInsights {
    /// Question and answer pairs from a transcript file ("Q: ..." then "A: ...", answers may run on
    /// over several lines).
    static func pairs(in content: String) -> [QAPair] {
        var out: [QAPair] = []
        var q = "", a = "", inAnswer = false
        func flush() {
            let question = q.trimmingCharacters(in: .whitespacesAndNewlines)
            if !question.isEmpty { out.append(QAPair(question: question, answer: a.trimmingCharacters(in: .whitespacesAndNewlines))) }
        }
        for line in content.components(separatedBy: "\n") {
            if line.hasPrefix("Q:") {
                flush()
                q = String(line.dropFirst(2)); a = ""; inAnswer = false
            } else if line.hasPrefix("A:") {
                a = String(line.dropFirst(2)); inAnswer = true
            } else if inAnswer {
                a += "\n" + line
            }
        }
        flush()
        return out
    }

    static func spoken(_ answer: String) -> String {
        if let r = answer.range(of: "MORE TO SAY") { return String(answer[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines) }
        return answer
    }
    static func extra(_ answer: String) -> String {
        guard let r = answer.range(of: "MORE TO SAY") else { return "" }
        return String(answer[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cue words, in the order they are tried. A question about designing a system that mentions
    /// code is still a design question, and "tell me about a time you debugged" is behavioural.
    static func kind(of question: String) -> QuestionKind {
        let q = question.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { q.contains($0) } }
        if q.hasPrefix("[screen") || has(["on my screen", "on the screen", "this screen", "shared screen"]) { return .fromScreen }
        if has(["tell me about a time", "tell me about yourself", "describe a time", "describe a situation", "give me an example of a time",
                "conflict", "your strength", "your weakness", "greatest weakness", "leadership", "difficult coworker", "disagree",
                "deadline", "why do you want", "why are you leaving", "where do you see yourself", "failure", "proud of"]) { return .behavioural }
        if has(["design a", "design the", "how would you design", "architecture", "scalab", "distributed", "microservice", "load balanc",
                "high availability", "throughput", "sharding", "message queue", "system design", "rate limiter"]) { return .systemDesign }
        if has(["write a function", "write a program", "write code", "implement", "algorithm", "time complexity", "space complexity",
                "big o", "linked list", "binary tree", "array", "string", "sql query", "leetcode", "debug", "reverse a", "sort "]) { return .coding }
        return .general
    }

    struct Summary: Equatable {
        var questions: Int
        var longestAnswerWords: Int
        var kinds: [(QuestionKind, Int)]
        static func == (a: Summary, b: Summary) -> Bool {
            a.questions == b.questions && a.longestAnswerWords == b.longestAnswerWords
                && a.kinds.map { "\($0.0.rawValue)\($0.1)" } == b.kinds.map { "\($0.0.rawValue)\($0.1)" }
        }
    }

    static func summary(of pairs: [QAPair]) -> Summary {
        var counts: [QuestionKind: Int] = [:]
        for p in pairs { counts[p.kind, default: 0] += 1 }
        let kinds = QuestionKind.allCases.compactMap { k in counts[k].map { (k, $0) } }
        return Summary(questions: pairs.count, longestAnswerWords: pairs.map(\.answerWords).max() ?? 0, kinds: kinds)
    }

    /// "Lasted 38 min", from when the transcript was started to when it was last written. Nil when
    /// that is not worth saying (no span, or a cloud copy that has no such times).
    static func lastedText(from start: Date?, to end: Date?) -> String? {
        guard let start, let end, end > start else { return nil }
        let minutes = Int((end.timeIntervalSince(start) / 60).rounded())
        if minutes < 1 { return "Lasted under 1 min" }
        if minutes < 120 { return "Lasted \(minutes) min" }
        return "Lasted \(minutes / 60) h \(minutes % 60) min"
    }

    /// The same interview seen twice, once from this Mac's file and once from the cloud copy. One
    /// interview must never show twice: they start within minutes of each other and open with the
    /// same question.
    static func isSameInterview(localDate: Date, localFirstQuestion: String,
                                cloudDate: Date, cloudFirstQuestion: String) -> Bool {
        func norm(_ s: String) -> String {
            s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
        }
        guard abs(localDate.timeIntervalSince(cloudDate)) < 15 * 60 else { return false }
        let a = norm(localFirstQuestion), b = norm(cloudFirstQuestion)
        return !a.isEmpty && a == b
    }

    static let deleteExplanation = "This removes this device's transcript and audio. Any cloud backup is kept and may appear again in this list. Local deletion cannot be undone."
}
