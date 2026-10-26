import Sparkle

// ══════════════════════════════════════════════════════════════════════════
// AppUpdater — wraps Sparkle so real auto-update actually exists. Before this,
// the GitHub release notes claimed "the app updates automatically" but there
// was no code anywhere that checked for or installed a new version — every
// user was stuck on whatever build they first downloaded until they manually
// found a new release on GitHub. Sparkle checks the feed in the background and lets
// the user trigger a check manually from Settings.
//
// Updates work the way the big apps do them (Chrome, VS Code, Slack, Discord, Zoom; owner, 2026-10-16):
// the check starts with the app, before anyone has signed in, and repeats every hour
// (SUScheduledCheckInterval 3600, Sparkle's shortest; Windows checks every 10 minutes since 2026-10-21); a found update is downloaded in the
// background and installed when the app is next quit (SUAutomaticallyUpdate), with no question
// asked; and nothing is checked while an interview is running (setInterviewActive below).
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
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        // Repairs a Mac where the checks were switched off for good by an older build (see setInterviewActive). Sparkle keeps this setting in
        // the user's defaults, and the old pause wrote false there, so a copy that was quit during an interview never checked again.
        controller.updater.automaticallyChecksForUpdates = true
        return controller
    }()

    /// True while an interview is running. Read by updater(_:mayPerformUpdateCheck:error:) to hold back the BACKGROUND check.
    private var interviewActive = false

    /// Sparkle asks before every check (updater:mayPerformUpdateCheck:error:, which Swift shows as a method that throws). While an interview
    /// runs the background check is refused (by throwing), so a prompt or a download never lands over a live interview; a check the person asks
    /// for in Settings is always allowed.
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard interviewActive && updateCheck == .updatesInBackground else { return }
        dlog("AppUpdater: a background check was due and is held back until the interview ends", tag: "UPDATE")
        throw NSError(domain: "com.bindualekhya.InterviewCopilot.updater", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "An interview is running; the update check waits."])
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        // THE NEW ACCOUNT. This override replaces SUFeedURL on every single check, so it is
        // the address that actually decides where updates come from. UPDATE_FEED_MIGRATION.md
        // moved SUFeedURL to drBindu in 1.0.245 and this line was left on moto123a, which
        // cancelled the move: every build through 1.0.246 kept polling the old feed.
        // Existing users still reach this build through the OLD feed (the bridge release
        // goes into both appcasts); from this build on they poll here.
        "https://raw.githubusercontent.com/drBindu/replysis-mac/main/appcast.xml?cachebust=\(Int(Date().timeIntervalSince1970))"
    }

    func checkForUpdates() {
        dlog("AppUpdater: manual check for updates triggered", tag: "UPDATE")
        controller.checkForUpdates(nil)
    }

    // Every outcome is logged separately. Windows found its check saying "You are up to
    // date" when the check had FAILED; Sparkle's own UI already tells these apart, and
    // the log now does too, so a report can say which one happened.
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        dlog("AppUpdater: check finished — up to date", tag: "UPDATE")
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        dlog("AppUpdater: update available — \(item.displayVersionString) (build \(item.versionString))", tag: "UPDATE")
        // Said the moment it is found, not after the download (Windows 1.0.46): people opened the app, saw nothing, and closed it.
        state = .onItsWay(item.displayVersionString)
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        dlog("AppUpdater: update \(item.displayVersionString) downloaded", tag: "UPDATE")
    }

    /// Downloaded and staged: it installs when the app is quit, or now from the notice's Restart button.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        dlog("AppUpdater: update \(item.displayVersionString) is ready; it installs on quit or from Restart", tag: "UPDATE")
        installNow = immediateInstallHandler
        state = .ready(item.displayVersionString)
        return true   // Sparkle still installs on quit; this keeps the handler for the Restart button
    }

    // ── The top bar notice ─────────────────────────────────────────────────────────────────
    enum State: Equatable { case none, onItsWay(String), ready(String) }
    /// Read by the view model, which shows it only while not listening (never during an interview).
    var state: State = .none { didSet { onStateChange?(state) } }
    var onStateChange: ((State) -> Void)?
    private var installNow: (() -> Void)?

    /// The notice's Restart button: install the staged update and relaunch.
    func restartToUpdate() {
        guard let installNow else { return }
        dlog("AppUpdater: Restart to update pressed", tag: "UPDATE")
        installNow()
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let code = (error as NSError).code
        if (error as NSError).domain == "com.bindualekhya.InterviewCopilot.updater" { return }   // our own hold-back during an interview, already logged
        // SUNoUpdateError (1001) is how Sparkle reports "nothing newer"; it is not a failure.
        if code == 1001 { return }
        dlog("AppUpdater: check FAILED — \(error.localizedDescription) (code \(code))", tag: "UPDATE")
    }

    #if DEBUG
    /// The developer flow's "updatecheck": the check Sparkle's own schedule would make, now (Sparkle will not schedule one sooner than an hour).
    func checkInBackgroundNow() { controller.updater.checkForUpdatesInBackground() }
    #endif

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    // Suppress the DAILY BACKGROUND check while an interview is actively being recorded.
    // An "Update available" alert popping up over the app mid-interview would be a real
    // problem for a tool used live in front of an interviewer. This only pauses the
    // automatic schedule — a user-initiated "Check for Updates…" in Settings always still
    // works immediately, since Sparkle handles those separately regardless of this flag
    // (see SPUUpdater.automaticallyChecksForUpdates). Called from MainViewModel's
    // startNewSession()/endSession() — resumes automatically once the interview ends, so
    // the update is simply found on the next scheduled check rather than lost.
    func setInterviewActive(_ active: Bool) {
        // NOT controller.updater.automaticallyChecksForUpdates = !active, which is what this did. Sparkle stores that setting in the user's
        // defaults (SUEnableAutomaticChecks), so an app quit during an interview, which is how most of them end, left it at false for good:
        // on the owner's Mac, 2026-10-16, automatic update checks were off and the updates never came. The pause is the flag above,
        // gone with the app.
        interviewActive = active
        dlog("AppUpdater: automatic background checks \(active ? "paused (interview active)" : "resumed")", tag: "UPDATE")
        // What was skipped during the interview is looked for now, as turning the setting back on used to do.
        if !active { controller.updater.checkForUpdatesInBackground() }
    }
}
