import Foundation

// How long to wait before asking again, in one place so it can be tested. Mirrors Windows
// RecoveryPolicy.cs (2026-09-29), where each of these failed silently on a real laptop.
enum RecoveryPolicy {
    /// After "no connection" (a laptop waking up, Wi-Fi switching): 2, 4, 8, 15, then 30 seconds.
    /// Nothing reached the server, so nothing counts against its limits and there is no reason
    /// to wait half a minute for a network that is back in two.
    static func keyRetryAfterNoConnection(_ consecutiveFailures: Int) -> TimeInterval {
        switch consecutiveFailures {
        case ...1: return 2
        case 2:    return 4
        case 3:    return 8
        case 4:    return 15
        default:   return 30
        }
    }

    /// After the speech service REJECTED the credentials: 5, 15, 30 seconds, then every minute.
    ///
    /// Never permanent. Renewing once and then marking the engine failed for good left a
    /// laptop deaf for the rest of an interview, and the Mac's old wait (one quick try, then
    /// ten minutes) did much the same. The usual cause is not a broken account: it is the
    /// hour-long token running out, and a fresh one fixes it at once.
    ///
    /// Every attempt that gets a token counts against the server's twelve-an-hour allowance,
    /// so `mintsInLastHour` caps the fast retries: past ten, the wait goes back to ten minutes
    /// rather than locking the account out of both apps while trying to recover.
    static func credentialRenewalWait(attempt: Int, mintsInLastHour: Int = 0) -> TimeInterval {
        if mintsInLastHour >= 10 { return 600 }
        switch attempt {
        case ...0: return 5
        case 1:    return 15
        case 2:    return 30
        default:   return 60
        }
    }
}
