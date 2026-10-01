import Foundation

// ══════════════════════════════════════════════════════════════════════════
// The interviewer box shows each burst of words the instant it lands. The speech service does
// not deliver words steadily: on a poor connection it sends nothing for a second or two and then
// a whole phrase at once, and a fast speaker's long question arrived as lumps. Typing the words
// in gives the eye something smooth to follow, and the box never runs more than about a third of
// a second behind what was actually heard. Ported from Windows (the transcript types in).
//
// DISPLAY ONLY. Auto, the question that is sent and the session record all read the real text;
// nothing here can delay or change what is answered.
// ══════════════════════════════════════════════════════════════════════════
enum TranscriptTyping {
    /// How quickly the box closes the gap to what was heard: each step clears this fraction of the
    /// remaining text per `catchUpSeconds`. A burst is typed within about a third of a second,
    /// and a few words in a moment or two. Windows' figure is the same: never more than about a
    /// third of a second behind.
    static let catchUpSeconds: TimeInterval = 0.1

    /// The text to show after `dt` more seconds of typing from `shown` toward `target`.
    ///
    /// A recogniser revises itself ("a cue" becomes "a queue"), so `shown` is not always the
    /// start of `target`. Anything past the point where they differ is taken back, and the
    /// corrected words are typed again.
    static func advance(shown: String, toward target: String, dt: TimeInterval) -> String {
        guard !target.isEmpty else { return "" }
        let t = Array(target), s = Array(shown)
        var common = 0
        while common < s.count, common < t.count, s[common] == t[common] { common += 1 }
        let backlog = t.count - common
        guard backlog > 0 else { return String(t[0..<common]) }   // nothing new, or the text got shorter
        // Enough per step to clear the backlog within catchUpSeconds, and never less than one
        // character, so a short phrase still types rather than appearing whole.
        let step = max(1, Int((Double(backlog) * dt / catchUpSeconds).rounded(.up)))
        return String(t[0..<min(t.count, common + step)])
    }
}
