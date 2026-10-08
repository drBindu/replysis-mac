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

    /// Logs what the network did for one answer request: whether the connection was reused or
    /// had to be opened, and how long each stage took. A cold start shows up here as
    /// reused=false with real DNS/connect/TLS time, or as a long wait with the connection reused,
    /// which is the server's container being cold. Times only, never content.
    private final class AnswerTimingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didFinishCollecting metrics: URLSessionTaskMetrics) {
            guard let t = metrics.transactionMetrics.last else { return }
            func ms(_ a: Date?, _ b: Date?) -> Int {
                guard let a, let b else { return 0 }
                return Int(b.timeIntervalSince(a) * 1000)
            }
            let line = "NET: answer request — connection \(t.isReusedConnection ? "REUSED" : "NEW"), "
                + "dns \(ms(t.domainLookupStartDate, t.domainLookupEndDate))ms, "
                + "connect \(ms(t.connectStartDate, t.connectEndDate))ms, "
                + "tls \(ms(t.secureConnectionStartDate, t.secureConnectionEndDate))ms, "
                + "server wait \(ms(t.requestEndDate, t.responseStartDate))ms, "
                + "protocol \(t.networkProtocolName ?? "?")"
            Task { @MainActor in dlog(line, tag: "NET") }
        }
    }

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
        // Measure what we are actually asking the server to read. Time-to-first-token is
        // dominated by prefill, and prefill is proportional to prompt size — so "the model is
        // slow" and "we are sending it too much" are indistinguishable without this number.
        let body = try? JSONSerialization.data(withJSONObject: payload)
        let resumeKB = Double(resume.utf8.count) / 1024
        let histKB = Double(messages.reduce(0) { $0 + ($1["content"]?.utf8.count ?? 0) }) / 1024
        dlog(String(format: "PAYLOAD: %.1fKB total — resume %.1fKB, %d history messages %.1fKB, question %d chars",
                    Double(body?.count ?? 0) / 1024, resumeKB, messages.count, histKB, question.count),
             tag: "PERF")
        // Real-time SSE streaming with mid-interview resilience (see streamSSE).
        streamSSE(url: url, body: body,
                  onToken: onToken, onDone: onDone, onError: onError)
    }

    // MARK: - Screen cache
    //
    // Sending the picture AHEAD of the question was the larger half of the screen-answer
    // wait: 1,483ms to first word, of which the model was 720ms and most of the rest was
    // the image going up the wire. Cached server-side for ninety seconds, returned only to
    // the identity that sent it, and returned exactly once.

    /// How one send ahead of the question went.
    struct EarlyUpload {
        /// The id to put in `imageIds`, when the server kept it.
        var id: String?
        /// HTTP status, or 0 when nothing came back.
        var status = 0
        var elapsed: TimeInterval = 0
        /// Stopped because a question was about to be asked, so it says nothing about the line.
        var droppedForQuestion = false
    }

    /// Never waits for connectivity and never retries: a send ahead that cannot go now is not worth holding the line for.
    private let uploadSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config)
    }()
    private var earlyUploadWork: Task<(Data, URLResponse), Error>?
    private var earlyUploadDropped = false

    /// A question is about to be asked: the send ahead stops so the question has the connection.
    func dropEarlyUploadForQuestion() {
        guard let work = earlyUploadWork else { return }
        earlyUploadDropped = true
        work.cancel()
    }

    private func screenCacheRequest(body: Data) -> URLRequest? {
        guard let url = URL(string: "\(AppConfig.backendUrl)/api/v1/interview/screen-cache") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(UserSession.shared.idToken)", forHTTPHeaderField: "Authorization")
        req.setValue(DeviceIdentity.current, forHTTPHeaderField: "X-Device-Id")
        req.httpBody = body
        return req
    }

    /// One bounded request to /screen-cache. Gives up after `timeout` so a doomed upload holds the line for as little time as possible.
    private func sendEarly(_ body: Data, timeout: TimeInterval) async -> (EarlyUpload, Data?) {
        guard let req = screenCacheRequest(body: body) else { return (EarlyUpload(), nil) }
        let started = Date()
        earlyUploadDropped = false
        let work = Task { try await uploadSession.data(for: AppIdentity.label(req)) }
        earlyUploadWork = work
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            work.cancel()
        }
        defer { watchdog.cancel(); earlyUploadWork = nil }
        do {
            let (data, response) = try await work.value
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (EarlyUpload(id: nil, status: status, elapsed: Date().timeIntervalSince(started)), data)
        } catch {
            return (EarlyUpload(id: nil, status: 0, elapsed: Date().timeIntervalSince(started),
                                droppedForQuestion: earlyUploadDropped), nil)
        }
    }

    private func idFrom(_ data: Data?, status: Int) -> String? {
        guard (200...299).contains(status), let data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["imageId"] as? String
    }

    /// Upload a screenshot now and get an id to reference it by later. The id is nil on any failure; the
    /// caller then sends the bytes inline, which still works.
    func cacheScreenshot(imageBase64: String) async -> EarlyUpload {
        guard let body = try? JSONSerialization.data(withJSONObject: ["image": imageBase64]) else { return EarlyUpload() }
        var (result, data) = await sendEarly(body, timeout: UplinkGovernor.uploadTimeout)
        result.id = idFrom(data, status: result.status)
        return result
    }

    /// The screen's words, sent in place of a picture on a line too slow to carry one: kilobytes, not hundreds of them.
    func cacheScreenText(_ text: String) async -> EarlyUpload {
        guard let body = try? JSONSerialization.data(withJSONObject: ["text": text]) else { return EarlyUpload() }
        var (result, data) = await sendEarly(body, timeout: UplinkGovernor.uploadTimeout)
        result.id = idFrom(data, status: result.status)
        return result
    }

    private static let probeBody: Data = {
        // Incompressible filler of the test size, made once. Repeating letters would be squeezed to
        // nothing by anything on the way that compresses, and the test would measure nothing.
        var bytes = [UInt8](repeating: 0, count: UplinkGovernor.probeBytes * 3 / 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let json = "{\"probe\":\"" + Data(bytes).base64EncodedString() + "\"}"
        return Data(json.utf8)
    }()

    /// Times a small throw-away upload to the same server the pictures go to. The server reads the body,
    /// finds no image in it, answers 400 and keeps nothing, so the only thing measured is how fast this
    /// line carries 160 KB. `reached` is true when the server answered the way it should (400, or 200).
    func probeUplink() async -> (reached: Bool, status: Int, elapsed: TimeInterval, droppedForQuestion: Bool) {
        let (result, _) = await sendEarly(Self.probeBody, timeout: UplinkGovernor.probeTimeout)
        return (result.status == 400 || result.status == 200, result.status, result.elapsed, result.droppedForQuestion)
    }

    // MARK: - Screen Analysis Stream

    func streamScreenAnalysis(imageBase64: String, resumeCtx: String, provider: String,
                              question: String = "",
                              transcript: String = "", jobContext: String = "",
                              captureSource: String = "", imageIds: [String]? = nil,
                              screenText: String? = nil,
                              onToken: @escaping (String) -> Void,
                              onDone: @escaping () -> Void,
                              onError: @escaping (String) -> Void) {
        guard let url = URL(string: "\(AppConfig.backendUrl)/api/v1/interview/analyze-screen") else {
            onError("Invalid URL"); return
        }

        var payload: [String: Any] = [
            "prompt": buildScreenPrompt(resumeCtx: resumeCtx, question: question, transcript: transcript,
                                        jobContext: jobContext, captureSource: captureSource),
            "provider": provider
        ]
        // Reference an already-uploaded picture (or the words read from the screen) when there is one;
        // otherwise send the bytes, which is what happens whenever the pre-upload did not finish in time
        // or failed. On a line too slow for a picture the screen's words go inline instead.
        if let imageIds, !imageIds.isEmpty {
            payload["imageIds"] = imageIds
        } else if let screenText, !screenText.isEmpty {
            payload["screenText"] = screenText
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
    /// Set when the server refuses a gzip body; every later request in this run goes plain.
    nonisolated(unsafe) private static var gzipRefused = false

    /// How long to wait before the one silent retry of a failed answer request.
    private static let answerRetryDelay: UInt64 = 250_000_000

    private func streamSSE(url: URL, body: Data?,
                           onToken: @escaping (String) -> Void,
                           onDone: @escaping () -> Void,
                           onError: @escaping (String) -> Void) {
        let enteredAt = Date()
        // Read now, on the main thread where this is called, so the first attempt never waits for the main thread
        // to be free. A retry after a refresh reads it again.
        let firstToken = UserSession.shared.idToken
        // Also read here, not inside the task: measured, reading it from the background task waited 800 ms for the
        // main thread to be free. This module's default isolation is the main actor, and a static that is
        // isolated there is not free to read from another thread.
        let deviceId = DeviceIdentity.current
        let session = self.session
        let onMain: @Sendable (@escaping @Sendable @MainActor () -> Void) -> Void = { block in Task { @MainActor in block() } }
        // OFF the main thread. This used to be a plain Task, which runs on the main actor, so the request did not
        // leave until whatever the window was doing had finished: measured 600 ms between asking for the request
        // and the request starting, right when the answer is being waited for. Only delivering tokens to the
        // screen needs the main thread.
        Task.detached(priority: .userInitiated) {
            var yielded = false
            // Compress once. If the server ever refuses a compressed body (400, 415 or 501), the
            // request is resent PLAIN, once, and stays plain for the rest of this run.
            let gzipped = (Self.gzipRefused || body == nil) ? nil : body.flatMap { Gzip.compress($0) }
            // Nothing is logged before the request has left. Even a log line costs a hop to the main thread, and
            // measured, that hop alone held the request back by over half a second while the window was busy.
            let sizeNote: String? = body.flatMap { b in gzipped.map { "request body \(b.count / 1024)KB to \(max(1, $0.count / 1024))KB with gzip" } }
            var sendPlain = gzipped == nil
            for attempt in 0..<2 {
                // Read the freshest token each attempt (it may have just been refreshed).
                let token = attempt == 0 ? firstToken : await MainActor.run { UserSession.shared.idToken }
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                // Sent alongside the token unconditionally — the backend only consults this
                // for the free-trial-without-sign-in path, and ignores it whenever the
                // Authorization header carries a valid Firebase token (see IdentityResolverService).
                req.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
                if sendPlain || gzipped == nil {
                    req.httpBody = body
                } else {
                    req.httpBody = gzipped
                    req.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
                }
                do {
                    let sentAt = Date()
                    let (bytes, response) = try await session.bytes(for: AppIdentity.label(req), delegate: AnswerTimingDelegate())
                    let headersAt = Date().timeIntervalSince(sentAt)
                    if let http = response as? HTTPURLResponse {
                        // A server that cannot read a compressed body says so BEFORE it charges
                        // anything, so resending the same question plain is safe.
                        if !sendPlain, gzipped != nil, [400, 415, 501].contains(http.statusCode) {
                            Self.gzipRefused = true; sendPlain = true
                            dlog("NET: server refused the compressed request (HTTP \(http.statusCode)) — sending plain from now on", tag: "NET")
                            continue
                        }
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
                            // Transient 5xx → ONE silent retry, after a beat. Straight away it can
                            // hit the very same fault; 250 ms is Windows' measured wait, and safe
                            // because nothing has streamed and the server has refunded.
                            dlog("NET: answer request refused with HTTP \(http.statusCode)\(attempt == 0 ? ", retrying once" : "")", tag: "NET")
                            if attempt == 0 { try? await Task.sleep(nanoseconds: Self.answerRetryDelay); continue }
                            onMain { onError("Server error (\(http.statusCode))") }; return
                        }
                    }
                    for try await line in bytes.lines {
                        // The server's own words, when it has them. Retrying this would only
                        // hit the same limit and double the time before the user is told.
                        if let serverError = Self.errorFromSSELine(line) {
                            // The server's own words, kept in the log: the screen may only show
                            // a generic line, and without this there is no way to tell afterwards
                            // which limit or fault the person actually hit.
                            dlog("NET: server answered with an error instead of an answer: \(serverError.prefix(200))", tag: "NET")
                            onMain { onError("SERVER_MSG:" + serverError) }
                            return
                        }
                        guard let tok = Self.tokenFromSSELine(line) else {
                            if line.hasSuffix("[DONE]") { break }
                            continue
                        }
                        if tok == "[DONE]" { break }
                        if !yielded {
                            dlog(String(format: "NET: first token %.2fs after the request was sent (response headers at %.2fs); it left %.0fms after it was asked for",
                                        Date().timeIntervalSince(sentAt), headersAt, sentAt.timeIntervalSince(enteredAt) * 1000)
                                 + (sizeNote.map { "; " + $0 } ?? ""), tag: "NET")
                        }
                        let firstOne = !yielded
                        let handedAt = Date()
                        yielded = true
                        onMain {
                            if firstOne { dlog(String(format: "NET: first token waited %.0fms for the main thread", Date().timeIntervalSince(handedAt) * 1000), tag: "NET") }
                            onToken(tok)
                        }
                    }
                    // Only call onDone when the server actually streamed tokens — an
                    // empty response (yielded=false) means the server sent nothing and
                    // should be retried or surfaced as an error, not a blank answer.
                    if yielded { onMain { onDone() } } else if attempt == 0 { try? await Task.sleep(nanoseconds: Self.answerRetryDelay); continue }
                    else { onMain { onError("Server returned empty response. Please try again.") } }
                    return
                } catch {
                    // Clean failure before a single token arrived → silent retry once.
                    if attempt == 0 && !yielded { try? await Task.sleep(nanoseconds: Self.answerRetryDelay); continue }
                    // Dropped mid-answer with text already on screen → keep the partial answer.
                    if yielded { onMain { onDone() } }
                    else { onMain { onError("Connection issue. Please try again.") } }
                    return
                }
            }
        }
    }

    /// How long to wait, from Retry-After, as whole seconds. Zero when the server did not
    /// say — the caller must then not invent a number.
    nonisolated static func retryAfterSeconds(_ http: HTTPURLResponse) -> Int {
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
    // ── Keep the connection to the answer server warm ────────────────────────────────
    //
    // The first question after a quiet gap used to cost 2 to 5 seconds (measured 2026-10-01:
    // 2.35s, 1.99s, 4.91s against 0.3s to 0.6s for a question asked right after another).
    // Two things go cold: the connection itself (DNS, TCP and TLS, which on a jittery link is
    // 0.1s to 1.5s) and the answer server's container, which spins down when idle. Windows
    // measured and fixed the same thing (MAC_CATCHUP, "keep-warm"), and the Mac had three faults
    // of its own:
    //   1. it warmed ONCE, when the mic was unmuted, never again;
    //   2. it used `shortSession`, a different connection pool from the one answers use, so it
    //      kept warm a connection no answer ever touched;
    //   3. it called /interview/credits with a token, a heavy route, to do a job a constant
    //      one does.
    // Now: every 25 seconds (shorter than a proxy or home router keeps a quiet connection),
    // a HEAD to the answer server's own constant status route, on the SAME session as answers.
    private var keepWarmTimer: Timer?
    private static let keepWarmInterval: TimeInterval = 25

    func startKeepWarm() {
        guard keepWarmTimer == nil else { return }
        warmUp()
        keepWarmTimer = Timer.scheduledTimer(withTimeInterval: Self.keepWarmInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.warmUp() }
        }
    }

    func stopKeepWarm() { keepWarmTimer?.invalidate(); keepWarmTimer = nil }

    /// After the Mac wakes or the network changes: close the answer connections (their sockets died with the old
    /// line, and a question sent on one waits for a timeout) and open a fresh one now, before anyone asks.
    func refreshConnections() {
        session.reset { [weak self] in
            Task { @MainActor [weak self] in self?.warmUp() }
        }
        dlog("NET: connections reset and a fresh one opening, so the next question does not wait on a dead socket", tag: "NET")
    }

    func warmUp() {
        guard let url = URL(string: "\(AppConfig.backendUrl)/api/v1/resume/status") else { return }
        Task {
            var req = URLRequest(url: url)
            req.httpMethod = "HEAD"          // no body to carry; any reply, even a 404, proves the connection is open
            req.timeoutInterval = 6
            _ = try? await session.data(for: AppIdentity.label(req))
        }
    }

    // Deliver a closure to the main actor. Using Task { @MainActor } keeps this within
    // Swift Concurrency's actor model rather than mixing GCD and @MainActor isolation.
    private func onMain(_ block: @escaping @Sendable @MainActor () -> Void) {
        Task { @MainActor in block() }
    }

    // Parse one SSE line ("data: {...}" / "data:{...}") → token, or nil for non-data lines.
    /// An error the SERVER put inside the stream.
    ///
    /// A rate limit does not always arrive as HTTP 429. This backend answers 200 and then
    /// sends `data: {"error": "This minute's AI allowance is used up…"}` — a better message
    /// than anything written here, because it knows which allowance ran out and how long it
    /// takes to refill. Reading only the HTTP status missed it entirely: no tokens ever
    /// arrived, so the stream looked empty, was silently retried into the same limit, and
    /// surfaced as "Server returned empty response. Please try again." — the useless
    /// wording this whole area exists to remove.
    nonisolated private static func errorFromSSELine(_ line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        var json = String(line.dropFirst(5))
        if json.hasPrefix(" ") { json.removeFirst() }
        guard json.hasPrefix("{"), json.contains("\"error\""),
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return serverErrorText(obj["error"])
    }

    /// The words of an error the server put in a stream: a plain string, or an object carrying a
    /// `message`. An error sent as an object used to fall through as "no tokens", and was retried into the
    /// same fault and shown as an empty reply.
    nonisolated static func serverErrorText(_ value: Any?) -> String? {
        if let text = value as? String { return text.isEmpty ? nil : text }
        if let obj = value as? [String: Any] {
            for key in ["message", "error", "detail", "description"] {
                if let text = obj[key] as? String, !text.isEmpty { return text }
            }
            return "The server could not answer this request."
        }
        return nil
    }

    nonisolated private static func tokenFromSSELine(_ line: String) -> String? {
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
            let (data, response) = try await shortSession.data(for: AppIdentity.label(req))
            // Only a successful reply carrying a real balance counts. An error reply (a 503 from
            // a server having a bad moment, a 401) has a JSON body too, and with every field
            // defaulted it read as "0 credits, free plan": a paying customer was told their free
            // answers were used and was refused (found by testing, 2026-10-01).
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                dlog("Credits: the server answered HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0) — not a balance", tag: "CREDITS")
                return nil
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let credits = obj["credits"] as? Int else {
                dlog("Credits: the reply had no balance in it", tag: "CREDITS")
                return nil
            }
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
            let (data, response) = try await shortSession.data(for: AppIdentity.label(req))
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return nil
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return obj["remainingMinutes"] as? Int
        } catch { return nil }
    }

    /// The same report, but blocking, for use on app termination.
    ///
    /// applicationWillTerminate is the last moment the session's banked remainder can be
    /// billed, and an async Task started there is killed with the process before it reaches
    /// the wire — so the minutes the user actually listened to would be lost precisely at
    /// the point they are supposed to be counted. Bounded at three seconds: macOS will not
    /// wait indefinitely for a terminating app, and a lost minute is better than a hang.
    func reportListeningMinutesBlocking(_ minutes: Int) {
        guard minutes > 0,
              let url = URL(string: "\(AppConfig.backendUrl)/api/v1/usage/listening") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 3
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(UserSession.shared.idToken)", forHTTPHeaderField: "Authorization")
        req.setValue(DeviceIdentity.current, forHTTPHeaderField: "X-Device-Id")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["minutes": minutes])

        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: AppIdentity.label(req)) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 3)
    }

    /// Current listening allowance, without reporting anything. Used at sign-in so the badge
    /// is honest before the first minute of the session has been spent.
    func fetchListeningTime() async -> Int? {
        guard let url = URL(string: "\(AppConfig.backendUrl)/api/v1/usage/listening") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(UserSession.shared.idToken)", forHTTPHeaderField: "Authorization")
        req.setValue(DeviceIdentity.current, forHTTPHeaderField: "X-Device-Id")
        do {
            let (data, _) = try await shortSession.data(for: AppIdentity.label(req))
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
                let (data, _) = try await shortSession.data(for: AppIdentity.label(req))
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
            let (data, _) = try await shortSession.data(for: AppIdentity.label(req))
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

    nonisolated private static func parseSSEToken(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // An error is reported by errorFromSSELine before this is reached; it is never answer text.
        // A line with no "choices" (the final usage chunk, a keep-alive) is simply not a token.
        guard let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let delta = first["delta"] as? [String: Any],
              let content = delta["content"] as? String else { return nil }
        return content
    }

    /// What the app tells the models when it sends a screen. Ported from the Windows ScreenAnalyzer so both
    /// apps ask for the same thing and get the same shape back: SAY THIS first (the part to say), DETAIL
    /// with the code fenced, and the bare section titles the answer view lifts into its own places.
    ///
    /// Two things here are a contract with the server, not style:
    ///   1. A question asked out loud goes after "THE QUESTION:" and is followed by a blank line and
    ///      "Answer in this shape". The server cuts exactly that span out to tell the model what was asked;
    ///      without the marker the answering stage is told only to "analyze what is on the screen".
    ///   2. The reply starts with the part to say, which is what lets the server stream it before the
    ///      code is written.
    func buildScreenPrompt(resumeCtx: String, question: String = "", transcript: String = "",
                           jobContext: String = "", captureSource: String = "") -> String {
        var sb = ""
        func line(_ s: String = "") { sb += s + "\n" }
        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)

        if !asked.isEmpty {
            line("The image below is the user's own screen, as it looks right now.")
            line("They are looking at it. Someone has asked them about it and they")
            line("want to reply out loud.")
            line()
            line("You are writing their reply, so you are answering as someone who can")
            line("see this screen, because they can. Never write a reply that denies")
            line("being able to see it.")
            line()
            line("SAY WHEN SOMETHING IS BROKEN, EVEN IF NOBODY ASKED.")
            line("If the screen shows a compile error, a failed test case, a stack")
            line("trace, \"Wrong Answer\", \"Time Limit Exceeded\", or a red error")
            line("panel, that is the most useful thing on it and the candidate may")
            line("not have noticed yet. Nobody in an interview says \"can you solve")
            line("that error\": they wait to see whether you spot it.")
            line()
            line("So put it first, in one short line they can say out loud:")
            line("  \"I have got a compile error on line 63, let me fix that first.\"")
            line("  \"Case 3 is failing, looks like the empty input case.\"")
            line("Then answer whatever was actually asked. Name the line number and")
            line("the message if they are readable, and give the corrected code in")
            line("DETAIL. Never invent an error that is not on the screen.")
            line()
            line("NOT EVERY QUESTION IS ABOUT THE SCREEN. While the app is watching a")
            line("shared screen it sends you the screen with every question, including")
            line("the ones that have nothing to do with it. \"Which language do you")
            line("prefer?\", \"tell me about yourself\", \"why are you leaving your")
            line("current role?\" are ordinary interview questions that happen to have")
            line("arrived while a screen was on show.")
            line()
            line("Answer those normally, as the candidate, and ignore the screen")
            line("completely. Do not mention it, do not work it into the answer, do not")
            line("say you can see it. Nobody asked. An answer about a code editor to")
            line("\"which language do you prefer\" is a non-answer, and it tells the")
            line("interviewer something is reading the screen.")
            line()
            line("Use the screen only when the question is about what is on it: solve")
            line("this, what is this error, walk me through this code, can you see my")
            line("screen.")
            line()
            line("DO THE TASK. Confirming you can see the screen is never the answer.")
            line("Interviewers put the two together in one breath: \"you can see my")
            line("screen, right? Can you solve this?\" There is one real question there")
            line("and it is the second one. Answer it.")
            line()
            line("An unclear question is asked about, not answered around. When the")
            line("question arrives half transcribed, such as \"do you know coding or coding")
            line("language? You\", ask for it again in one short line and stop:")
            line("\"Sorry, could you say that again?\" Do not fill the gap with an")
            line("inventory of the screen. Listing the problem number, the language")
            line("selected and which panel it is in reads as stalling, and it tells")
            line("them nothing they cannot see.")
            line()
            line("Confirming sight is at most four words, and only when they asked:")
            line("\"Yes, I can see it.\" Then the actual answer, immediately. Asked to")
            line("solve something, solve it, with the code. Asked how you would")
            line("approach it, give the approach. Never describe the screen back to")
            line("them: they are looking at it, and they know what is on it.")
            line()
            line("THE QUESTION:")
            line(asked)
            line()
            line("Answer in this shape, and nothing else:")
            line()
            line("SAY THIS")
            line("The reply, written in the user's voice, first person, ready to say")
            line("out loud with no editing. Two to four sentences. Not a description")
            line("of the screen and not advice about what to do: the actual reply.")
            line()
            line("DETAIL")
            line("Only when the answer needs code, numbers, or steps to work through.")
            line("Complete code, never abbreviated. Leave this section out entirely")
            line("when the spoken reply is the whole answer.")
            line()
            line("SCREEN NOTES")
            line("One dense line of what is visible: window name, menu and tab labels,")
            line("button labels, headings, figures. Facts only, comma separated. Not")
            line("shown to the user. It is what you will be given if they ask a")
            line("follow-up about this same screen.")
            line()
            line("Rules:")
            line("- Name things. \"Visual Studio\", \"Chrome\", \"the LeetCode Two Sum")
            line("  page\", \"a Postgres query in DBeaver\". Never \"an application\", \"an")
            line("  IDE\", \"a code editor\", \"a document\". A person looking at their own")
            line("  screen says what it is, and hedging is the one thing that makes a")
            line("  reply sound like it came from something that cannot really see.")
            line("  Title bars, tabs, logos and menu names are all in the image; read")
            line("  them. Only if the name is genuinely not visible, describe it by")
            line("  what it does rather than calling it \"an application\".")
            line("- Say when the question is cut off, and ask for the rest.")
            line("  A coding problem often runs past the bottom of the screen. If the")
            line("  statement, the examples or the constraints are clearly incomplete,")
            line("  such as text that ends mid sentence, a section that is missing, or a")
            line("  scrollbar showing more below, do not answer from half of it. Say so in")
            line("  the user's own voice, as a line they can speak out loud while they")
            line("  scroll:")
            line("    \"Let me scroll down and read the constraints before I answer.\"")
            line("    \"Give me a second, I want to see the rest of the examples.\"")
            line("  Then add one line beginning NEED: naming exactly what is missing,")
            line("  such as NEED: the constraints and the third example.")
            line("  Scrolling is captured, so the next answer will have both halves.")
            line("  Answering a half read question confidently is the worst outcome")
            line("  here: it sounds right and it is wrong, and nobody can tell which.")
            line("- Describe only what is visible. If you cannot read the part being")
            line("  asked about, SAY THIS becomes a natural line that buys a moment,")
            line("  such as \"Let me scroll up so I get the exact wording.\" Never guess.")
            line("- Never invent the user's own history, employers, projects, or")
            line("  numbers. Where their own detail belongs, write [your example].")
            line("- Stop on your last point. Never end with a question to the interviewer")
            line("  or an offer to say more, such as \"let me know if you want more")
            line("  detail\" or \"does that make sense\". The only time a question belongs")
            line("  at the end is when the screen itself asks the candidate for one.")
            line("- Plain text and section titles exactly as above. No markdown, with")
            line("  one exception: code goes inside a fence, ```language on its own")
            line("  line before it and ``` on its own line after. The app lifts")
            line("  anything fenced into a monospace panel of its own, so fence every")
            line("  line of code and nothing else. Code left outside a fence is shown")
            line("  in a proportional font with its indentation flattened.")
        } else {
            line("You are sitting beside someone who is in a live interview right now. They")
            line("have just captured their screen and need something they can use within")
            line("seconds.")
            line()
            line("Work in this order:")
            line("1. Read the screen. Find the one thing they need help with: a question, a")
            line("   coding problem, an error, a diagram, or a form. Ignore tabs, toolbars,")
            line("   chat panels, notifications, and anything else around it.")
            line("2. Answer that. Lead with the answer. Do not describe the screenshot back")
            line("   to them.")
            line()
            line("Rules that matter more than the format:")
            line("- Use only what you can actually see. If the part that matters is too")
            line("  small, cut off, or blurred, say which part you cannot read and stop.")
            line("  A confident wrong answer can cost them the job.")
            line("- Say when the problem itself is cut off, and stop rather than guess")
            line("  the rest. A coding problem statement runs past the bottom of the")
            line("  screen more often than it fits: a scrollbar showing more below,")
            line("  text ending mid sentence, a constraints or examples section that")
            line("  looks started but not finished. When that is what you see, do not")
            line("  write a final SOLUTION or FIX from a partial statement: say what")
            line("  is missing,")
            line("  NEED: the constraints and the second example.")
            line("  and nothing else. Guessing at unseen constraints is how a")
            line("  solution that looks right fails on a case nobody could see.")
            line("- Never invent their experience. No employers, projects, metrics, or")
            line("  numbers about them that are not on the screen. Where their own detail")
            line("  belongs, write [your example] and let them fill it in.")
            line("- Answer this screen, not the general topic. If an error code or a")
            line("  message is shown, work out what it means here, in this program,")
            line("  using everything else visible around it. Reciting what the code")
            line("  usually means is not an answer, and it is usually the wrong one.")
            line("- Code must be complete and runnable. Never write \"...\" or \"rest of the")
            line("  code unchanged\".")
            line("- Put every piece of code in a fenced block, opening with three")
            line("  backticks and the language and closing with three backticks.")
            line("  Including a single line.")
            line("- Everything that is not code stays short. They are reading this while")
            line("  another person is talking to them.")
            line("- Stop on your last point. Never end with a question to the interviewer")
            line("  or an offer to say more, such as \"let me know if you want more")
            line("  detail\" or \"does that make sense\".")
            line()
            line("Every answer ends with a SAY THIS line: one or two sentences, first")
            line("person, ready to speak out loud with no editing. It is the one thing")
            line("they can use in the next three seconds while someone is looking at")
            line("them, so it is never optional, whatever is on the screen.")
            line()
            line("Match the shape of your answer to what is on the screen.")
            line()
            line("A coding or algorithm problem:")
            line("APPROACH")
            line("One or two lines. Name the technique.")
            line("SOLUTION")
            line("Complete code, in whatever language is on screen, Python if none is.")
            line("Comment only the lines whose logic is not obvious.")
            line("COMPLEXITY")
            line("Time: O(?)   Space: O(?)")
            line("SAY THIS")
            line("One sentence they can speak while writing it.")
            line()
            line("An error, failing test, or stack trace:")
            line("CAUSE")
            line("One line. The real cause, not the symptom.")
            line("FIX")
            line("The corrected code, ready to paste.")
            line("SAY THIS")
            line("One sentence they can speak.")
            line()
            line("A multiple choice or quiz question:")
            line("ANSWER")
            line("The option, stated flatly.")
            line("WHY")
            line("One line for why it is right. One line for why the closest wrong option")
            line("is wrong.")
            line("SAY THIS")
            line("One sentence they can say out loud, giving the answer and the reason.")
            line()
            line("A system design or architecture diagram:")
            line("SCOPE")
            line("What it has to do, and the scale you are assuming.")
            line("DESIGN")
            line("The components, and how one request travels through them.")
            line("TRADE-OFF")
            line("The one an interviewer will push on.")
            line("SAY THIS")
            line("One sentence to open with.")
            line()
            line("A question about them, such as \"tell me about a time\":")
            line("STRUCTURE")
            line("Situation, action, result, with [your example] everywhere their own")
            line("detail belongs.")
            line("SAY THIS")
            line("An opening sentence that is safe to say exactly as written.")
            line()
            line("Anything else:")
            line("WHAT THIS IS")
            line("One line.")
            line("DO THIS")
            line("The single most useful next step.")
            line("SAY THIS")
            line("One sentence they can say out loud right now.")
            line()
            line("After the answer, and always, add one final section:")
            line()
            line("SCREEN NOTES")
            line("A single dense line listing what is actually visible: the page or")
            line("window name, menu and tab labels, button labels, headings, and any")
            line("figures or identifiers on screen. Facts only, comma separated, no")
            line("commentary. This is not shown to the user. It is what you will be")
            line("given if they ask you something about this screen later, so include")
            line("the things your answer did not need but a follow-up question might.")
            line()
            line("Format: plain text, nothing decorative. A section title is the bare word on")
            line("its own line, in capitals, with its content on the very next line and")
            line("no blank line between them. No lines of dashes, no markdown, no")
            line("asterisks. Code is the one exception and must be fenced: ```language")
            line("on its own line before it, ``` on its own line after, so the app can")
            line("show it in a monospace panel instead of flattening it into prose.")
            line("Bullets, where you need them, use the \u{2022} character.")
            line()
            line("Keep the whole thing as short as it can be and still answer. Three")
            line("clean lines beat three decorated sections.")
        }

        // Name the window the pixels came from. An answer about the WRONG window is otherwise
        // indistinguishable from a bad answer about the right one.
        if !captureSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            line()
            line("WHAT WAS CAPTURED: \(captureSource)")
            line("If this is clearly not what the question is about, say so in one line before answering.")
        }
        // No spoken question (a hotkey): what the interviewer said so far still says what they are asking about.
        if asked.isEmpty, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            line()
            line("WHAT THE INTERVIEWER SAID (audio transcript), to understand what they are asking about the screen:")
            line("\"\(transcript)\"")
        }
        if !jobContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            line()
            line("THE ROLE / COMPANY (tailor any spoken guidance to this):")
            line(jobContext)
        }
        if !resumeCtx.isEmpty && resumeCtx != ResumeParser.noResumeMarker {
            line()
            line("The candidate's background is below. Use it only to choose which of their real experiences")
            line("fits, and only when the screen is asking about them. It is never a licence to invent detail")
            line("that is not in it.")
            line(resumeCtx)
        }
        return sb
    }

    // Post-processor matching .NET ScreenAnalyzer.PostProcess — strips markdown and
    // normalizes spacing around the ━━━ section headers so output is clean & scannable.
    static func postProcessScreen(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        var text = raw
        // Strip markdown (bold/italic/headings/code fences) but keep ━━━ headers & code
        // These two lines were the worst instance of the bug: this is the path EVERY screen
        // answer takes, and the comment above claimed it kept code while stripping every
        // paired asterisk out of it.
        text = PromptBuilder.stripMarkdownPreservingCode(text)
        text = text.replacingOccurrences(of: "(?m)^#{1,6}\\s+", with: "", options: .regularExpression)
        // The fence line is NOT deleted any more. Deleting it removed the only marker saying
        // where code began, and the renderer keys on ━━━ headers alone — so a model that
        // answered with a fence instead of a header had its code rendered as prose:
        // proportional, wrapped, uncopyable. Stripping the marker for a panel that needs the
        // marker is a fix and its own undoing in one line. parseAnswerBlocks reads fences now.
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
