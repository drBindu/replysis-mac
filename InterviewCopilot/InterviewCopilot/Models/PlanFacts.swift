import Foundation

// ══════════════════════════════════════════════════════════════════════════
// The plan sizes as this app states them. Decided with the owner on 2026-09-29.
//
//   Free   25 credits     5 answers, ONCE (never refilled)
//   Pro    2,500 credits  500 answers a month
//   Max    7,500 credits  1,500 answers a month
//   An answer or a screen read costs 5 credits.
//
// Ported from Windows PlanFacts.cs so the two apps say the same thing. These must equal
// PLAN_MONTHLY_CREDITS in the website's data/productFacts.ts and the server's
// FirestoreCreditsService; the server is what enforces them, this only decides what the
// app SAYS. The website's scripts/check-sync.mjs compares all of them, so changing one
// alone fails a release check instead of reaching a customer.
//
// CUSTOMERS NEVER SEE THE WORD "CREDITS". They see answers. Credits exist only inside
// this file and the server.
// ══════════════════════════════════════════════════════════════════════════
enum PlanFacts {
    /// What one answer or screen read costs. Must equal INTERVIEW_QUESTION_COST on the server.
    static let answerCost = 5
    static let freeCredits = 25
    static let proCredits = 2_500
    static let maxCredits = 7_500
    /// Retired plan, kept so an old account still reads correctly.
    static let teamsCredits = 10_000
    /// One real interview is about 30 answers with Auto on.
    static let answersPerInterview = 30
    /// Amber warning at two answers left or fewer.
    static let lowCreditsThreshold = 10

    /// Where someone who has run out adds answers without a subscription.
    static let addAnswersURL = URL(string: "https://replysis.com/account#add-answers")!
    static let pricingURL = URL(string: "https://replysis.com/pricing")!

    static func monthlyCredits(_ plan: String?) -> Int {
        switch (plan ?? "").trimmingCharacters(in: .whitespaces).lowercased() {
        case "pro":             return proCredits
        case "max", "lifetime": return maxCredits
        case "teams":           return teamsCredits
        default:                return freeCredits
        }
    }

    /// On the one-time free answers rather than a paid plan. A guest counts.
    static func isFreeTrial(plan: String?, signedIn: Bool) -> Bool {
        !signedIn || monthlyCredits(plan) == freeCredits
    }

    /// What a balance can actually buy: rounded DOWN, never overstated (12 credits is 2 answers).
    static func answers(_ credits: Int) -> Int { max(0, credits) / answerCost }

    /// "12", or "1.5k" on the badge.
    static func answersShort(_ credits: Int) -> String {
        let a = answers(credits)
        if a >= 1000 { return String(format: "%.1fk", Double(a) / 1000.0) }
        return NumberFormatter.localizedString(from: NSNumber(value: a), number: .decimal)
    }

    /// "1 answer" or "12 answers".
    static func answersLabel(_ credits: Int) -> String {
        let a = answers(credits)
        let n = NumberFormatter.localizedString(from: NSNumber(value: a), number: .decimal)
        return "\(n) \(a == 1 ? "answer" : "answers")"
    }

    /// The badge at the top of the app: "12 answers", "1.5k answers".
    static func badgeText(_ credits: Int) -> String {
        "\(answersShort(credits)) \(answers(credits) == 1 ? "answer" : "answers")"
    }

    /// The allowance line: "5 answers, one time" or "500 answers each month".
    static func allowanceText(plan: String?, signedIn: Bool) -> String {
        if isFreeTrial(plan: plan, signedIn: signedIn) { return "\(answers(freeCredits)) answers, one time" }
        let n = NumberFormatter.localizedString(from: NSNumber(value: answers(monthlyCredits(plan))), number: .decimal)
        return "\(n) answers each month"
    }

    /// When the allowance comes back. Free answers never do, and must not be promised.
    static func refreshText(plan: String?, signedIn: Bool) -> String {
        isFreeTrial(plan: plan, signedIn: signedIn) ? "Not refreshed" : "Renews each month"
    }

    /// The hover text on the badge. Never "this month" for the free answers: they do not refill.
    static func tooltip(credits: Int, freeTrial: Bool, listeningLimitReached: Bool = false) -> String {
        let count = answers(credits)
        let n = NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
        // "About 1 free answers left" read wrong, and "About 0" is not an estimate, it is a fact.
        let line: String
        if count == 0 {
            line = freeTrial
                ? "No free answers left. Free answers do not refresh."
                : "No answers left this month."
        } else if count == 1 {
            line = freeTrial
                ? "About 1 free answer left. Free answers do not refresh."
                : "About 1 answer left this month."
        } else {
            line = freeTrial
                ? "About \(n) free answers left. Free answers do not refresh."
                : "About \(n) answers left this month."
        }
        let cost = "Each answer or screen read uses one answer."
        return listeningLimitReached
            ? "\(line)\n\(cost)\nYou have reached this month's fair use limit for listening, so nothing more can be heard until it renews. Click for plans."
            : "\(line)\n\(cost)\nClick for plans."
    }

    /// Two answers left or fewer: time to say so, in amber.
    static func isLow(_ credits: Int) -> Bool { credits <= lowCreditsThreshold }

    /// Less than one answer: nothing can be asked until more are added.
    static func isEmpty(_ credits: Int) -> Bool { credits < answerCost }

    /// What someone reads when an answer is refused for having none left. A free trial is
    /// the end of a trial, not a limit that renews, so it says what Pro gives. No numbers:
    /// those belong to the server and the website.
    static func outOfAnswers(freeTrial: Bool) -> (title: String, body: String) {
        freeTrial
            ? ("Your free answers are used",
               "That is what Replysis does in a real interview. Pro gives you a whole month of answers, enough for many interviews, and you can cancel any time. Or add a few answers with no subscription.")
            : ("No answers left this month",
               "Every answer and screen read uses one of your answers. You have used them all, so Replysis cannot answer until they renew, you add more, or you upgrade.")
    }

    /// The low warning shown above an answer when two or fewer are left.
    static func lowWarning(credits: Int, freeTrial: Bool) -> String {
        let label = answersLabel(credits)
        return freeTrial
            ? "Only \(label) left. Free answers do not refresh."
            : "Only \(label) left this month."
    }
}
