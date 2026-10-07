import Foundation

/// Takes the closing line off an answer when it is the model handing the conversation back instead of
/// finishing: "Let me know if you'd like more detail.", "Would you like me to go deeper?", "Does that make
/// sense?", or a question put to the interviewer ("What does your team use?"). Ported from the Windows
/// AnswerClosers.
///
/// The person reading the answer says it out loud. A candidate who ends every answer by inviting the
/// interviewer to ask for more, or by turning the question around, sounds like a support chat and not like
/// someone who has answered. The prompt says to stop on the last point; this is the net under it, because a
/// prompt is a request and the model sometimes ignores it.
///
/// Deliberately narrow. A sentence goes only when it starts like a hand-back, so advice that happens to begin
/// with "If you want fast lookups, use a hash map." is never touched, and the only sentence of an answer is
/// never removed. Code is left exactly as it is.
enum AnswerClosers {
    private static let moreMarker = "MORE TO SAY"

    /// A sentence that starts like an offer to say more or a check that the interviewer is satisfied.
    private static let offer: NSRegularExpression = {
        let pattern =
            #"^(?:and |so |but |also |anyway,? |okay,? )?(?:please )?(?:"# +
            #"let me know|feel free to (?:ask|reach|let|interrupt|stop)|"# +
            #"happy to (?:elaborate|expand|go|dive|walk|share|explain|discuss|clarify|help|answer)|"# +
            #"glad to (?:elaborate|expand|go|dive|walk|share|explain|discuss|clarify|answer)|"# +
            #"i(?:'d| would) be (?:happy|glad) to|"# +
            #"i can (?:also )?(?:go (?:deeper|into|further|over)|dive|elaborate|expand|walk (?:you )?through|give (?:you )?(?:more|an example)|share more|explain (?:more|further))|"# +
            #"would you like|do you want (?:me|to hear|more)|want me to|"# +
            #"does (?:that|this) (?:make sense|help|answer|cover|sound|clear)|did (?:that|this) (?:make sense|help|answer|cover)|"# +
            #"is there (?:anything|something|a particular|any)|"# +
            #"hope (?:that|this) (?:helps|answers|clears)|how does (?:that|this) sound|"# +
            #"if you(?:'d| would)? (?:like|want|prefer),? (?:me )?to |if you(?:'d| would) like,? i |if you want,? i |"# +
            #"if that(?:'s| is) (?:helpful|useful))"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    private static func isOffer(_ s: String) -> Bool {
        // The model writes a typographic apostrophe as often as a plain one.
        let plain = s.replacingOccurrences(of: "\u{2019}", with: "'")
        return offer.firstMatch(in: plain, range: NSRange(plain.startIndex..., in: plain)) != nil
    }

    /// - Parameter allowClosingQuestion: True when the interviewer has just invited the candidate's
    ///   questions. Then a closing question IS the answer and stays; offers to say more are still taken off.
    static func stripTrailingOffer(_ text: String, allowClosingQuestion: Bool = false) -> String {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }

        // Inside code, or ending on code: nothing here is prose to tidy.
        if countFences(text) % 2 == 1 { return text }
        let head: String
        let prose: String
        if let r = text.range(of: "```", options: .backwards) {
            head = String(text[..<r.upperBound])
            prose = String(text[r.upperBound...])
        } else {
            head = ""
            prose = text
        }
        if prose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }

        let spoken: String
        let more: String
        if let m = prose.range(of: moreMarker, options: .caseInsensitive) {
            spoken = String(prose[..<m.lowerBound])
            more = String(prose[m.lowerBound...])
        } else {
            spoken = prose
            more = ""
        }

        let newSpoken = stripSpoken(spoken, allowClosingQuestion: allowClosingQuestion)
        let newMore = more.isEmpty ? "" : stripBullets(more)
        if newSpoken == spoken && newMore == more { return text }

        var joined = newSpoken
        if !newMore.isEmpty {
            joined = trimEnd(newSpoken) + (newSpoken.isEmpty ? "" : "\n\n") + newMore
        }
        return head + joined
    }

    private static func stripSpoken(_ spoken: String, allowClosingQuestion: Bool) -> String {
        let trimmed = trimEnd(spoken)
        var result = trimmed
        while true {
            let start = lastSentenceStart(result)
            if start <= 0 { break }                      // never remove the only sentence
            let last = String(result.dropFirst(start)).trimmingCharacters(in: .whitespacesAndNewlines)
            let closers = CharacterSet(charactersIn: "\"')\u{201D}\u{2019}")
            var tail = last
            while let c = tail.unicodeScalars.last, closers.contains(c) { tail.unicodeScalars.removeLast() }
            let isQuestion = tail.hasSuffix("?")
            let drop = isOffer(last) || (isQuestion && !allowClosingQuestion)
            if !drop { break }
            result = trimEnd(String(result.prefix(start)))
        }
        return result.count == trimmed.count ? spoken : result
    }

    /// Offers at the end of the bullets under MORE TO SAY.
    private static func stripBullets(_ more: String) -> String {
        let lines = more.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var keep = lines.count
        let bullets = CharacterSet(charactersIn: "\u{2022}-* ")
        while keep > 1 {
            let line = lines[keep - 1].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: bullets).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || isOffer(line) { keep -= 1 } else { break }
        }
        return keep == lines.count ? more : trimEnd(lines.prefix(keep).joined(separator: "\n"))
    }

    /// Where the last sentence of `s` starts (a character offset), or 0 when there is only one sentence.
    private static func lastSentenceStart(_ s: String) -> Int {
        let chars = Array(s)
        var start = 0
        var i = 1
        while i < chars.count {
            if chars[i].isWhitespace && ".!?".contains(chars[i - 1]) {
                var j = i
                while j < chars.count && chars[j].isWhitespace { j += 1 }
                start = j
                i = j
            } else {
                i += 1
            }
        }
        return start
    }

    private static func countFences(_ s: String) -> Int {
        var count = 0
        var rest = s[...]
        while let r = rest.range(of: "```") {
            count += 1
            rest = rest[r.upperBound...]
        }
        return count
    }

    private static func trimEnd(_ s: String) -> String {
        var out = s
        while let last = out.last, last.isWhitespace { out.removeLast() }
        return out
    }
}
