import Foundation

/// How an answer is cut into the three places it is shown: the part to say, the code in a panel of its own,
/// and the complexity under the code. Ported from the Windows ShowAnswer / StripScaffolding /
/// ScreenAnalyzer.PostProcess so a screen answer and a spoken answer have exactly the same shape on both apps.
enum AnswerLayout {
    struct Parts: Equatable {
        /// What is left once code, headings and the complexity line have moved to their own places.
        var prose = ""
        var code = ""
        var language = ""
        /// "Time O(n)   Space O(1)" when the answer states it next to code, else nil.
        var complexity: String?
    }

    // MARK: - Complexity

    /// A line that IS the complexity statement: it starts with Time, Space, Runtime, Complexity, Overall or
    /// Total (or with O( itself) and gives the figure. This used to be any line containing "O(...)", which
    /// took the spoken answer's own sentence ("I'll use a hash map; this gives O(n) time and O(n) space") out
    /// of the answer and left it in the small complexity bar, so the one thing the candidate has to say was
    /// missing from where they were reading.
    private static let complexityLine = try! NSRegularExpression(
        pattern: #"^[ \t•*\-]*(?:(?:time|space|runtime|complexity|overall|total)\b[^\n]*?\bO\s*\(\s*[^)\n]{1,24}\)[^\n]*|O\s*\(\s*[^)\n]{1,24}\)[^\n]*)$"#,
        options: [.anchorsMatchLines, .caseInsensitive])

    /// The complexity lines of an answer joined for the bar ("Time O(n)   Space O(1)"), or nil when it
    /// states none. At most two lines: time and space; the bar is one line.
    static func complexityOf(_ prose: String) -> String? {
        let ns = prose as NSString
        var found: [String] = []
        for m in complexityLine.matches(in: prose, range: NSRange(location: 0, length: ns.length)) {
            let line = ns.substring(with: m.range)
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t-*\u{2022}\r"))
            if line.count < 4 || line.count > 160 { continue }
            found.append(line)
            if found.count == 2 { break }
        }
        return found.isEmpty ? nil : found.joined(separator: "   ")
    }

    // MARK: - NEED

