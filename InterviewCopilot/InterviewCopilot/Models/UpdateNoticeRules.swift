import Foundation

// The top bar update notice, kept apart from AppUpdater (which needs Sparkle) so the regression harness can drive it.
// Windows MAC_CATCHUP 2026-11-07, bug round 8: the "on its way" notice stayed up for good when the download then failed.
// Now a check that ends with nothing ready takes it down, the next check that finds the update says it again, and a failed
// download is reported as minor so it never raises the owner's "apps are reporting errors" email.
enum UpdateNoticeRules {
    enum Notice: Equatable { case none, onItsWay(String), ready(String) }

    /// The notice once an update check is over: "on its way" with nothing ready comes down; "ready" stays.
    static func afterCheckEnds(_ notice: Notice) -> Notice {
        if case .onItsWay = notice { return .none }
        return notice
    }

    static let downloadFailedKind = "update-download-failed-minor"
}
