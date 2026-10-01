import Foundation

// ══════════════════════════════════════════════════════════════════════════
// The words that matter in THIS interview: the company, the role's tech stack, the names and
// projects on the resume. The speech engine reads them from vocab.txt and gives them to the
// recogniser as keyterms, so "Kubernetes" is not written "Kubernets" and a candidate's own
// employer is not guessed.
//
// Windows has done this since the start (MainWindow.xaml.cs WriteVocabFile and
// ExtractVocabTerms). The Mac never wrote the file, so the engine only ever had its built-in
// list. Same rules here, including the part that keeps personal details out: the file is plain
// text, because the engine reads it directly.
// ══════════════════════════════════════════════════════════════════════════
enum VocabTerms {
    /// Words that start sentences and say nothing about this interview.
    private static let stop: Set<String> = [
        "the", "and", "for", "with", "you", "your", "our", "we", "this", "that", "are", "is", "as", "at",
        "or", "by", "be", "it", "if", "so", "but", "not", "all", "can", "will", "job", "role", "team", "work",
        "years", "year", "experience", "skills", "company", "about", "requirements", "responsibilities",
        "description", "position", "please", "must", "have", "strong", "good", "new", "more", "who", "what",
        "when", "where", "why", "how", "we're", "you'll", "we'll", "their", "there", "here", "then", "than",
    ]

    /// At most this many, so the engine's budget is not spent on the tail.
    static let limit = 170

    static func extract(from text: String, company: String) -> [String] {
        var found: [String] = []
        var seen = Set<String>()
        func add(_ raw: String) {
            let w = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:()\"'!? \n\t"))
            guard w.count >= 2, w.count <= 40, !stop.contains(w.lowercased()), !isPersonalDetail(w) else { return }
            if seen.insert(w.lowercased()).inserted { found.append(w) }
        }
        let companyName = company.trimmingCharacters(in: .whitespacesAndNewlines)
        if !companyName.isEmpty { add(companyName) }

        guard let regex = try? NSRegularExpression(pattern: #"[A-Za-z][A-Za-z0-9\.\+/#\-]*"#) else { return found }
        let ns = text as NSString
        let tokens = regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
        // A recurring proper noun is kept, a one-off capital at the start of a sentence is not.
        var freq: [String: Int] = [:]
        for t in tokens { freq[t.lowercased(), default: 0] += 1 }

        for w in tokens {
            if found.count >= limit { break }
            let chars = Array(w)
            let acronym = (2...6).contains(chars.count) && chars.allSatisfy { $0.isUppercase || $0.isNumber } && chars.contains { $0.isLetter }
            let tech = w.contains(where: { ".+#/".contains($0) }) || (chars.contains { $0.isNumber } && chars.contains { $0.isLetter })
            let internalCaps = chars.count >= 3 && chars.dropFirst().contains { $0.isUppercase }      // React, MongoDB, TypeScript
            let repeatedProper = (chars.first?.isUppercase ?? false) && chars.count >= 3 && (freq[w.lowercased()] ?? 0) >= 2
            if acronym || tech || internalCaps || repeatedProper { add(w) }
        }
        return found
    }

    /// Contact details and other fragments that are neither speech nor anybody's business.
    /// Nobody says an email address out loud in an interview, and a short fragment is worse than
    /// useless: a resume from Illinois put "IL" in the list, and a hint is exactly the nudge that
    /// turns "I'll" into "IL" in a transcript.
    static func isPersonalDetail(_ word: String) -> Bool {
        if word.contains("@") { return true }                                  // email
        if word.contains("/") { return true }                                  // URL or handle
        // A domain, but only where something precedes the dot. ".NET" is a framework this
        // candidate may be asked about.
        for suffix in [".com", ".org", ".net", ".io", ".co", ".dev"] {
            if let r = word.range(of: suffix, options: .caseInsensitive), r.lowerBound > word.startIndex { return true }
        }
        let digits = word.filter { $0.isNumber }.count
        if digits > 0 && digits * 2 >= word.count { return true }             // phone number, postcode
        // A long word ending in a run of digits is a username: "pavankrishna2528". Four in a row,
        // so "gpt-oss-20b" and "llama3" survive.
        if word.count >= 8, word.range(of: #"\d{4}"#, options: .regularExpression) != nil { return true }
        if word.count == 2, word.allSatisfy({ $0.isUppercase }) { return true } // a state code
        return false
    }
}
