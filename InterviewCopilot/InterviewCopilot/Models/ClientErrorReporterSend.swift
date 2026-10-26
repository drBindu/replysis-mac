import Foundation

// The sending half of ClientErrorReporter. Kept apart from the pure half so the regression harness can compile that one alone.
extension ClientErrorReporter {
    nonisolated(unsafe) private static var seen = Set<String>()
    nonisolated(unsafe) private static var engineTail: [String] = []
    /// "STEALTH: on" or "STEALTH: OFF in Settings", kept current by the view model; first in every report's detail.
    nonisolated(unsafe) static var stealthState = ""
    private static let lock = NSLock()

    /// Every engine output line passes through here; only allowlisted technical lines are kept (the last 40).
    static func noteEngineLine(_ line: String) {
        guard let kept = technicalLine(line) else { return }
        lock.withLock {
            engineTail.append(kept)
            if engineTail.count > engineTailLength { engineTail.removeFirst(engineTail.count - engineTailLength) }
        }
    }

    /// Report one problem. DEBUG builds only log, except against the fake server of a test run, so a scenario can see what would go out.
    static func reportProblem(kind: String, message: String) {
        let first: Bool = lock.withLock { shouldSend(kind: kind, seen: &seen) }
        guard first else { return }
        #if DEBUG
        guard DeveloperOverrides.active else {
            dlog("PROBLEM (debug, not sent): \(kind): \(sanitize(message))", tag: "REPORT")
            return
        }
        #endif
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? ""
        let v = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        let os = "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion) \(arch)"
        let tail = lock.withLock { engineTail }
        let user = UserSession.shared.isLoggedIn ? UserSession.shared.email : ""
        guard let req = request(backendUrl: AppConfig.backendUrl,
                                payload: payload(kind: kind, message: message, version: version, os: os,
                                                 stealth: stealthState, engineTail: tail, user: user)) else { return }
        dlog("PROBLEM sent to admin: \(kind)", tag: "REPORT")
        URLSession.shared.dataTask(with: AppIdentity.label(req)) { _, _, _ in }.resume()
    }
}
