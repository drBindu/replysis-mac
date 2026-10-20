import Foundation

// ══════════════════════════════════════════════════════════════════════════
// The screening answers a recruiter opens with, for India (Windows MAC_CATCHUP item 56, 2026-10-16: "India gets its own screening options,
// chosen automatically; owner: no choosing, detect the country"). In India the first call asks about notice period, other offers and current
// and expected pay, not work authorization or contract type, so those people get their own four lists and nobody there is asked about H1B or
// C2C. India answers are stored apart from the US ones, so switching the country back and forth never mixes them.
//
// Detected, never chosen: the website's own answer (the country the checkout uses for rupee prices) with the time zone and region as the
// first guess before it answers and when it cannot be reached.
// ══════════════════════════════════════════════════════════════════════════
enum ScreeningOptions {
    static let notSpecified = "Not specified"

    static let indiaWorkType = [notSpecified, "Full time / permanent", "Contract (third party payroll)", "Contract to hire",
                                "Freelance", "Internship", "Open to any of these"]
    static let indiaNotice   = [notSpecified, "Immediate joiner", "Serving notice", "15 days", "30 days", "45 days",
                                "60 days", "90 days", "Notice period negotiable"]
    static let indiaOffers   = [notSpecified, "No other offers", "Have an offer in hand", "In final rounds elsewhere", "Prefer not to say"]
    static let indiaLocation = [notSpecified, "Work from office", "Hybrid", "Remote only", "Open to relocation", "Open to any of these"]

    /// The first guess, before the server answers: the Mac's time zone or region.
    static func looksLikeIndia(timeZoneId: String, regionCode: String?) -> Bool {
        timeZoneId == "Asia/Kolkata" || timeZoneId == "Asia/Calcutta" || regionCode == "IN"
    }

    /// The website's /api/geo answer, {"country": "IN"}: true for India, false for any other two letter country, nil when it says nothing usable.
    static func isIndia(geoJSON data: Data) -> Bool? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = object["country"] as? String, code.count == 2 else { return nil }
        return code.uppercased() == "IN"
    }

    /// The lines the prompt gets for an Indian candidate, only for what was set: a blank is left out, never turned into an answer.
    /// Notice period and other offers stand where work authorization and can start stand for everyone else.
    static func indiaContext(workType: String, notice: String, offers: String, location: String, pay: String) -> String {
        var lines: [String] = []
        if workType != notSpecified { lines.append("Work type wanted: \(workType)") }
        if notice != notSpecified   { lines.append("Notice period: \(notice)") }
        if offers != notSpecified   { lines.append("Other offers: \(offers)") }
        if location != notSpecified { lines.append("Work location: \(location)") }
        let trimmed = pay.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { lines.append("Pay expectation: \(trimmed)") }
        return lines.joined(separator: "\n")
    }
}
