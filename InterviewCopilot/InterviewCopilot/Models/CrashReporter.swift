import Foundation
import Sentry

// ══════════════════════════════════════════════════════════════════════════
// CrashReporter — wraps Sentry so crashes and errors in the field are reported
// automatically, instead of only surfacing if a user happens to email their
// debug log. Started as early as possible in launch (see InterviewCopilotApp).
//
// Privacy choices, deliberately stricter than Sentry's copy-paste defaults:
//   • sendDefaultPii = false — do NOT attach user IP addresses or device names.
//     This app handles interviews; we don't need to collect who or where.
//   • Disabled entirely in DEBUG builds — local development crashes are noise,
//     not something to spend the free-tier quota on or clutter the dashboard.
//   • beforeSend strips the email from any event so a report can't carry the
//     user's address even if some frame captured it (matches the masked-email
//     policy already applied to the on-disk debug log).
// ══════════════════════════════════════════════════════════════════════════

enum CrashReporter {
    static func start() {
        #if DEBUG
        // No-op in debug: keep local dev crashes out of the production dashboard/quota.
        #else
        SentrySDK.start { options in
            options.dsn = "https://4e149eec97361cb9aa77eadef94349a8@o4511700595769344.ingest.us.sentry.io/4511700620279808"
            options.debug = false
            // Never attach IP addresses / personally identifying network info.
            options.sendDefaultPii = false
            // Report crashes + unhandled errors. Leave performance tracing off — it adds
            // overhead and quota cost we don't need just for crash visibility.
            options.tracesSampleRate = 0.0
            // Last-chance scrub: drop any email that slipped into an event's message or
            // user fields before it leaves the device.
            options.beforeSend = { event in
                event.user?.email = nil
                return event
            }
        }
        #endif
    }

    /// Reports a significant HANDLED failure (not a crash) as a tracked Sentry event —
    /// e.g. "Google sign-in failed". Without this, a handled error just shows the user a
    /// message and vanishes; nobody finds out unless the user reports it. This surfaces
    /// it the moment it happens instead. Scoped to real failures worth knowing about
    /// immediately, not routine/expected states — don't call this for every dismissed
    /// error message, only ones that indicate something is actually broken.
    static func reportIssue(_ message: String, category: String) {
        #if DEBUG
        dlog("CrashReporter (debug, not sent): [\(category)] \(message)", tag: "SENTRY")
        #else
        SentrySDK.capture(message: message) { scope in
            scope.setTag(value: category, key: "issue_category")
        }
        #endif
    }
}
