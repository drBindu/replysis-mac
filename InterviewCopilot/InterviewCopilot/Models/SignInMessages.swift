import Foundation

// ══════════════════════════════════════════════════════════════════════════
// What the sign-in page says when signing in or creating an account does not work, and how it is reported to admin.
// Windows MAC_CATCHUP 2026-11-02 and 2026-11-07 (bug round 1, sign in):
//   - The words never say connection, internet or network: a failure is "Could not sign in just now", a timeout is
//     "That took too long", a reply that cannot be read is "That did not go through".
//   - Firebase puts detail after the code ("WEAK_PASSWORD : Password should be at least 6 characters"); the code is read
//     from the start, so it still maps, and an unknown code never shows raw.
//   - A typing mistake (wrong password, unknown email, bad email, short password, email already used) is reported marked
//     minor, so it never raises the owner's "apps are reporting errors" alert. A disabled account, a lockout and real
//     failures still count. An empty field is not reported at all.
// Pure, so the regression harness drives it.
// ══════════════════════════════════════════════════════════════════════════
enum SignInMessages {
    static let failed = "Could not sign in just now. Please try again."
    static let tooLong = "That took too long. Please try again."
    static let didNotGoThrough = "That did not go through. Please try again."
    static let createFailed = "Could not create account. Please try again."

    static let wrongCredentials = "Incorrect email or password."
    static let badEmail = "Please enter a valid email address."
    static let shortPassword = "Password must be at least 6 characters."
    static let emailUsed = "An account with this email already exists. Try signing in instead."
    static let emptyFields = "Please enter your email and password."
    static let emptyName = "Please enter your name."
    static let emptyResetEmail = "Enter your email above, then tap Forgot password."
    static let sessionExpired = "Your session expired. Please sign in again."
    static let googleCancelled = "Google sign-in was cancelled."
    static let googleBusy = "Sign-in already in progress."

    /// The code at the start of Firebase's message, without the detail after it.
    static func code(_ raw: String) -> String {
        let head = raw.components(separatedBy: ":").first ?? raw
        return head.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The words for a Firebase refusal. Never the raw code.
    static func message(firebaseCode raw: String, creating: Bool) -> String {
        switch code(raw) {
        case "EMAIL_NOT_FOUND", "INVALID_PASSWORD", "INVALID_LOGIN_CREDENTIALS": return wrongCredentials
        case "INVALID_EMAIL": return badEmail
        case "WEAK_PASSWORD": return shortPassword
        case "EMAIL_EXISTS": return emailUsed
        case "USER_DISABLED": return "This account has been disabled. Contact support."
        case "TOO_MANY_ATTEMPTS_TRY_LATER": return "Too many attempts. Please try again later."
        case "OPERATION_NOT_ALLOWED": return "Account creation is temporarily unavailable. Please try again later."
        case "MISSING_PASSWORD", "MISSING_EMAIL": return emptyFields
        default: return creating ? createFailed : failed
        }
    }

    /// The words for a request that never got an answer.
    static func message(for error: Error) -> String {
        if let u = error as? URLError, u.code == .timedOut { return tooLong }
        return failed
    }

    /// What the person typed, not the app failing: reported, but minor.
    static let typingMistakes: Set<String> = [wrongCredentials, badEmail, shortPassword, emailUsed]
    /// The person's own state, not the app failing: reported, but minor.
    static let minorStates: Set<String> = [sessionExpired]
    /// Nothing was sent, or the person stopped it: not reported at all.
    static let notReported: Set<String> = [emptyFields, emptyName, emptyResetEmail, googleCancelled, googleBusy]

    /// The problem kind sent to admin for a message shown, or nil when it is not reported.
    static func reportKind(_ message: String) -> String? {
        guard !message.isEmpty, !notReported.contains(message) else { return nil }
        return "signin-" + ClientErrorReporter.slug(message) + (typingMistakes.contains(message) || minorStates.contains(message) ? "-minor" : "")
    }
}