    /// "NEED" followed by what is missing is the reply to a problem that runs past the bottom of the screen.
    /// With the heading taken off, all that was left was a stray "The constraints section." under "Let me
    /// scroll down". It reads "Still need to see: The constraints section." now.
    private static let needHeading = try! NSRegularExpression(
        pattern: #"^[ \t]*NEED[ \t]*:?[ \t]*(?:\r?\n[ \t]*)?(?=\S)"#, options: [.anchorsMatchLines])

    static func rewriteNeedHeading(_ prose: String) -> String {
        needHeading.stringByReplacingMatches(in: prose, range: NSRange(location: 0, length: (prose as NSString).length),
                                             withTemplate: "Still need to see: ")
    }

    // MARK: - Scaffolding

    private static let scaffoldHeading = try! NSRegularExpression(
        pattern: #"^[ \t]*(SAY THIS|DETAIL|NEED|CAUSE|FIX|APPROACH|SOLUTION|COMPLEXITY)[ \t]*:?[ \t]*\r?$"#,
        options: [.anchorsMatchLines, .caseInsensitive])

    /// What is left of the prose once every part that has its own place on screen has moved there. The
    /// model is asked for headed sections because that is what makes its output parseable; the person
    /// reading mid-interview should never see the headings.
    static func stripScaffolding(_ prose: String, complexityShown: Bool) -> String {
        if prose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "" }
        var cleaned = rewriteNeedHeading(prose)
        cleaned = replace(scaffoldHeading, in: cleaned, with: "")
        // Only when the bar is actually showing it: otherwise removing it would lose it altogether.
        if complexityShown { cleaned = replace(complexityLine, in: cleaned, with: "") }
        cleaned = cleaned.replacingOccurrences(of: #"(\r?\n){3,}"#, with: "\n\n", options: .regularExpression)
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Splitting an answer

    private static let fencedCode = try! NSRegularExpression(
        pattern: #"```[ \t]*([A-Za-z0-9+#_-]*)[ \t]*\r?\n(.*?)(?:```|$)"#, options: [.dotMatchesLineSeparators])

    /// A fence that has just opened and has not yet said its language or ended its line, at the very end of
    /// text that is still arriving. Hidden, so a half-written fence never shows as three backticks.
    private static let partialFenceAtEnd = try! NSRegularExpression(
        pattern: #"(?:^|\n)[ \t]*`{1,3}[A-Za-z0-9+#_-]*[ \t]*\z"#)

    /// Cuts an answer into prose, code and complexity. Any number of fenced blocks become one code panel.
    static func split(_ answer: String) -> Parts {
        var text = answer
        text = replace(partialFenceAtEnd, in: text, with: "")
        let ns = text as NSString
        var code = ""
        var language = ""
        for m in fencedCode.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if language.isEmpty { language = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces) }
            if !code.isEmpty { code += "\n" }
            code += trimEnd(ns.substring(with: m.range(at: 2)))
        }
        // A fence that has opened and not yet closed is still arriving. Its text is already in the panel, so
        // leaving the half-written fence in the prose as well would show the same code twice.
        let prose = replace(fencedCode, in: text, with: "").trimmingCharacters(in: .whitespacesAndNewlines)

        let codeText = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if codeText.isEmpty {
            return Parts(prose: stripScaffolding(prose, complexityShown: false), code: "", language: "", complexity: nil)
        }
        // Read the complexity out of the prose before the prose is trimmed, because trimming removes that line.
        let complexity = complexityOf(prose)
        return Parts(prose: stripScaffolding(prose, complexityShown: complexity != nil),
                     code: codeText, language: language.lowercased(), complexity: complexity)
    }

    // MARK: - Cleaning a screen answer (ScreenAnalyzer.PostProcess)

    private static let fencedBlock = try! NSRegularExpression(
        pattern: #"```[^\n]*\n.*?(?:```|$)"#, options: [.dotMatchesLineSeparators])

    /// Code that arrived without a fence. The prompt asks for a SOLUTION section containing code and the
    /// model does not always fence it, so the sections the prompt itself defines as code are treated as
    /// code, fence or no fence: everything under a SOLUTION, FIX or CODE heading up to the next heading.
    private static let bareCodeSection = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:SOLUTION|FIX|CODE)[ \t]*:?[ \t]*\r?\n(?:(?![ \t]*(?:APPROACH|SOLUTION|COMPLEXITY|SAY THIS|CAUSE|FIX|CODE|ANSWER|DETAIL|NEED|SCREEN NOTES)[ \t]*:?[ \t]*\r?$).*\n?)*"#,
        options: [.anchorsMatchLines])

    /// Runs a text transform over the prose of an answer and never over its code. Markdown cleanup and code
    /// cannot share a pass: the characters that mark emphasis in prose, `*` and `_`, are ordinary syntax in
    /// most languages, so a rule written for one silently rewrites the other.
    static func transformProseOnly(_ text: String, _ transform: (String) -> String) -> String {
        guard !text.isEmpty else { return text }
        var stashed: [String] = []
        func stash(_ re: NSRegularExpression, _ s: String) -> String {
            var out = ""
            var last = 0
            let ns = s as NSString
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                stashed.append(ns.substring(with: m.range))
                out += "\u{E000}\(stashed.count - 1)\u{E001}"
                last = m.range.location + m.range.length
            }
            out += ns.substring(from: last)
            return out
        }
        var masked = stash(fencedBlock, text)
        masked = stash(bareCodeSection, masked)
        var transformed = transform(masked)
        for (i, original) in stashed.enumerated() {
            transformed = transformed.replacingOccurrences(of: "\u{E000}\(i)\u{E001}", with: original)
        }
        return transformed
    }

