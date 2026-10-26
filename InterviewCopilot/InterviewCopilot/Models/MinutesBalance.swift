import Foundation

// ══════════════════════════════════════════════════════════════════════════
// India pays by the minute (Windows MAC_CATCHUP item 57, 2026-10-16): Rs 5 a minute, bought on the website (15 to 600), with auto add of
// 15 minutes. The server keeps a minutesBalance on the user; reported listening is taken from it first, and while it is above 0 an answer
// costs no credits. /api/v1/interview/credits and /api/v1/usage/listening return it.
//
// The app shows "N min left" in place of the answers while minutes remain, and when 2 or fewer are left asks the website to auto add 15
// (POST /api/minutes {"action":"add"}), at most once every three minutes. Most Indian banks want the person to approve such a charge, so
// when the website says so (needsApproval and a checkout.stripe.com address) a notice offers "Add 15 minutes" and NOTHING opens by itself
// during an interview.
// ══════════════════════════════════════════════════════════════════════════
enum MinutesBalance {
    /// At or below this many minutes the app asks for more.
    static let autoAddWhenLeft = 2
    /// The most often the website is asked.
    static let askEvery: TimeInterval = 3 * 60

    /// What the badge says: the minutes while there are any, otherwise whatever it said before.
    /// A paid plan with answers left shows its answers: those are what it pays for (Windows bug sweep, 2026-10-22).
    static func badgeText(minutes: Int, fallback: String, paidWithAnswers: Bool = false) -> String {
        minutes > 0 && !paidWithAnswers ? "\(minutes) min left" : fallback
    }

    /// A balance that is dropping to nothing, for someone who has (or just had) bought minutes. A person who never bought any is not asked,
    /// and neither is a paid plan with answers left: it would be charged for minutes it does not need.
    static func shouldAskForMore(hadMinutes: Bool, balance: Int, paidWithAnswers: Bool = false) -> Bool {
        !paidWithAnswers && (hadMinutes || balance > 0) && balance <= autoAddWhenLeft
    }

    static func mayAsk(now: Date, lastAskedAt: Date?) -> Bool {
        guard let last = lastAskedAt else { return true }
        return now.timeIntervalSince(last) >= askEvery
    }

    enum Outcome: Equatable {
        case added(Int)                    // charged the saved card: this many minutes were added
        case needsApproval(URL)            // the bank wants the person to approve: a checkout address to offer
        case notUsed(String)               // auto add is off, or refused; the reason, for the log
    }

    /// The website's answer to {"action":"add"}.
    static func outcome(fromAddResponse data: Data) -> Outcome {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .notUsed("unreadable answer") }
        if let added = object["added"] as? Int, added > 0 { return .added(added) }
        if object["needsApproval"] as? Bool == true, let address = object["url"] as? String,
           address.hasPrefix("https://checkout.stripe.com/"), let url = URL(string: address) {
            return .needsApproval(url)
        }
        let reason = object["reason"] as? String ?? ""
        return .notUsed(reason.isEmpty ? "no reason given" : reason)
    }

    /// minutesBalance out of a credits or listening answer, never below zero. nil when the answer has none.
    static func balance(from object: [String: Any]) -> Int? {
        guard let value = object["minutesBalance"] as? Int else { return nil }
        return max(0, value)
    }
}
