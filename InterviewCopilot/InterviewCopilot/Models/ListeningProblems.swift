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

    enum NextStep { case none, seePlans, moreAnswers }

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
            return Description(label: "NO ANSWERS", title: m.title, body: m.body, step: .moreAnswers)
        case .noAnswers:
            let m = PlanFacts.outOfAnswers(freeTrial: false)
            return Description(label: "NO ANSWERS", title: m.title, body: m.body, step: .moreAnswers)
        case .noListeningTime:
            return Description(
                label: "LISTENING LIMIT",
                title: "Monthly listening limit reached",
                body: "You have reached this month's fair use limit for listening. You still have answers left, but nothing more can be heard until the limit renews or you upgrade. Reading your screen with F8 still works.",
                step: .seePlans)
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
                label: "WEAK CONNECTION",
                title: "Your internet connection is unstable",
                body: "Replysis cannot hold a steady connection to the speech service, so listening is delayed or cut off. This usually means a weak connection, such as a phone hotspot or a busy network. It keeps trying by itself. A stronger wireless network or a cable connection fixes it.",
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
                body: "Practice mode needs a microphone. Plug one in, or allow microphone access in System Settings, under Privacy and Security, then Microphone. Interview mode does not need a microphone.",
                step: .none)
        case .noSpeechService:
            return Description(
                label: "NO SPEECH SERVICE",
                title: "Cannot reach the speech service",
                body: "This is usually a network that blocks it, such as a work or school network or a VPN. Try a phone hotspot.",
                step: .none)
        case .noNetwork:
            return Description(
                label: "NO NETWORK",
                title: "No internet connection",
                body: "Replysis cannot reach the internet, so it cannot hear or answer. It will carry on by itself as soon as the connection is back.",
                step: .none)
        }
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
                       anotherDevice: Bool = false, poorConnection: Bool = false) -> Kind? {
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
        if noNetwork { return .noNetwork }
        // Specific beats generic: repeated connection failures with the network up say more than
        // "reconnecting" does.
        if poorConnection { return .poorConnection }
        if waitingToRetry { return .waitingToReconnect }
        if fatalNoMicrophone { return .noMicrophone }
        if connectionStalled { return .noSpeechService }
        return nil
    }
}
