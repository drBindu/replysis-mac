import Sparkle

// ══════════════════════════════════════════════════════════════════════════
// AppUpdater — wraps Sparkle so real auto-update actually exists. Before this,
// the GitHub release notes claimed "the app updates automatically" but there
// was no code anywhere that checked for or installed a new version — every
// user was stuck on whatever build they first downloaded until they manually
// found a new release on GitHub. Sparkle checks SUFeedURL (Info.plist) once a
// day in the background, and lets the user trigger a check manually from
// Settings. Updates are verified against SUPublicEDKey before install, so a
// tampered feed/download can't silently replace the app.
// ══════════════════════════════════════════════════════════════════════════

@MainActor
final class AppUpdater {
    static let shared = AppUpdater()

    let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        dlog("AppUpdater: Sparkle updater started", tag: "UPDATE")
    }

    func checkForUpdates() {
        dlog("AppUpdater: manual check for updates triggered", tag: "UPDATE")
        controller.checkForUpdates(nil)
    }

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }
}
