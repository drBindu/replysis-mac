import Sparkle

// ══════════════════════════════════════════════════════════════════════════
// AppUpdater — wraps Sparkle so real auto-update actually exists. Before this,
// the GitHub release notes claimed "the app updates automatically" but there
// was no code anywhere that checked for or installed a new version — every
// user was stuck on whatever build they first downloaded until they manually
// found a new release on GitHub. Sparkle checks the feed once a day in the
// background, and lets the user trigger a check manually from Settings.
// Updates are verified against SUPublicEDKey before install, so a tampered
// feed/download can't silently replace the app.
//
// feedURLString(for:) overrides the static SUFeedURL from Info.plist with a
// cache-busted one on every single check. raw.githubusercontent.com caches
// responses for 5 minutes (Cache-Control: max-age=300) — confirmed live: right
// after publishing v1.0.208, a manual check still reported "up to date" at
// v1.0.207 because the edge server it happened to hit hadn't refreshed yet.
// Appending a unique query string per request forces a cache miss every
// time, since the CDN's cache key includes the full URL including query.
// ══════════════════════════════════════════════════════════════════════════

@MainActor
final class AppUpdater: NSObject, SPUUpdaterDelegate {
    static let shared = AppUpdater()

    private override init() {
        super.init()
    }

    lazy var controller: SPUStandardUpdaterController = {
        SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    }()

    func feedURLString(for updater: SPUUpdater) -> String? {
        "https://raw.githubusercontent.com/moto123a/interview-copilot-mac/main/appcast.xml?cachebust=\(Int(Date().timeIntervalSince1970))"
    }

    func checkForUpdates() {
        dlog("AppUpdater: manual check for updates triggered", tag: "UPDATE")
        controller.checkForUpdates(nil)
    }

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }
}
