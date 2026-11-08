import Foundation

// ══════════════════════════════════════════════════════════════════════════
// Every reason the app can be running and still not hear anyone, with the words that tell
// the person what is wrong and what to do. Ported from Windows ListeningProblems.cs.
//
// Until 2026-09-29 most of these were a small coloured label beside the mic and nothing
// else. A tester on the Free plan with 55 credits and no listening time spoke to a silent
// app for minutes and concluded her laptop was broken, because "NO LISTENING TIME" next to
// "55 credits" reads as a contradiction, not an explanation.
//
// Two rules keep that from happening again, and a test enforces both:
//   1. Every problem has a title, a plain-language body and a next step. Adding a case to
//      Kind without describing it fails the build (the switch below must stay exhaustive),
//      and the tests below fail if any description is empty.
//   2. No numbers appear in the words. A plan's limits live on the server and the website;
//      a copy here goes stale the day either changes. The words point at the pricing page.
// ══════════════════════════════════════════════════════════════════════════
enum ListeningProblems {
    enum Kind: CaseIterable {
        case noListeningTime, noAnswers, signInExpired, serviceUnavailable
        case waitingToReconnect, noMicrophone, noSpeechService, noNetwork
        case anotherDevice, poorConnection
    }

    /// upgrade: "Upgrade now" to the plans page, when the free answers or the free trial run out (MAC_HANDOFF_2026-10-27).
    enum NextStep { case none, seePlans, moreAnswers, upgrade }

    struct Description {
        let label: String
        let title: String
        let body: String
        let step: NextStep
    }

    /// - Parameter freeTrial: the one-time free answers (a guest counts). Running out of
    ///   those is the end of a trial, not a limit that renews, so it says what Pro gives.
    static func describe(_ kind: Kind, freeTrial: Bool = false) -> Description {
        switch kind {
        case .noAnswers where freeTrial:
            let m = PlanFacts.outOfAnswers(freeTrial: true)
            return Description(label: "NO ANSWERS", title: m.title, body: m.body, step: .upgrade)
        case .noAnswers:
            let m = PlanFacts.outOfAnswers(freeTrial: false)
            return Description(label: "NO ANSWERS", title: m.title, body: m.body, step: .moreAnswers)
        // The server keeps a hidden ceiling on how much a month can be used, so that an open microphone cannot cost
        // money. Customers are told about ANSWERS and nothing else (owner, 2026-10-05: "we removed that completely"),
        // so these two never say listening, minutes, hours or fair use; a test fails if they ever do. On the free
        // trial it is simply the end of the trial, with the same way forward as running out of answers; on a paid
        // plan it is a monthly limit that renews. Same words as Windows ListeningProblems.NoListeningTime.
        case .noListeningTime where freeTrial:
            return Description(
                label: "TRIAL OVER",
                title: "Your free trial is over",
                body: "That is what Replysis does in a real interview. Pro gives you a whole month, enough for many interviews, and you can cancel any time. Or add a few answers with no subscription.",
                step: .upgrade)
        case .noListeningTime:
            return Description(
                label: "MONTHLY LIMIT",
                title: "You have reached this month's limit",
                body: "This month's allowance is used up, so Replysis cannot hear more until it renews on the first of next month. Your answers are safe, and reading your screen with F8 still works. If you need more, contact support.",
                step: .none)
        case .signInExpired:
            return Description(
                label: "SIGN IN",
                title: "Please sign in again",
                body: "Your sign in has expired, so Replysis cannot connect to the speech service. Open your profile menu at the top right, choose Sign Out, then sign in again.",
                step: .none)
        case .serviceUnavailable:
            return Description(
                label: "SERVICE OFFLINE",
                title: "The speech service is busy",
                body: "Our speech service is temporarily unavailable. Replysis keeps trying on its own and will start listening again as soon as it is back. Nothing needs to be done.",
                step: .none)
        case .anotherDevice:
            // Windows says "Another device is using your account" (ConcurrentSessionLimit).
            // "Usually" is deliberate: the refusal comes from the speech service having no
            // free place for the account, which is nearly always the same person's other
            // device, but the app cannot see that device and must not state it as certain.
            return Description(
                label: "ANOTHER DEVICE",
                title: "Another device is using your account",
                body: "Listening is already in use on this account. That usually means Replysis is open on another device, such as your Windows PC or another Mac. Close it there, or sign out there, and listening starts here by itself.",
                step: .none)
        case .poorConnection:
            // Seen on a phone hotspot losing one packet in five: the speech connection timed out
            // opening, was dropped for silence, and rejected with a timeout, over and over, and
            // the only words on screen were "Connecting". The cause is the connection, so the
            // words say so and say what fixes it.
            return Description(
                // Not the customer's internet: on Windows this showed while the speech provider itself
                // was failing (2026-10-29; owner: never blame the network). Same words as Windows.
                label: "RECONNECTING",
                title: "Listening is reconnecting",
                body: "The speech service dropped a few times and Replysis reconnected each time. Words said during a reconnect can be missed, so the interviewer may need to repeat a question.",
                step: .none)
        case .waitingToReconnect:
            return Description(
                label: "RECONNECTING",
                title: "Reconnecting to speech",
                body: "Replysis is waiting a moment before it reconnects to the speech service. It will start listening again by itself.",
                step: .none)
        case .noMicrophone:
            return Description(
                label: "NO MICROPHONE",
                title: "No microphone found",
                // No mode names (Windows 2026-11-02: Interview and Practice are gone from every hint).
                body: "Replysis listens to your microphone too, and cannot open it. Plug one in, or allow microphone access in System Settings, under Privacy and Security, then Microphone.",
                step: .none)
        case .noSpeechService:
            return Description(
                label: "NO SPEECH SERVICE",
                // Never about the customer's network, VPN or hotspot (Windows 2026-11-02, same words).
                title: "Still connecting to speech",
                body: "Replysis is connecting to the speech service and keeps trying on its own. It starts listening by itself as soon as it connects.",
                step: .none)
        case .noNetwork:
            return Description(
                // The Mac has no network path. Said without blaming the customer's internet (owner's copy rule).
                label: "WAITING",
                title: "Waiting to connect",
                body: "Replysis cannot connect right now, so it cannot hear or answer. It carries on by itself as soon as it connects.",
                step: .none)
        }
    }

