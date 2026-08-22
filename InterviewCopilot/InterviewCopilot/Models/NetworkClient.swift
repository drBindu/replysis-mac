import Foundation

@MainActor
class NetworkClient {
    static let shared = NetworkClient()

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        // Time we'll wait with NO bytes arriving before failing. During streaming this
        // resets on every token, so it only bites a truly stuck/cold server — short
        // enough to fail fast and auto-retry, long enough for a cold backend's first byte.
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true   // brief network drop → wait, don't instantly fail
        return URLSession(configuration: config)
    }()

    private let shortSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    private init() {}

    // MARK: - AI Stream

    func streamAnswer(question: String, resume: String, provider: String,
                      messages: [[String: String]],
                      onToken: @escaping (String) -> Void,
                      onDone: @escaping () -> Void,
                      onError: @escaping (String) -> Void) {
        guard let url = URL(string: "\(AppConfig.backendUrl)/api/v1/interview/ask") else {
            onError("Invalid URL"); return
        }

        let payload: [String: Any] = [
            "question": question,
            "resume": resume,
            "provider": provider,
            "messages": messages
        ]
        // Real-time SSE streaming with mid-interview resilience (see streamSSE).
        streamSSE(url: url, body: try? JSONSerialization.data(withJSONObject: payload),
                  onToken: onToken, onDone: onDone, onError: onError)
    }

    // MARK: - Screen cache
    //
    // Sending the picture AHEAD of the question was the larger half of the screen-answer
    // wait: 1,483ms to first word, of which the model was 720ms and most of the rest was
    // the image going up the wire. Cached server-side for ninety seconds, returned only to
    // the identity that sent it, and returned exactly once.

    /// Upload a screenshot now and get an id to reference it by later. Returns nil on any
    /// failure — the caller then sends the bytes inline, which still works.
    func cacheScreenshot(imageBase64: String) async -> String? {
        guard let url = URL(string: "\(AppConfig.backendUrl)/api/v1/interview/screen-cache") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(UserSession.shared.idToken)", forHTTPHeaderField: "Authorization")
        req.setValue(DeviceIdentity.current, forHTTPHeaderField: "X-Device-Id")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["image": imageBase64])
        do {
            let (data, response) = try await session.data(for: req)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return nil
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return obj["imageId"] as? String
        } catch { return nil }
    }

    // MARK: - Screen Analysis Stream

    func streamScreenAnalysis(imageBase64: String, resumeCtx: String, provider: String,
                              transcript: String = "", jobContext: String = "",
                              captureSource: String = "", imageId: String? = nil,
                              onToken: @escaping (String) -> Void,
                              onDone: @escaping () -> Void,
                              onError: @escaping (String) -> Void) {
        guard let url = URL(string: "\(AppConfig.backendUrl)/api/v1/interview/analyze-screen") else {
            onError("Invalid URL"); return
        }

        var payload: [String: Any] = [
            "prompt": buildScreenPrompt(resumeCtx: resumeCtx, transcript: transcript, jobContext: jobContext, captureSource: captureSource),
            "provider": provider
        ]
        // Reference an already-uploaded picture when there is one; otherwise send the bytes,
        // which is what happens whenever the pre-upload did not finish in time or failed.
        if let imageId, !imageId.isEmpty {
            payload["imageIds"] = [imageId]
        } else {
            payload["image"] = imageBase64
        }
        streamSSE(url: url, body: try? JSONSerialization.data(withJSONObject: payload),
                  onToken: onToken, onDone: onDone, onError: onError)
    }

    // MARK: - Resilient SSE engine (shared by both streams)

    /// One streaming engine that keeps a live interview alive when things wobble:
    ///   • 401 → silently refresh the auth token and retry once. The user is only logged
    ///     out if the refresh genuinely fails (dead refresh token) — never on a hiccup.
    ///   • network blip / 5xx before the first token → retry once, automatically & silently.
    ///   • connection drop *mid-answer* → keep the partial answer instead of wiping it
    ///     with a scary error (a truncated answer beats a blank one in front of an interviewer).
    private func streamSSE(url: URL, body: Data?,
                           onToken: @escaping (String) -> Void,
                           onDone: @escaping () -> Void,
                           onError: @escaping (String) -> Void) {
        Task {
            var yielded = false
            for attempt in 0..<2 {
                // Read the freshest token each attempt (it may have just been refreshed).
                let token = await MainActor.run { UserSession.shared.idToken }
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                // Sent alongside the token unconditionally — the backend only consults this
                // for the free-trial-without-sign-in path, and ignores it whenever the
                // Authorization header carries a valid Firebase token (see IdentityResolverService).
                req.setValue(DeviceIdentity.current, forHTTPHeaderField: "X-Device-Id")
                req.httpBody = body
                do {
                    let (bytes, response) = try await session.bytes(for: req)
                    if let http = response as? HTTPURLResponse {
                        if http.statusCode == 402 { onMain { onError("NO_CREDITS") }; return }
                        if http.statusCode == 401 {
                            // Token expired mid-interview — refresh and retry before giving up.
                            if attempt == 0, await UserSession.shared.tryRefreshAsync() { continue }
                            onMain { onError("SESSION_EXPIRED") }; return
                        }
                        // A RATE LIMIT IS NOT A TRANSIENT ERROR, and must fail at once.
                        //
                        // Retrying cannot help: this minute's allowance is spent, and the
                        // retry only doubles the time before the user learns anything —
                        // which makes a limit look like a fault. The free Groq tier is
                        // 8,000 tokens a minute and one full-screen view costs about 1,809
                        // of them, so four screen questions in a minute reaches it.
                        if http.statusCode == 429 {
                            let wait = Self.retryAfterSeconds(http)
                            onMain { onError("RATE_LIMIT:\(wait)") }; return
                        }
                        if !(200...299).contains(http.statusCode) {
                            if attempt == 0 { continue }   // transient 5xx → one silent retry
                            onMain { onError("Server error (\(http.statusCode))") }; return
                        }
                    }
                    for try await line in bytes.lines {
                        guard let tok = Self.tokenFromSSELine(line) else {
                            if line.hasSuffix("[DONE]") { break }
                            continue
                        }
                        if tok == "[DONE]" { break }
                        yielded = true
                        onMain { onToken(tok) }
                    }
                    // Only call onDone when the server actually streamed tokens — an
                    // empty response (yielded=false) means the server sent nothing and
                    // should be retried or surfaced as an error, not a blank answer.
                    if yielded { onMain { onDone() } } else if attempt == 0 { continue }
                    else { onMain { onError("Server returned empty response. Please try again.") } }
                    return
                } catch {
                    // Clean failure before a single token arrived → silent retry once.
                    if attempt == 0 && !yielded { continue }
                    // Dropped mid-answer with text already on screen → keep the partial answer.
                    if yielded { onMain { onDone() } }
                    else { onMain { onError("Connection issue — please try again.") } }
                    return
                }
            }
        }
    }

    /// How long to wait, from Retry-After, as whole seconds. Zero when the server did not
    /// say — the caller must then not invent a number.
    static func retryAfterSeconds(_ http: HTTPURLResponse) -> Int {
        guard let raw = http.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return 0 }
        if let secs = Int(raw) { return max(0, secs) }
        // The header may also be an HTTP date.
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "GMT")
        fmt.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = fmt.date(from: raw) {
            return max(0, Int(date.timeIntervalSinceNow.rounded()))
        }
        return 0
    }

    /// Best-effort warm-up: open the TLS connection and wake the backend so the FIRST
    /// answer of the interview isn't slowed by a cold server. Fire-and-forget.
    func warmUp() {
        guard let url = URL(string: "\(AppConfig.backendUrl)/api/v1/interview/credits") else { return }
        Task {
            // BUG-23 FIX: read idToken inside the Task so we get the freshest token even if a
            // concurrent tryRefreshAsync() updated it between warmUp() being called and now.
            let token = await MainActor.run { UserSession.shared.idToken }
            var req = URLRequest(url: url)
            req.timeoutInterval = 8
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue(DeviceIdentity.current, forHTTPHeaderField: "X-Device-Id")
            _ = try? await shortSession.data(for: req)
        }
    }

    // Deliver a closure to the main actor. Using Task { @MainActor } keeps this within
    // Swift Concurrency's actor model rather than mixing GCD and @MainActor isolation.
    private func onMain(_ block: @escaping @Sendable @MainActor () -> Void) {
        Task { @MainActor in block() }
    }

    // Parse one SSE line ("data: {...}" / "data:{...}") → token, or nil for non-data lines.
    private static func tokenFromSSELine(_ line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        var json = String(line.dropFirst(5))
        if json.hasPrefix(" ") { json.removeFirst() }
        if json == "[DONE]" { return "[DONE]" }
        return parseSSEToken(json)
    }

    // MARK: - Credits

    func fetchCredits() async -> (credits: Int, plan: String, isUnlimited: Bool)? {
        guard let url = URL(string: "\(AppConfig.backendUrl)/api/v1/interview/credits") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(UserSession.shared.idToken)", forHTTPHeaderField: "Authorization")
        req.setValue(DeviceIdentity.current, forHTTPHeaderField: "X-Device-Id")

        do {
            let (data, _) = try await shortSession.data(for: req)
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let credits = obj["credits"] as? Int ?? 0
            let plan = obj["plan"] as? String ?? "free"
            let isUnlimited = obj["isUnlimited"] as? Bool ?? false
            return (credits, plan, isUnlimited)
        } catch { return nil }
    }

    // MARK: - Listening time
    //
    // Credits count questions; Speechmatics charges by the hour of audio. Those two were
    // never connected, so the expensive half of the bill was invisible — a microphone left
    // open all afternoon cost real money and showed up nowhere. The server keeps the running
    // total and refuses a new speech token once the month's allowance is gone; this side just
    // reports what it heard.
    //
    // Both calls swallow every error on purpose. A failed report loses a minute; failing an
    // interview over accounting loses the thing the user actually paid for. The gate that
    // protects the money is server-side already.

    /// Report `minutes` of listening. Returns minutes remaining this month, or nil if the
    /// report did not land. `-1` means the plan is unlimited.
    @discardableResult
    func reportListeningMinutes(_ minutes: Int) async -> Int? {
        guard minutes > 0,
              let url = URL(string: "\(AppConfig.backendUrl)/api/v1/usage/listening") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(UserSession.shared.idToken)", forHTTPHeaderField: "Authorization")
        req.setValue(DeviceIdentity.current, forHTTPHeaderField: "X-Device-Id")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["minutes": minutes])

        do {
            let (data, response) = try await shortSession.data(for: req)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return nil
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return obj["remainingMinutes"] as? Int
        } catch { return nil }
    }

    /// Current listening allowance, without reporting anything. Used at sign-in so the badge
    /// is honest before the first minute of the session has been spent.
    func fetchListeningTime() async -> Int? {
        guard let url = URL(string: "\(AppConfig.backendUrl)/api/v1/usage/listening") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(UserSession.shared.idToken)", forHTTPHeaderField: "Authorization")
        req.setValue(DeviceIdentity.current, forHTTPHeaderField: "X-Device-Id")
        do {
            let (data, _) = try await shortSession.data(for: req)
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return obj["remainingMinutes"] as? Int
        } catch { return nil }
    }

    // MARK: - Session Cloud Backup

    struct CloudTurn {
        let role: String   // "interviewer" | "candidate"
        let text: String
    }

    /// Mirrors the website's own /api/sessions upsert (same Firestore collection,
    /// same auth token) so a session survives even if the local .txt file is lost.
    /// Fire-and-forget: never blocks or affects the local session log.
    func syncSessionToCloud(userEmail: String, sessionId: String?, companyName: String,
                            role: String, resume: String, turns: [CloudTurn], durationSecs: Int,
                            completion: @escaping (String?) -> Void) {
        guard let url = URL(string: "\(AppConfig.backendUrl)/api/sessions") else { completion(nil); return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(UserSession.shared.idToken)", forHTTPHeaderField: "Authorization")
        var body: [String: Any] = [
            "userEmail":     userEmail,
            "companyName":   companyName,
            "role":          role,
            "resume":        resume,
            "turns":         turns.map { ["role": $0.role, "text": $0.text] },
            "durationSecs":  durationSecs
        ]
        if let sessionId = sessionId { body["sessionId"] = sessionId }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        Task {
            do {
                let (data, _) = try await shortSession.data(for: req)
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      obj["success"] as? Bool == true else {
                    dlog("Cloud session sync failed", tag: "SESSION")
                    completion(nil); return
                }
                dlog("Cloud session synced OK — id=\(obj["sessionId"] as? String ?? sessionId ?? "?")", tag: "SESSION")
                completion(obj["sessionId"] as? String)
            } catch {
                dlog("Cloud session sync error: \(error)", tag: "SESSION")
                completion(nil)
            }
        }
    }

    struct CloudSession {
        let id: String
        let content: String   // rebuilt as "Q: ...\nA: ...\n\n" blocks — same shape as the local .txt log
        let date: Date
    }

    /// Sessions saved from the website's real-interview page (or from this app's own
    /// cloud backup) — same Firestore collection, fetched via the same /api/sessions GET
    /// the website's dashboard uses. Guests skipped: no account to fetch under.
    func fetchCloudSessions() async -> [CloudSession]? {
        let email = UserSession.shared.email
        guard !email.isEmpty,
              let encoded = email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(AppConfig.backendUrl)/api/sessions?email=\(encoded)") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(UserSession.shared.idToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, _) = try await shortSession.data(for: req)
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = obj["sessions"] as? [[String: Any]] else {
                dlog("Cloud sessions fetch failed", tag: "SESSION")
                return nil
            }
            return arr.compactMap { dict -> CloudSession? in
                guard let id = dict["id"] as? String,
                      let turns = dict["turns"] as? [[String: Any]], !turns.isEmpty else { return nil }

                var content = ""
                var pendingQ: String?
                for turn in turns {
                    guard let role = turn["role"] as? String, let text = turn["text"] as? String else { continue }
                    if role == "interviewer" {
                        if let q = pendingQ { content += "Q: \(q)\nA: \n\n" }
                        pendingQ = text
                    } else if role == "candidate" {
                        content += "Q: \(pendingQ ?? "")\nA: \(text)\n\n"
                        pendingQ = nil
                    }
                }
                if let q = pendingQ { content += "Q: \(q)\nA: \n\n" }

                let secs = (dict["_createdAtSeconds"] as? Double) ?? Double(dict["_createdAtSeconds"] as? Int ?? 0)
                let date = secs > 0 ? Date(timeIntervalSince1970: secs) : Date()
                return CloudSession(id: id, content: content, date: date)
            }
        } catch {
            dlog("Cloud sessions fetch error: \(error)", tag: "SESSION")
            return nil
        }
    }

    // MARK: - Helpers

    private static func parseSSEToken(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let err = obj["error"] as? String { return "⚠ Error: \(err)" }
        guard let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let delta = first["delta"] as? [String: Any],
              let content = delta["content"] as? String else { return nil }
        return content
    }

    // Rich, structured screen-analysis prompt — ported 1:1 from the working .NET
    // ScreenAnalyzer.BuildStaticPromptBody so coding answers match the original app.
    func buildScreenPrompt(resumeCtx: String, transcript: String = "", jobContext: String = "", captureSource: String = "") -> String {
        var p = """
You are an expert interview coach helping a candidate in a live interview.
The screenshot was taken with the Replysis app excluded from capture, so you are seeing only the user's own work — so you are seeing whatever was behind it: Zoom/Meet shared screens, browsers with coding problems, job descriptions, terminal output, etc.
IMPORTANT: Look at the ENTIRE screenshot. Identify ALL visible content — browser windows, coding platforms (LeetCode, HackerRank, CoderPad), video call screens, error messages, design mockups, or any interview question text.
Respond using the EXACT structure shown below for the matching content type.

ANSWER THE QUESTION, DO NOT DESCRIBE THE SCREEN BACK TO THEM:
• They are looking at the screen. Describing its panels, its editor and its error
  messages answers nothing, in front of somebody waiting to hear how they would solve it.
• "You can see my screen, right? Can you solve this?" contains ONE real question and it
  is the second. Confirm you can see it in at most four words, and only if asked, then
  answer the actual question.
• Asked to solve something, solve it, with the code. Not a description of the problem.

NOT EVERY QUESTION IS ABOUT THE SCREEN:
• The screen is sent with every question while a shared screen is being watched,
  including questions that have nothing to do with it. "Which language do you prefer?",
  "tell me about yourself", "why are you leaving your current role?" are ordinary
  interview questions that happen to have arrived while a screen was on show.
• When the question is about the candidate, IGNORE the screen entirely. Do not work it
  into the answer, do not mention it.

IF THE PROBLEM STATEMENT IS CUT OFF, SAY SO FIRST:
• A coding problem rarely fits on one screen, and answering from half of it produces a
  confident solution to the wrong constraints.
• When the statement, the constraints or the examples are cut off, open with a section
  headed exactly ━━━ SCROLL ━━━ containing ONE sentence the candidate can say out loud —
  e.g. "Let me scroll down and read the constraints before I answer." — followed by a short
  line naming exactly what is missing.
• Then answer as fully as you can from what IS visible. Do not refuse; a partial answer
  with its gap named is useful, and the app will read the screen again once they scroll.

IF THE SCREEN SHOWS A FAILURE, LEAD WITH IT:
• A compile error, a failed test or a red error panel is the most useful thing on that
  screen and nobody will ask about it — an interviewer waits to see whether you notice.
• Say what is broken and where, in one line, before anything else.

CRITICAL OUTPUT RULES — OBEY EXACTLY:
1. Use ━━━ TITLE ━━━ as section headers — nothing else (no ##, no **, no ---).
2. One blank line after each section header, one blank line before the next header.
3. Bullets use the • character only (never -, *, numbers).
4. No markdown: no **bold**, no _italic_, no backtick code fences.
5. Code goes directly after ━━━ SOLUTION ━━━ with no fences.
6. Never truncate code — write the complete solution even if it's long.
7. Keep non-code sections short and scannable.

─────────────────────────────────────────────────────
IF SCREEN SHOWS A CODING / ALGORITHM PROBLEM, output:
─────────────────────────────────────────────────────

━━━ PROBLEM ━━━
[One sentence: what the problem is asking for]

━━━ APPROACH ━━━
Brute force:  [brief — 1 sentence]  →  O(n²) time
Optimal:      [brief — 1 sentence]  →  O(n) time

━━━ SOLUTION ━━━
[Complete working code. Language = whatever is on screen, default Python.]
[Inline comments on non-obvious lines. Handle edge cases. No truncation.]

━━━ COMPLEXITY ━━━
Time: O(?)   |   Space: O(?)

━━━ SAY THIS ━━━
• "[Opening line to say to the interviewer before coding]"
• "[What to narrate as you write the key part]"
• "[How to wrap up and state the complexity]"

─────────────────────────────────────────────────────
IF SCREEN SHOWS A SYSTEM DESIGN / ARCHITECTURE DIAGRAM, output:
─────────────────────────────────────────────────────

━━━ COMPONENTS ━━━
• [Component name] — [what it does in 1 sentence]

━━━ DATA FLOW ━━━
[2-3 sentences describing how data moves through the system]

━━━ TRADE-OFFS ━━━
• [Scalability / bottleneck / consistency issue]

━━━ IMPROVEMENT ━━━
[One concrete suggestion]

─────────────────────────────────────────────────────
IF SCREEN SHOWS A SQL / DATABASE QUESTION, output:
─────────────────────────────────────────────────────

━━━ QUERY ━━━
[The complete SQL query, ready to run. No fences.]

━━━ EXPLAIN ━━━
[1-2 sentences on how it works and any join/index consideration]

─────────────────────────────────────────────────────
IF SCREEN SHOWS A MULTIPLE CHOICE / QUIZ QUESTION, output:
─────────────────────────────────────────────────────

━━━ ANSWER ━━━
[Correct option — state it directly]

━━━ WHY ━━━
• Correct ([option]): [why it's right — 1 sentence]
• Wrong ([option]):   [why it's wrong — 1 sentence]

━━━ WATCH OUT ━━━
[Any trick or common misconception in this question]

─────────────────────────────────────────────────────
IF SCREEN SHOWS A BEHAVIORAL / SITUATIONAL TEXT QUESTION, output:
─────────────────────────────────────────────────────

━━━ SITUATION ━━━
[Context: where, when, what was at stake — 1-2 sentences]

━━━ ACTION ━━━
• [Specific step you took]
• [Another concrete step]

━━━ RESULT ━━━
[Outcome with a specific number or metric]

─────────────────────────────────────────────────────
IF SCREEN SHOWS AN ERROR, BUG, OR STACK TRACE, output:
─────────────────────────────────────────────────────

━━━ ROOT CAUSE ━━━
[One sentence — the actual problem]

━━━ FIX ━━━
[The corrected code line(s) — complete, ready to paste]

━━━ EXPLAIN ━━━
[One sentence to say out loud to the interviewer]

─────────────────────────────────────────────────────
IF SCREEN CONTENT DOES NOT MATCH ANY ABOVE (e.g. only desktop/wallpaper visible), output:
─────────────────────────────────────────────────────

━━━ WHAT I SEE ━━━
[Describe ALL visible windows, apps, and content — be specific about what applications are open]
If the Replysis app is visible, mention the current transcript and any question being discussed.

━━━ GUIDANCE ━━━
• [Most relevant interview advice based on what you see]
• TIP: For best results, keep your coding platform or the interviewer's shared screen visible on screen when using Screen Analysis

"""
        // Name the window the pixels came from. An answer about the WRONG window is
        // otherwise indistinguishable from a bad answer about the right one, and the user
        // has no way to tell which happened.
        if !captureSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            p += "\n\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\n"
            p += "WHAT WAS CAPTURED: \(captureSource)\n"
            p += "If this is clearly not what the question is about, say so in one line before answering.\n"
        }
        if !transcript.isEmpty {
            p += "\n─────────────────────────────────────────────────────\n"
            p += "WHAT THE INTERVIEWER SAID (audio transcript) — use this to understand what they're asking about the screen:\n"
            p += "─────────────────────────────────────────────────────\n\"\(transcript)\"\n"
        }
        if !jobContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            p += "\n─────────────────────────────────────────────────────\n"
            p += "THE ROLE / COMPANY (tailor any spoken guidance to this):\n"
            p += "─────────────────────────────────────────────────────\n\(jobContext)\n"
        }
        if !resumeCtx.isEmpty && resumeCtx != ResumeParser.noResumeMarker {
            p += "\n─────────────────────────────────────────────────────\n"
            p += "CANDIDATE BACKGROUND (reference only if directly relevant):\n"
            p += "─────────────────────────────────────────────────────\n\(resumeCtx)\n"
        }
        return p
    }

    // Post-processor matching .NET ScreenAnalyzer.PostProcess — strips markdown and
    // normalizes spacing around the ━━━ section headers so output is clean & scannable.
    static func postProcessScreen(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        var text = raw
        // Strip markdown (bold/italic/headings/code fences) but keep ━━━ headers & code
        text = text.replacingOccurrences(of: "\\*{2}([^*\\n]+)\\*{2}", with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\*([^*\\n]+)\\*", with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?m)^#{1,6}\\s+", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "```[a-zA-Z]*\\r?\\n?", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")

        let lines = text.components(separatedBy: "\n")
        var result: [String] = []
        for raw in lines {
            let line = String(raw.reversed().drop(while: { $0 == " " }).reversed())  // trimEnd
            let isHeader = line.hasPrefix("━━━") && line.hasSuffix("━━━")
            if isHeader {
                while result.last == "" { result.removeLast() }
                if !result.isEmpty { result.append("") }
                result.append(line)
                result.append("")
            } else {
                if line == "", result.last == "" { continue }
                result.append(line)
            }
        }
        while result.first == "" { result.removeFirst() }
        while result.last == "" { result.removeLast() }
        return result.joined(separator: "\n")
    }
}
