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
    /// REPLYSIS_FLOW_SCRIPT="start:6,back:4,start:6,finish:4": presses the app's own controls on a
    /// timer, so the window and view transitions can be exercised without accessibility tools.
    /// Debug builds only. Unlike the two above it involves no network, so it needs no loopback.
    static let flowScript: String? = ProcessInfo.processInfo.environment["REPLYSIS_FLOW_SCRIPT"]
    /// REPLYSIS_TEST_SESSION=stale  -> a fake signed-in user whose token is "stale-token".
    static let testSession: String? =
        backendURL == nil ? nil : ProcessInfo.processInfo.environment["REPLYSIS_TEST_SESSION"]
    /// REPLYSIS_TEST_USER=alice  -> the fake signed-in person has this id, so account switching can be tested.
    static let testUser: String? =
        backendURL == nil ? nil : ProcessInfo.processInfo.environment["REPLYSIS_TEST_USER"]
    /// REPLYSIS_DATA_DIR=/tmp/x  -> the app's data folder, so a test never touches the real one.
    /// Only while a fake server is in use.
    static let dataFolder: String? =
        backendURL == nil ? nil : ProcessInfo.processInfo.environment["REPLYSIS_DATA_DIR"]
    /// REPLYSIS_SCREEN_IMAGE=/tmp/screen.png  -> every screen read uses this picture instead of the real screen,
    /// so the screen path can be tested end to end with no permission prompt and no window. Only while a fake
    /// server is in use. REPLYSIS_SCREEN_TARGET names the window it stands for.
    static let screenImagePath: String? =
        backendURL == nil ? nil : ProcessInfo.processInfo.environment["REPLYSIS_SCREEN_IMAGE"]
    /// REPLYSIS_HEADLESS=1  -> the window never shows (invisible, far off screen). Only against a fake server.
    static let headless: Bool =
        backendURL != nil && ProcessInfo.processInfo.environment["REPLYSIS_HEADLESS"] == "1"
    static let screenTarget: String =
        ProcessInfo.processInfo.environment["REPLYSIS_SCREEN_TARGET"] ?? "Google Chrome: Two Sum - LeetCode"
    #else
    static let screenImagePath: String? = nil
    static let headless = false
    static let screenTarget = ""
    static let flowScript: String? = nil
    static let backendURL: String? = nil
    static let tokenURL: String? = nil
    static let testSession: String? = nil
    static let testUser: String? = nil
    static let dataFolder: String? = nil
    #endif

    /// True while a test is running against a fake server. The Keychain stays untouched.
    static var active: Bool { backendURL != nil }
}
