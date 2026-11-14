import Foundation

// Which interview language the picker offers and the engine is started in (Windows LanguageRules, MAC_CATCHUP 2026-11-07
// round 53). "Telugu (Sarvam AI)" needed a Sarvam key that no customer has, so the engine exited at once and nothing was
// ever heard. It is no longer offered, and a saved Sarvam language with no key starts the engine in English.
enum LanguageRules {
    /// The picker: the same list and codes as Windows. No language that needs a key a customer cannot get.
    static let offered: [(name: String, code: String)] = [
        ("English", "en"), ("Hindi", "hi"), ("Tamil", "ta"),
        ("Bengali", "bn"), ("Marathi", "mr"), ("Urdu", "ur"), ("Spanish", "es"),
        ("French", "fr"), ("German", "de"), ("Portuguese", "pt"), ("Italian", "it"),
        ("Mandarin Chinese", "cmn"), ("Japanese", "ja"), ("Korean", "ko"),
        ("Arabic", "ar"), ("Russian", "ru"),
    ]

    /// Codes the engine routes to Sarvam AI. Keep in sync with SARVAM_LANG_MAP in speechmatics_engine.py and Windows.
    static let sarvamLanguages: Set<String> = ["te", "kn", "ml", "gu", "pa", "or", "as"]

    static let sarvamNames: [String: String] = ["te": "Telugu", "kn": "Kannada", "ml": "Malayalam", "gu": "Gujarati",
                                                "pa": "Punjabi", "or": "Odia", "as": "Assamese"]

    /// The language the engine is started in: the saved one, except a Sarvam language with no key, which is English.
    static func engineLanguage(saved: String?, sarvamKey: String?) -> String {
        let code = (saved ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if code.isEmpty { return "en" }
        let key = (sarvamKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if sarvamLanguages.contains(code) && key.isEmpty { return "en" }
        return code
    }

    /// The picker's list for the language now chosen: a Sarvam language kept from an older version (it has its own key) is
    /// still shown, so the picker never shows nothing selected.
    static func pickerList(current: String) -> [(name: String, code: String)] {
        guard sarvamLanguages.contains(current), !offered.contains(where: { $0.code == current }) else { return offered }
        return offered + [(sarvamNames[current] ?? current, current)]
    }

    /// A language change made mid-interview waits for the question (the engine restart takes about a second). In Auto
    /// the microphone never closes, so "not listening" never came and the change waited for the end of the interview
    /// (Mac bug round 7). It applies once no answer is being written and nobody has spoken for 1.5 s with nothing
    /// unanswered on screen.
    static func canApplyPendingChange(listening: Bool, processing: Bool, unansweredText: String, secondsSinceSpeech: TimeInterval) -> Bool {
        if processing { return false }
        if !listening { return true }
        return unansweredText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && secondsSinceSpeech >= 1.5
    }
}
