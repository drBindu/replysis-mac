import Foundation

// ══════════════════════════════════════════════════════════════════════════
// Lets a DEBUG build be pointed at a fake server on this Mac, so the real app can be run
// against each account situation (out of answers, fair use limit, signed out, service down,
// rate limited, stale token...) and checked for what the person is actually TOLD. Windows
// has the same in its developer builds (REPLYSIS_BACKEND_URL, tests/scenarios).
//
// Two hard limits, because this is a way to point the app somewhere else:
//   1. It does not exist in a Release build: everything below is #if DEBUG, and the Release
//      version of each property is a constant that turns the override off.
//   2. Only loopback addresses are accepted, so it can never send a real token anywhere but
//      this machine.
//
// While it is on, the Keychain is INERT: nothing is read from it and nothing is written to it,
// so a test run can never touch, replace or delete the real signed-in session.
// ══════════════════════════════════════════════════════════════════════════
enum DeveloperOverrides {
    #if DEBUG
    private static func loopback(_ key: String) -> String? {
        guard let raw = ProcessInfo.processInfo.environment[key],
              let url = URL(string: raw), let host = url.host?.lowercased(),
              ["127.0.0.1", "localhost", "::1"].contains(host) else { return nil }
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }
    /// REPLYSIS_BACKEND_URL=http://127.0.0.1:18081
    static let backendURL: String? = loopback("REPLYSIS_BACKEND_URL")
    /// REPLYSIS_TOKEN_URL=http://127.0.0.1:18081/token  (where a sign-in refresh goes)
    static let tokenURL: String? = loopback("REPLYSIS_TOKEN_URL")
    /// REPLYSIS_TEST_SESSION=stale  -> a fake signed-in user whose token is "stale-token".
    static let testSession: String? =
        backendURL == nil ? nil : ProcessInfo.processInfo.environment["REPLYSIS_TEST_SESSION"]
    #else
    static let backendURL: String? = nil
    static let tokenURL: String? = nil
    static let testSession: String? = nil
    #endif

    /// True while a test is running against a fake server. The Keychain stays untouched.
    static var active: Bool { backendURL != nil }
}