    /// Long dashes become plain punctuation: a candidate cannot voice an em dash, and it reads as machine
    /// writing. Code is never passed through here.
    static func plainDashes(_ prose: String) -> String {
        var p = prose.replacingOccurrences(of: #"(\S)[ \t]*[—–][ \t]+"#, with: "$1, ", options: .regularExpression)
        p = p.replacingOccurrences(of: "\u{2014}", with: "-").replacingOccurrences(of: "\u{2013}", with: "-")
        return p
    }

    /// True for the short all-capitals labels an answer is built from, such as CAUSE or SAY THIS. Strict: a
    /// sentence the model happened to shout, a line of code in capitals, or anything with punctuation is left
    /// alone, so ordinary content is never reformatted as a heading.
    static func isSectionTitle(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t.count > 24 { return false }
        var hasLetter = false
        for c in t {
            if c.isLetter {
                if c.isLowercase { return false }
                hasLetter = true
            } else if c != " " {
                return false
            }
        }
        return hasLetter
    }

    /// Normalises a screen answer as it arrives: stray markdown off the prose (code untouched), long dashes
    /// out, the notes for the next question removed, headings spaced, and no run of blank lines. Cheap enough
    /// to run on every update, so what shows while it streams is what shows when it is done.
    static func postProcess(_ raw: String) -> String {
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return raw }

        var text = transformProseOnly(raw) { prose in
            plainDashes(PromptBuilder.stripMarkdownPreservingCode(prose)
                .replacingOccurrences(of: #"(?m)^#{1,6}\s+"#, with: "", options: .regularExpression))
        }
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")

        // SCREEN NOTES is written for the next question, not for this answer, so it is removed before
        // display. Only outside code: a line of code is never a note.
        var lines = text.components(separatedBy: "\n")
        var inNotesFence = false
        for (i, l) in lines.enumerated() {
            if l.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inNotesFence.toggle() }
            if !inNotesFence, i > 0, l.uppercased().hasPrefix("SCREEN NOTES") {
                lines = Array(lines[..<i])
                break
            }
        }
        text = lines.joined(separator: "\n")

        // Section titles are bare words on their own line. A blank line before each, none between a title
        // and what it describes, and never more than one blank line anywhere.
        var result: [String] = []
        var inFence = false
        for rawLine in text.components(separatedBy: "\n") {
            let line = trimEnd(rawLine)
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle() }
            if !inFence && isSectionTitle(line) {
                while result.last == "" { result.removeLast() }
                if !result.isEmpty { result.append("") }
                result.append(line.trimmingCharacters(in: .whitespaces))
            } else {
                if line.isEmpty && result.last == "" { continue }
                result.append(line)
            }
        }
        while result.first == "" { result.removeFirst() }
        while result.last == "" { result.removeLast() }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The finished-or-streaming text of a screen answer: cleaned, then the hand-back filter. A screen
    /// answer may end on a clarifying question (a design answer can), so a closing question stays.
    ///
    /// THE ONE PLACE both the streaming view and the finished answer get their text from, so a rule added here cannot be on one and
    /// missing from the other. (On Windows the "nothing asked" rewrite was in the streaming view and left out of the final step, so the
    /// plain line showed while the answer arrived and the invented task came back the moment it finished.)
    static func composeScreenAnswer(_ raw: String) -> String {
        rewriteNothingAsked(AnswerClosers.stripTrailingOffer(postProcess(raw), allowClosingQuestion: true))
    }

    /// A screen with nothing on it to answer (a chat, a document, a desktop) used to get an invented "do this" and a "say this" line
    /// nobody could say aloud, such as "I am ready for the next prompt". The model now writes NOTHING ASKED and one line about the
    /// screen; this turns that into a plain sentence and says what to do next. Anything else passes through unchanged. Windows 1.0.31 item 30.
    static func rewriteNothingAsked(_ text: String) -> String {
        guard !text.isEmpty,
              let re = try? NSRegularExpression(pattern: #"^\s*NOTHING ASKED[ \t]*:?[ \t]*\r?\n?([^\r\n]*)"#, options: [.caseInsensitive]),
              let match = re.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else { return text }
        var line = (text as NSString).substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
        while line.hasSuffix(".") { line.removeLast() }
        let next = "Press F8 when a question or code is showing."
        return line.isEmpty
            ? "No question on this screen. " + next
            : "No question on this screen. It shows: " + line + ".\n\n" + next
    }

    /// What a spoken answer shows while it is still arriving: the part not yet cleaned is never shown.
    static func composeSpokenAnswer(_ cleaned: String, allowClosingQuestion: Bool) -> String {
        AnswerClosers.stripTrailingOffer(cleaned, allowClosingQuestion: allowClosingQuestion)
    }

    // MARK: - What Copy takes

    /// The text a person sees in the answer, for the Copy button: the one quiet line saying what was read, then the part to
    /// say, without the section headings the model writes (SAY THIS, DETAIL) and without the code, which has its own Copy code
    /// button. Copying the raw answer put those headings and the fences in whatever they pasted it into.
    static func copyText(_ answer: String) -> String {
        if answer.contains("\u{2501}\u{2501}\u{2501}") { return answer }   // the older section style is shown as it is
        var rest = answer
        var note = ""
        let first = rest.prefix(while: { $0 != "\n" })
        if first.hasPrefix("From your screen") {
            note = String(first)
            rest = String(rest.dropFirst(first.count))
        }
        let prose = split(rest.trimmingCharacters(in: .whitespacesAndNewlines)).prose
        return [note, prose].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    // MARK: - Small helpers

    private static func replace(_ re: NSRegularExpression, in s: String, with template: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: template)
    }

    private static func trimEnd(_ s: String) -> String {
        var out = s
        while let last = out.last, last.isWhitespace { out.removeLast() }
        return out
    }
}
