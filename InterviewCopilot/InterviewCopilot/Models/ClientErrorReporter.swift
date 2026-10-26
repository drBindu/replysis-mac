import Foundation

// ══════════════════════════════════════════════════════════════════════════
// Tells the server, quietly, about a problem a person ran into (Windows MAC_CATCHUP, 2026-10-19: "Every problem a person hits is
// reported to admin"). Only crashes reached admin before (through Sentry), so a tester with no microphone never showed up. Every
// problem kind the app puts on screen is now posted once a run to the same client-error endpoint Windows uses, with the situation
// it happened in appended, and shows in the admin portal's Live, Problems filter as "Problem.<kind>".
//
// What is sent: the app version, the macOS version, the kind, and a short message with emails, tokens, JWTs and file paths removed.
// No account, no answer, no resume, no transcript. Each kind once per run, at most 40 kinds. It never shows the person anything,
// never waits for a reply, and a failed post is simply dropped.
// ══════════════════════════════════════════════════════════════════════════
enum ClientErrorReporter {
    static let maxProblemsPerRun = 40
    static let maxMessageLength = 200

    /// A short, stable id from free text, so the same problem groups together in admin.
    static func slug(_ text: String) -> String {
        let t = text.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return t.count > 48 ? String(t.prefix(48)) : t
    }

    /// The message with emails, tokens, JWTs and file paths taken out, cut to 200 characters.
    static func sanitize(_ message: String) -> String {
        let s = sanitizeLong(message)
        return s.count > maxMessageLength ? String(s.prefix(maxMessageLength)) : s
    }

    /// Whether this kind goes out now: once per run, at most 40 kinds. Pure, so a test can drive it with its own set.
    static func shouldSend(kind: String, seen: inout Set<String>) -> Bool {
        guard seen.count < maxProblemsPerRun, !kind.isEmpty else { return false }
        return seen.insert(kind).inserted
    }

    /// The body posted to /api/v1/diagnostics/client-error. "detail" starts with the stealth state and then carries the engine's
    /// recent technical lines (what it found, what failed), and "user" is the signed-in email, so admin can tell whose problem it is
    /// and why (Windows, 2026-10-21 and 2026-10-22).
    static func payload(kind: String, message: String, version: String, os: String,
                        stealth: String = "", engineTail: [String] = [], user: String = "") -> [String: Any] {
        let detail = ((stealth.isEmpty ? [] : [">>> " + stealth]) + engineTail).joined(separator: " | ")
        return ["version": version, "os": os, "source": "mac", "type": "Problem." + kind, "message": sanitize(message), "frames": "",
                "detail": String(detail.prefix(6000)), "user": user]
    }

    // ── The engine's technical lines, for "detail" ───────────────────────────────────────────────
    // Allowlist only: a line must start with ">>>", name something technical, and carry nothing that can hold speech or an answer,
    // so nothing a person said leaves the computer. The last 40 are kept.
    static let techWords = ["MIC", "SYSTEM AUDIO", "loopback", "tap", "FATAL", "WARNING", "failed", "error", "device", "MODE",
                            "Deepgram", "connection", "NO_MICROPHONE", "ENGINE", "PROVIDER", "STEALTH", "STATUS"]
    static let speechWords = ["words were", "DEBUG", "FINAL", "PARTIAL", "segment", "said", "transcript", "text="]
    static let engineTailLength = 40

    /// The line as it may be kept, or nil when it must not leave the computer.
    static func technicalLine(_ line: String) -> String? {
        guard line.hasPrefix(">>>") else { return nil }
        guard techWords.contains(where: { line.range(of: $0, options: .caseInsensitive) != nil }) else { return nil }
        guard !speechWords.contains(where: { line.range(of: $0, options: .caseInsensitive) != nil }) else { return nil }
        let cut = line.count > 240 ? String(line.prefix(240)) : line
        return sanitizeLong(cut)
    }

    /// Emails, tokens, JWTs and file paths taken out, at any length.
    static func sanitizeLong(_ text: String) -> String {
        var s = text
        let rules: [(String, String)] = [
            // a path, and the "Application Support" kind of folder name that has a space and a capital in it
            (#"(?:/Users|/Volumes|/private|/var|/Applications|/Library)/[^\s"'<>|]+(?: (?-i:[A-Z])[^\s"'<>|]*)*"#, "[path]"),
            (#"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, "[email]"),
            (#"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#, "[token]"),
            (#"\b(bearer|token|api[_-]?key|password)\s*[:=]?\s*[^\s,;]+"#, "$1 [redacted]"),
        ]
        for (pattern, replacement) in rules {
            s = s.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
        }
        return s
    }

    static func request(backendUrl: String, payload: [String: Any]) -> URLRequest? {
        guard let url = URL(string: backendUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/v1/diagnostics/client-error"),
              let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 5
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        return req
    }
}
