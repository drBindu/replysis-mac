import Foundation

// ══════════════════════════════════════════════════════════════════════════
// The phone app's Companion screen, from the laptop side (Windows CompanionLink.cs, 2026-10-25). The answers already reach the phone
// through our server as they stream; this adds what the laptop hears, word by word, whether it is listening, and the phone's Stop and
// Answer buttons.
//
// POST /api/v1/companion/laptop {listening, heard}: the words as they change (at most about 3 a second) while a phone has the
// Companion tab open, else only "listening or not" every 15 s with no words, to find out whether one has opened. The reply carries
// {phones, command}: "stop" finishes the interview once any answer being written is done, "answer" works like Space. The server keeps
// only the latest value in memory; nothing is stored. Only the interviewer's words are sent: the candidate's (the microphone) never are.
// ══════════════════════════════════════════════════════════════════════════
@MainActor
final class CompanionLink {
    static let shared = CompanionLink()

    static let wordsEvery: TimeInterval = 0.35
    static let reportEvery: TimeInterval = 3      // how soon a Stop from the phone lands while listening
    static let probeEvery: TimeInterval = 15

    var onStopRequested: (() -> Void)?
    var onAnswerRequested: (() -> Void)?

    private var heardText = ""
    private var listening = false
    private var changed = false
    private(set) var phones = 0
    private var lastSent = Date.distantPast
    private var sending = false
    private var timer: Timer?

    /// Whether a report is due now. Pure, so the schedule can be checked without a server.
    nonisolated static func reportDue(watching: Bool, changed: Bool, listening: Bool, sinceLast: TimeInterval) -> Bool {
        watching ? (changed && sinceLast >= wordsEvery) || (listening && sinceLast >= reportEvery)
                 : (changed || listening) && sinceLast >= probeEvery
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.15, repeats: true) { _ in MainActor.assumeIsolated { CompanionLink.shared.tick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// The words on screen now (the interviewer's question so far).
    func heard(_ text: String) {
        guard text != heardText else { return }
        heardText = text
        changed = true
    }

    func setListening(_ on: Bool) {
        guard on != listening else { return }
        listening = on
        if !on { heardText = "" }
        changed = true
    }

    private func tick() {
        guard !sending, UserSession.shared.isLoggedIn else { return }
        let watching = phones > 0
        guard Self.reportDue(watching: watching, changed: changed, listening: listening,
                             sinceLast: Date().timeIntervalSince(lastSent)) else { return }
        changed = false
        lastSent = Date()
        sending = true
        let body: [String: Any] = ["listening": listening, "heard": watching ? heardText : ""]
        Task { @MainActor [weak self] in
            defer { self?.sending = false }
            guard let self, let reply = await NetworkClient.shared.reportToCompanion(body) else { return }
            let phones = reply["phones"] as? Int ?? 0
            if phones > 0 && self.phones == 0 { self.changed = true }   // a phone just opened: send it the words at once
            self.phones = phones
            switch reply["command"] as? String ?? "" {
            case "stop":
                dlog("COMPANION: Stop asked from the phone", tag: "COMPANION")
                self.onStopRequested?()
            case "answer":
                dlog("COMPANION: Answer asked from the phone", tag: "COMPANION")
                self.onAnswerRequested?()
            default: break
            }
        }
    }
}