    /// The kind sent to admin for a problem shown (Windows ListeningProblems.ReportKind). A customer's own state (out of
    /// answers, this month's limit, no microphone) ends in "-minor", so it shows in admin but never counts towards the
    /// "apps are reporting errors" email. Reported by kind, never by title.
    static func reportKind(_ kind: Kind) -> String {
        let minor: Bool
        switch kind {
        case .noAnswers, .noListeningTime, .noMicrophone: minor = true
        default: minor = false
        }
        return "listening-" + String(describing: kind) + (minor ? "-minor" : "")
    }

    /// How long after the engine's last provider refusal it still counts (Windows: 45 s). The engine keeps trying every
    /// few seconds, so a refusal stops counting soon after the last one.
    static let providerFaultWindow: TimeInterval = 45

    /// The engine's own line saying the speech provider refused it (no credit, forbidden, too many requests) or failed
    /// (5xx). A 401 is not one: that is an expired token, and the app renews it. Windows SpeechHealth.IsProviderFaultLine.
    static func isProviderFaultLine(_ line: String) -> Bool {
        let refused = ">>> [DEEPGRAM] Refused with "
        if let r = line.range(of: refused) {
            return !line[r.upperBound...].hasPrefix("401")
        }
        let http = ">>> [DEEPGRAM] HTTP "
        if let r = line.range(of: http) {
            return line[r.upperBound...].first == "5"
        }
        return false
    }

    /// A line from the speech engine describing the connection failing for the usual reasons of a
    /// weak link: the handshake timing out, the session dropped for want of data that never got
    /// through, a rejection with a timeout. Not an auth failure and not a full account.
    static func isConnectionTrouble(_ line: String) -> Bool {
        let low = line.lowercased()
        return low.contains("timed out during opening handshake") || low.contains("http 408")
            || low.contains("keepalive ping timeout") || low.contains("did not receive audio data")
            || low.contains("no close frame")
    }

    /// The state the app is in, from the facts it already tracks. nil when nothing is wrong.
    static func detect(engineOnline: Bool, speechStatusCode: Int, outOfListeningTime: Bool,
                       outOfAnswers: Bool, waitingToRetry: Bool, fatalNoMicrophone: Bool,
                       connectionStalled: Bool, noNetwork: Bool = false,
                       anotherDevice: Bool = false, poorConnection: Bool = false,
                       providerFault: Bool = false) -> Kind? {
        if engineOnline { return nil }
        // A definite refusal outlives whatever the server said most recently. After a "no
        // listening time" the app kept asking, hit the hourly request limit, and the latest
        // status became "too many requests", which read as a passing reconnect: nothing
        // looked wrong and nothing explained it (Windows, 2026-09-29).
        if outOfListeningTime { return .noListeningTime }
        if outOfAnswers { return .noAnswers }
        if speechStatusCode == 402 { return .noAnswers }
        if speechStatusCode == 401 { return .signInExpired }
        // A refusal for having no free place is as definite as the two above, and the retry
        // that follows it must not turn it into "reconnecting".
        if anotherDevice { return .anotherDevice }
        if speechStatusCode == 502 || speechStatusCode == 503 { return .serviceUnavailable }
        // The speech provider itself refused (402, 403, 429) or failed (5xx), seen in the engine's own lines. That is
        // the service being unavailable, never the customer's network (Windows 2026-11-02, SpeechProviderAtFault).
        if providerFault { return .serviceUnavailable }
        if noNetwork { return .noNetwork }
        // Specific beats generic: repeated connection failures with the network up say more than
        // "reconnecting" does.
        if poorConnection { return .poorConnection }
        if waitingToRetry { return .waitingToReconnect }
        if fatalNoMicrophone { return .noMicrophone }
        if connectionStalled { return .noSpeechService }
        return nil
    }

    /// Whether a speech connection that is not up has been missing long enough to call stalled.
    ///
    /// The wait is counted from when the connection WENT AWAY: the later of the engine process starting and the
    /// last moment it was up. Counted from the process start alone, any drop in a session older than the
    /// patience was "stalled" the instant it happened, and a banner about a work network or a VPN appeared over
    /// a transcript that was working a second later.
    static func connectionStalled(now: Date, startedAt: Date?, lastReadyAt: Date, patience: TimeInterval) -> Bool {
        let since = max(startedAt ?? .distantPast, lastReadyAt)
        guard since > .distantPast else { return false }
        return now.timeIntervalSince(since) > patience
    }
}
