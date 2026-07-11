import SwiftUI
import AppKit
import Observation
import AVFoundation
import IOKit.hid
import ScreenCaptureKit

@MainActor
@Observable
class MainViewModel {

    // MARK: - Mic State
    var isMuted = true
    var isListening = false
    var isProcessing = false
    var isRecording = false
    var micStatus = "READY"
    var micColor: Color = Color(red: 239/255, green: 68/255, blue: 68/255)

    // MARK: - UI Content
    var aiAnswer = ""
    var transcript = ""
    var aiAnswerHint = "Ready. Press SPACE to start listening, then SPACE again to get your answer."
    var showThinking = false
    var thinkingText = "Thinking..."
    var resumeText = ""
    var resumeLocked = false
    var liveHints = ""               // freeform hints the candidate types to steer answers live
    var savedResumes: [String] = []  // cached list (avoids disk reads on every UI render)
    var isEditingText = false        // true while a text field is focused → Space types, not mic-toggle
    var answerIsBehavioral = false   // true when the current answer used STAR structure
    var answerEpoch = 0              // bumps on each NEW answer → UI scrolls the answer to top

    // MARK: - Job context & answer style
    var companyName = ""
    var jobDescription = ""
    var conciseAnswers = false      // when true, answers are short & spoken-length
    var jobContext: String {
        var parts: [String] = []
        let c = companyName.trimmingCharacters(in: .whitespacesAndNewlines)
        let d = jobDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !c.isEmpty { parts.append("Company: \(c)") }
        if !d.isEmpty { parts.append(d) }
        return parts.joined(separator: "\n")
    }

    // MARK: - Session
    var sessionSeconds = 0
    var sessionTimerVisible = false
    var sessionTimerText = "0:00"

    // MARK: - Credits
    var creditsText = "—"
    var creditsColor: Color = .green
    var creditsPlanText = ""
    var creditsIcon = ""
    var showCreditsBadge = false

    // MARK: - Profile
    var showProfile = false
    var profileName = ""
    var profilePlan = ""
    var avatarInitials = ""

    // MARK: - Window / Overlay
    var showCameraOverlay = false
    var isPinnedOnTop = false       // when true, window floats above other apps
    var mainWindowOpacity: Double = 0.40
    var overlayOpacity: Double = 0.90
    var isScreenAnalyzing = false
    var isWatchMode = false         // continuous screen watch mode
    var useGroq = true

    // MARK: - Permission onboarding
    // The app is NEVER blocked on permissions. Microphone is a one-tap popup (all that's
    // needed to transcribe). The global Space/F8/F9 hotkey is an OPTIONAL upgrade — until
    // it's enabled the user just clicks the mic button. This is what makes the app usable
    // the instant it's downloaded, with no System Settings wall.
    var needsPermissionSetup = false   // true only while the OPTIONAL hotkey setup sheet is up
    var hotkeyActive = false           // is the global hotkey currently working?
    var showHotkeyBanner = false       // subtle "enable Space bar" upsell in the main UI
    private var hotkeyBannerDismissed = false
    var permInputMonitoring = false    // needed (with Accessibility) for the global hotkey
    var permAccessibility   = false
    var permMicrophone      = false
    var micDenied           = false   // true when user explicitly denied mic (not just undetermined)
    var permScreenRecording = false
    private var permTimer: Timer?
    private var permPollingStarted: Date?           // wall-time cap — stops after 5 min total
    private var isMicPermissionRequesting = false  // guard against re-entrant requestAccess calls
    private var hasPromptedAccessibility = false   // BUG-21: fire the AX prompt only once per launch
    private var isRestoringSession = false         // BUG-5: true while async restore is in flight

    // Input Monitoring is what actually authorizes a keyboard CGEventTap on modern macOS.
    static func inputMonitoringGranted() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    // Ask macOS for Input Monitoring. This is what REGISTERS the app in the Input
    // Monitoring list (and shows the system prompt with its own "Open System Settings"
    // button). Called both at launch and again when the user taps the card's button, so
    // the app is guaranteed to be in the list they're looking at.
    func requestInputMonitoring() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    // Fire the Accessibility prompt. This REGISTERS the app in the Accessibility list
    // (and shows the "would like to control this computer" prompt with its own "Open
    // System Settings" button). Without this the app never appears in that list to toggle.
    // BUG-21 FIX: only prompt once per launch — subsequent calls on repeated sheet open/close
    // cycles are no-ops (macOS suppresses the dialog anyway, but we skip the call entirely).
    func requestAccessibilityPrompt() {
        guard !hasPromptedAccessibility else { return }
        hasPromptedAccessibility = true
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    /// Eagerly request Screen Recording from the permissions setup screen, instead of
    /// waiting for the user's first F9/Analyze. CGRequestScreenCaptureAccess() is the
    /// dedicated Core Graphics API for exactly this: it shows the native system dialog if
    /// not yet decided, and returns the current authorization synchronously. Called off the
    /// main thread since it can block while the system dialog is on screen (same pattern as
    /// the other permission calls). Screen Recording — like Accessibility — needs the app to
    /// be relaunched for a NEW grant to actually take effect; startPermissionPolling()'s
    /// existing timer already watches for exactly this transition and relaunches.
    func requestScreenRecordingPermission() {
        // BUG FIX: this used to call CGRequestScreenCaptureAccess() — a DIFFERENT Apple API
        // than the one Analyze actually uses (ScreenCaptureKit's SCShareableContent, in
        // captureScreen() below). Confirmed live: real capture succeeded via
        // SCShareableContent while CGRequestScreenCaptureAccess() kept reporting false — the
        // two APIs don't reliably agree, so the setup screen's card could never show
        // Granted even though Analyze already worked. Fixed by requesting through the EXACT
        // same call captureScreen() uses, so there is no possibility of disagreement: if
        // this succeeds, Analyze is guaranteed to also work, and vice versa.
        Task { @MainActor in
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                self.permScreenRecording = true
                dlog("Screen recording permission request (via ScreenCaptureKit) → granted", tag: "PERM")
            } catch {
                self.permScreenRecording = false
                dlog("Screen recording permission request (via ScreenCaptureKit) → denied/error: \(error.localizedDescription)", tag: "PERM")
            }
        }
    }

    // MARK: - Timers (not tracked by @Observable)
    private var transcriptTimer: Timer?
    private var thinkingTimer: Timer?
    private var sessionTimerObj: Timer?
    private var creditsTimer: Timer?
    private var watchModeTimer: Timer?
    private var thinkingStep = 0

    // MARK: - State
    private var justStartedListening = false
    private var listenStartTicks = 0
    // Suppress the transcript for the first few 150ms ticks after unmute so a stale line
    // from the previous turn doesn't flash before the reset lands. Was 7 (~1s), which made
    // listening feel laggy to start; 3 (~0.45s) is enough to swallow the stale frame while
    // showing fresh words noticeably sooner.
    private let suppressTickCount = 3
    private var lastSpaceTime: Date = .distantPast
    private let spaceDebounceMs: Double = 0.4
    private var sessionNumber = 1
    private var sessionLogPath: URL?
    private var cloudTurns: [NetworkClient.CloudTurn] = []
    private var cloudSessionId: String?
    private var hotkey: GlobalHotkey?
    private var localKeyMonitor: Any?

    let engine = SpeechmaticsEngine.shared
    let session = UserSession.shared

    // MARK: - Init
    init() { loadSettings() }

    private var didAppear = false
    func onAppear() {
        guard !didAppear else { return }
        didAppear = true
        // Surface a clear message if the speech service rejects the key, instead of
        // silently showing an empty transcript forever.
        engine.onKeyError = { [weak self] in self?.handleSpeechKeyError() }
        // Start MUTED so the engine opens the mic idle (start=False) and the macOS orange
        // mic indicator stays OFF until the user actually presses Space to listen. The
        // unmute path deletes this flag; the mute path re-writes it.
        engine.writePauseFlag()
        // Best-effort: pull the Google client secret so "Continue with Google" can work.
        // Harmless if that config backend is down — email/password sign-in is independent.
        Task { await AppConfig.fetchRemoteConfig() }
        // Reliable focused-window hotkeys (Space / F8 / F9) even BEFORE the global
        // Accessibility hotkey is enabled — and more dependable than SwiftUI .onKeyPress.
        setupLocalKeyMonitor()
        loadResume()
        loadJob()
        checkAndRequestPermissions()
        startTranscriptTimer()
        startThinkingTimer()
        startCreditsTimer()
        restoreSession()
    }

    // MARK: - Session Restore
    private func restoreSession() {
        isRestoringSession = true   // BUG-5: suppress premature login prompt during restore
        Task { @MainActor in        // BUG-22: explicit @MainActor keeps all session mutations on actor
            defer { isRestoringSession = false }
            var restored = session.tryLoadFromDisk()
            if !restored && !session.refreshToken.isEmpty {
                restored = await session.tryRefreshAsync()
            }
            // BUG-4 FIX: check showProfile BEFORE awaiting to close the TOCTOU window where
            // the user taps "Continue As" while this Task is in flight and both paths reach
            // startNewSession(). showProfile=true is our mutex for "session already active".
            guard restored && !showProfile else {
                isRestoringSession = false
                // No real saved account — try the free trial (device-ID based, see
                // UserSession.startGuestSession()) instead of immediately locking Space
                // behind a sign-in prompt. Fails harmlessly if offline or this device's
                // free credits are already used up; Space then falls back to the existing
                // "not signed in" prompt exactly as before this feature existed.
                if !showProfile {
                    showProfile = true   // same mutex, same TOCTOU protection as the real-account path
                    let guestOk = await session.startGuestSession()
                    if guestOk {
                        refreshHotkeyGate()
                        profileName = "Guest"
                        profilePlan = "Free trial"
                        avatarInitials = "GU"
                        // BUG FIX: this only set showCreditsBadge = true without ever calling
                        // updateCreditsUI(), so the header badge stayed on its default "—"
                        // placeholder forever — a guest had no visible way to see how many
                        // free credits they actually had left. startGuestSession() already
                        // populated session.credits/plan/isUnlimited; just render them.
                        updateCreditsUI(credits: session.credits, plan: session.plan, isUnlimited: session.isUnlimited)
                        let smOk = await session.fetchSpeechmaticsKeyAsync()
                        startNewSession()
                        if smOk && !engine.isRunning {
                            engine.start(smKey: session.speechmaticsKey)
                        }
                    } else {
                        showProfile = false   // release the mutex — no session was actually started
                    }
                }
                return
            }
            showProfile = true   // claim the mutex before any await below
            // ROOT-CAUSE FIX for "Space does nothing until I click something": isLoggedIn
            // is already true here, but the two awaits below (credits, Speechmatics key)
            // can take real network time. The old code only unlocked the global Space tap
            // deep inside startNewSession(), AFTER both awaits — so for that whole window,
            // the global tap kept treating the user as signed out and let Space pass
            // through untouched (only a focus change elsewhere happened to fix it). Refresh
            // the gate the instant we know isLoggedIn, not after the network round-trips.
            refreshHotkeyGate()
            profileName = session.firstName
            profilePlan = "\(session.plan) plan"
            avatarInitials = session.initials
            showCreditsBadge = true
            await fetchCredits()
            let smOk = await session.fetchSpeechmaticsKeyAsync()
            startNewSession()
            // BUG-20 FIX: only start the engine if it isn't already running (e.g. from a
            // concurrent continueAsSaved() call that completed first).
            if smOk && !engine.isRunning {
                engine.start(smKey: session.speechmaticsKey)
            } else if smOk {
                dlog("restoreSession: engine already running — no restart needed", tag: "AUTH")
            } else {
                micStatus = "NO MIC"
                micColor = Color(white: 0.42)
                aiAnswer = "Ready — speech service temporarily unavailable. Retrying automatically.\n\nClick NO MIC badge to retry, or use F9 to analyze screen."
                engine.startRetryTimer()
            }
        }
    }

    // MARK: - Permission Setup

    private func checkAndRequestPermissions() {
        permInputMonitoring = MainViewModel.inputMonitoringGranted()
        permAccessibility   = AXIsProcessTrusted()
        // CGPreflightScreenCaptureAccess() is a cheap, one-shot status READ (not a capture
        // call), so it's safe here — the old "never call it" note was about repeatedly
        // POLLING actual ScreenCaptureKit content APIs, which shows a persistent "Currently
        // Sharing" system indicator. A single preflight check has no such side effect, and
        // the setup screen now needs the REAL status to show Granted/Pending accurately.
        permScreenRecording = CGPreflightScreenCaptureAccess()
        let micStatus       = AVCaptureDevice.authorizationStatus(for: .audio)
        permMicrophone      = micStatus == .authorized
        micDenied           = micStatus == .denied

        dlog("checkAndRequestPermissions: AXIsProcessTrusted=\(permAccessibility) mic=\(micStatus.rawValue)", tag: "PERM")

        // EARLIEST-POSSIBLE mic warmup: if mic is already authorized (the common case on
        // every launch after the first), start priming the hardware right NOW — before the
        // engine even spawns, before login/credits/key-fetch network calls, before anything.
        // Measured on-device: the OS-level mic hardware wake-up takes ~18-20s NO MATTER WHEN
        // it's triggered — moving the trigger earlier doesn't shorten it, it just gives more
        // wall-clock time for it to finish in the background before the user wants to speak.
        // This is strictly earlier than the engine's own warmup (which waits for sign-in +
        // credits + key fetch first), so it buys several extra seconds of head start for
        // free. Consistent with the user's chosen trade-off: the mic indicator may appear
        // this early too, in exchange for the best possible shot at feeling instant.
        if micCaptureEnabled && micStatus == .authorized {
            MicPrimer.shared.start()
        }

        // ENTERPRISE PERMISSION PATTERN: explain BEFORE asking, never fire a native system
        // popup straight from launch code with no context. If ANYTHING the app uses still
        // needs deciding — mic, Accessibility, or Screen Recording — show our own calm
        // "Set up permissions" screen (PermissionSetupView) instead — its buttons are what
        // actually trigger the real macOS dialogs, one at a time, each with a plain-language
        // reason shown first. All three are asked in this ONE place; once each is decided,
        // returning launches never show this screen again for that permission.
        if micStatus == .notDetermined || !permAccessibility || !permScreenRecording {
            dlog("Permissions incomplete (mic=\(micStatus.rawValue) AX=\(permAccessibility) screenRec=\(permScreenRecording)) — showing the explain-first setup screen", tag: "PERM")
            needsPermissionSetup = true
        }
        startPermissionPolling()   // relaunches the moment AX flips to granted (see the poll loop)

        if permAccessibility {
            setupHotkeys()
            hotkeyActive = true
        } else {
            hotkeyActive = false
        }
    }

    /// User tapped "Enable Space bar" (the optional upgrade). Fire the Accessibility prompt
    /// so the app is REGISTERED in that Settings list (otherwise it isn't there to toggle),
    /// nudge the mic if still undecided, open the setup sheet, and poll so the sheet's
    /// cards flip to green and the Relaunch button enables the instant they're granted.
    func beginHotkeyUpgrade() {
        if !permAccessibility { requestAccessibilityPrompt() }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            requestMicrophonePermission()
        }
        showHotkeyBanner = false
    }

    /// User dismissed the upsell banner — don't nag again this session.
    func dismissHotkeyBanner() {
        hotkeyBannerDismissed = true
        showHotkeyBanner = false
    }

    /// Close the optional hotkey setup sheet without enabling it — app stays fully usable.
    func closeHotkeySetup() {
        permTimer?.invalidate(); permTimer = nil
        permPollingStarted = nil   // reset so next open gets a fresh 5-min window
        needsPermissionSetup = false
    }

    /// Open the permission setup sheet and start polling so cards flip to green
    /// the moment each permission is granted.
    func openPermissionSetup() {
        if !permAccessibility { requestAccessibilityPrompt() }
        showHotkeyBanner = false
    }

    func requestMicrophonePermission() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.permMicrophone = granted
                self.micDenied = !granted   // BUG-12 FIX: was missing — UI showed wrong denied state
                if granted {
                    MicPrimer.shared.start()   // earliest possible warmup — see MicPrimer's doc comment
                    // If the engine already came up in system-only mode before the user
                    // answered this popup, restart it into BOTH mode NOW — so the first Space
                    // press lands on an already-warm mic pipeline instead of triggering a
                    // restart at that moment.
                    if self.engine.isRunning {
                        dlog("Mic granted — restarting engine into BOTH mode ahead of first Space", tag: "PERM")
                        self.engine.stop()
                        self.engine.start(smKey: self.session.speechmaticsKey)
                    }
                }
            }
        }
    }

    private func startPermissionPolling() {
        // Record the FIRST activation time — the 5-min cap is absolute, not per sheet-open.
        // Repeated calls (user opens/closes the sheet) restart the 1s timer but don't
        // reset the clock, so the cap actually fires instead of being bypassed forever.
        if permPollingStarted == nil { permPollingStarted = Date() }
        permTimer?.invalidate()
        permTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.permInputMonitoring = MainViewModel.inputMonitoringGranted()
                let prevAX = self.permAccessibility
                self.permAccessibility   = AXIsProcessTrusted()
                let micStatus            = AVCaptureDevice.authorizationStatus(for: .audio)
                self.permMicrophone      = micStatus == .authorized
                self.micDenied           = micStatus == .denied
                // CGPreflightScreenCaptureAccess() is a cheap status READ, safe to poll —
                // it's actually calling into ScreenCaptureKit content (SCShareableContent
                // etc.) repeatedly that triggers the "Currently Sharing" system indicator,
                // and we don't do that here.
                //
                // BUG FIX: this used to unconditionally overwrite permScreenRecording every
                // second with whatever CGPreflightScreenCaptureAccess() reports. Confirmed
                // live: that API can disagree with the ScreenCaptureKit call the setup
                // screen's button now uses (requestScreenRecordingPermission) — the button
                // would correctly set permScreenRecording=true, then THIS poll tick, firing
                // a second later, would read the stale/disagreeing CG API and flip it right
                // back to false, so the card never visibly showed Granted even though the
                // permission genuinely was. Fixed: only let this poll RAISE the flag
                // (false→true, to catch a grant made directly in System Settings and trigger
                // the relaunch below); never let it lower a flag that a more authoritative
                // check already confirmed true.
                let prevScreenRec = self.permScreenRecording
                if !self.permScreenRecording {
                    self.permScreenRecording = CGPreflightScreenCaptureAccess()
                }

                // ROOT CAUSE of "Space only works after I click inside the app, every
                // time": a CGEventTap created with .defaultTap only actually receives
                // events reliably when Accessibility was ALREADY granted before this
                // process launched (see GlobalHotkey.swift's own long-standing comment on
                // this). Calling setupHotkeys() again in-place, mid-session, right after
                // the user grants Accessibility in System Settings, creates a tap object
                // that LOOKS fine (hotkeyActive=true, no error) but silently never fires —
                // so the user is left thinking the global hotkey works when only the
                // LOCAL monitor (window must be key) actually does, forever, for that
                // whole run. The only reliable fix is a full relaunch: the NEW process
                // starts already trusted, so its tap attaches correctly from birth.
                // Screen Recording has the exact same "needs a fresh process" requirement.
                // Both are checked into ONE combined relaunch call — triggering it twice in
                // the same tick (if both flip true together) would race two new instances
                // against each other, so `newlyGranted` collapses them into a single call.
                let newlyGranted = (!prevAX && self.permAccessibility) || (!prevScreenRec && self.permScreenRecording)
                if newlyGranted {
                    dlog("Accessibility=\(self.permAccessibility) ScreenRecording=\(self.permScreenRecording) newly granted — relaunching so both take effect", tag: "PERM")
                    MainViewModel.relaunchApp()
                }
                // Safety net for the global-Space gate: re-sync it every second for the
                // first 5 minutes after launch, in ADDITION to the explicit refreshes at
                // login/logout. This guarantees Space can never get stuck thinking the user
                // is signed out, no matter which async path updates isLoggedIn first — the
                // exact bug that made Space (and the mic) do nothing until something else
                // (like opening the debug log) happened to trigger a refresh.
                self.refreshHotkeyGate()
                // Stop after 5 min from the first activation, even across multiple reopens.
                if let start = self.permPollingStarted, Date().timeIntervalSince(start) > 300 {
                    let t = self.permTimer
                    self.permTimer = nil
                    self.permPollingStarted = nil
                    t?.invalidate()
                }
            }
        }
    }

    /// Accessibility granted → enable the "Relaunch & Start Session" button.
    /// Accessibility is the ONLY permission that truly requires a relaunch (the CGEventTap
    /// must be registered in a process that was trusted from birth). Mic and Screen Recording
    /// are shown upfront but never block this button — mic is requested at click-time if still
    /// undetermined, and Screen Recording is prompted when F9 is used.
    var hotkeyReadyToActivate: Bool { permAccessibility }

    /// Called when the user taps "Relaunch & Start Session".
    /// If mic is still undetermined, request it first then relaunch.
    /// If mic is denied, relaunch anyway — the Space bar press will prompt again.
    func permissionGrantedContinue() {
        permTimer?.invalidate(); permTimer = nil
        permPollingStarted = nil   // BUG-3/11 FIX: always nil here so if relaunch fails the
                                   // timer cap doesn't expire before the user retries.
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        switch micStatus {
        case .notDetermined:
            // Show the system mic popup now; relaunch after user responds.
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor in MainViewModel.relaunchApp() }
            }
        case .denied:
            // Cannot show the system popup — open the Privacy pane directly.
            // Leave needsPermissionSetup = true so the sheet stays open on return.
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        default: // .authorized
            if AXIsProcessTrusted() {
                MainViewModel.relaunchApp()
            } else {
                needsPermissionSetup = false
            }
        }
    }

    /// Guards against calling relaunchApp() twice concurrently (e.g. Accessibility and
    /// Screen Recording both flipping to granted around the same moment) — a second call
    /// while one is already in flight would race two new instances against each other.
    private static var isRelaunching = false

    /// Relaunch the app cleanly: open a fresh instance, then quit this one. Used after
    /// Accessibility or Screen Recording is granted, since both only take effect in a
    /// process that was already trusted/authorized at launch.
    /// Read by the NEW process's applicationDidFinishLaunching to distinguish an
    /// intentional relaunch (where the OLD instance is expected to still be alive for a
    /// brief moment) from an accidental duplicate launch (e.g. the user double-clicking the
    /// icon again) — the single-instance guard in InterviewCopilotApp.swift checks this so
    /// it doesn't mistake this deliberate handoff for a duplicate and kill the new instance.
    static let relaunchEnvKey = "INTERVIEWCOPILOT_RELAUNCHING"

    static func relaunchApp() {
        guard !isRelaunching else { return }
        isRelaunching = true
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.environment = [relaunchEnvKey: "1"]
        // BUG-10 FIX: check the error before quitting — if the new instance fails to open
        // (corrupt bundle, read-only volume) the old instance must NOT terminate, otherwise
        // the user is left with zero app instances and has to relaunch manually.
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            guard error == nil else {
                dlog("relaunchApp: failed to open new instance — \(error!.localizedDescription)", tag: "APP")
                isRelaunching = false   // allow a future retry — the old instance is still alive
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                dlog("relaunchApp: new instance confirmed open — terminating this (old) instance now", tag: "APP")
                NSApp.terminate(nil)
                // HARDENING: seen live — NSApp.terminate(nil) can be silently swallowed
                // (observed on this .accessory-policy app: the old process kept running
                // indefinitely alongside the new one, producing two visible windows). This
                // isn't a cosmetic bug — a stray old instance can hold stale state, an
                // un-upgraded hotkey tap, or a duplicate mic/engine session. If the graceful
                // path hasn't actually exited within 1.5s, force it unconditionally: the
                // NEW instance is already confirmed up and running, so there is no
                // "zero instances" risk here — only ever the OLD, redundant one.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    dlog("relaunchApp: still alive 1.5s after terminate() — forcing hard exit", tag: "APP")
                    exit(0)
                }
            }
        }
    }

    // MARK: - Hotkeys

    /// Local key monitor: catches Space / F8 / F9 while OUR main window is focused. This
    /// works with NO special permission (unlike the global CGEventTap, which needs
    /// Accessibility) and is more reliable than SwiftUI's .onKeyPress (which silently does
    /// nothing unless a control is focused). It NEVER interferes with sheets (login,
    /// settings, permission setup) or text fields. When the global tap is also active, the
    /// debounce inside handleSpacePress absorbs the duplicate so the mic toggles once.
    private func setupLocalKeyMonitor() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated {
                // Act when the main window OR the eye-mode overlay is key.
                guard event.window is FloatingPanel || event.window is AnswerOverlayWindow else { return event }
                // Let text editors (resume / ask boxes) receive a real space.
                if let fr = event.window?.firstResponder, fr is NSText { return event }
                switch event.keyCode {
                case 49:        self.handleSpacePress(source: "LOCAL"); return nil   // Space
                case 100, 101:  self.runScreenAnalysis();              return nil   // F8 / F9
                default:        return event
                }
            }
        }
    }

    private func setupHotkeys() {
        // Guard: creating a second GlobalHotkey tears down the current tap for ~1 frame,
        // causing observable hotkey dropouts. Only create if not already registered.
        guard hotkey == nil else {
            dlog("setupHotkeys: already have an instance — skipping (this is normal)", tag: "HOTKEY")
            return
        }
        dlog("setupHotkeys: creating new GlobalHotkey instance", tag: "HOTKEY")
        hotkey = GlobalHotkey(
            onSpacePressed: { [weak self] in self?.handleSpacePress(source: "GLOBAL") },
            onF8Pressed:    { [weak self] in self?.runScreenAnalysis() },
            onF9Pressed:    { [weak self] in self?.runScreenAnalysis() },
            onF12Pressed:   { },
            onKillPressed:  { NSApplication.shared.terminate(nil) }
        )
        refreshHotkeyGate()   // seed the tap's consume/pass-through state
    }

    /// Push the current sign-in + text-editing state to the global hotkey tap so it knows
    /// when to CONSUME Space (clean push-to-talk) vs pass it through (typing / signed out).
    /// Called on the main thread whenever either can change. (No need to track the login
    /// sheet separately: while it's up the user isn't signed in yet, so Space already
    /// passes through and types into the email/password fields.)
    func refreshHotkeyGate() {
        let editing = isEditingText || needsPermissionSetup
        hotkey?.updateGate(loggedIn: session.isLoggedIn, editing: editing)
    }

    /// Called by AppDelegate after setActivationPolicy(.accessory) — the policy change can
    /// invalidate CGEventTaps created earlier. Re-create the tap in the final policy state.
    func reinstateHotkeys() {
        dlog("reinstateHotkeys called — AXIsProcessTrusted=\(AXIsProcessTrusted())", tag: "HOTKEY")
        hotkey = nil
        if AXIsProcessTrusted() { setupHotkeys(); hotkeyActive = true }
    }

    // MARK: - Space Logic
    func handleSpacePress(source: String = "KEYBOARD") {
        refreshHotkeyGate()   // keep the tap's editing/login mirror fresh
        if isEditingText { return }

        if !session.isLoggedIn {
            // BUG-5 FIX: if async restore is still in flight, swallow the press — the user
            // has a valid saved session, they just haven't been authenticated yet (~1-2s lag).
            // Without this guard, Space fires .showLogin before the Keychain restore completes
            // and the user sees a login sheet for an account they're already signed into.
            if isRestoringSession {
                dlog("SPACE from \(source): session restore in flight — ignoring to avoid premature login prompt", tag: "SPACE")
                return
            }
            dlog("SPACE from \(source): not signed in → prompting sign-in", tag: "SPACE")
            NotificationCenter.default.post(name: .showLogin, object: nil)
            return
        }

        // Lazy microphone permission — ONLY when the user has opted into it from Settings
        // (Audio Capture: "System audio + my voice"). With the default "System audio only"
        // mode, the mic is never touched and never prompted for, so the app stays fully
        // invisible (no orange indicator, nothing in the mic list if checked).
        if micCaptureEnabled {
            let micAuth = AVCaptureDevice.authorizationStatus(for: .audio)
            if micAuth == .notDetermined {
                // Guard prevents a re-entrant loop: user hammers Space while popup is open →
                // second call would requestAccess again → callback calls handleSpacePress again.
                guard !isMicPermissionRequesting else { return }
                isMicPermissionRequesting = true
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.isMicPermissionRequesting = false
                        self.permMicrophone = granted
                        self.micDenied = !granted
                        if granted && self.engine.isRunning {
                            // Restart so the engine picks up the mic (relaunches in BOTH mode).
                            // The mic is opened idle and only records while listening, so this
                            // doesn't turn on the orange dot until the user is actually speaking.
                            dlog("Mic granted on first Space — restarting engine in BOTH mode", tag: "SPACE")
                            self.engine.stop()
                            self.engine.start(smKey: self.session.speechmaticsKey)
                        }
                        self.handleSpacePress(source: source)
                    }
                }
                return
            }
            if micAuth != .authorized && !engine.systemAudioAvailable {
                // Mic denied AND no system-audio tap (macOS < 14.2) → nothing can capture audio.
                // Open the mic privacy pane directly (native, no custom UI).
                NSWorkspace.shared.open(
                    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                return
            }
            // Mic denied but the system tap works → continue with system audio only.
        }
        // Accessibility is never a gate here: the local key monitor works without it.

        dlog("SPACE pressed from \(source) | loggedIn=\(session.isLoggedIn) | engineRunning=\(engine.isRunning) | isMuted=\(isMuted) | isProcessing=\(isProcessing)", tag: "SPACE")

        guard !isProcessing else {
            dlog("SPACE ignored — AI is processing", tag: "SPACE"); return
        }
        let now = Date()
        guard now.timeIntervalSince(lastSpaceTime) >= spaceDebounceMs else {
            dlog("SPACE debounced", tag: "SPACE"); return
        }
        lastSpaceTime = now

        if session.isLoggedIn && !engine.isRunning && isMuted {
            let key = session.speechmaticsKey
            dlog("SPACE: engine not running, smKey length=\(key.count)", tag: "SPACE")
            if key.isEmpty {
                // BUG-1 FIX: if session restore is still in flight the key just hasn't been
                // fetched yet — don't cry "NO MIC" and lock in a 60s retry; just wait.
                if isRestoringSession {
                    dlog("SPACE: key not yet fetched (restore in flight), ignoring", tag: "SPACE")
                    return
                }
                aiAnswer = "⚠ Speech service temporarily unavailable.\n\nRetrying automatically — or click the NO MIC badge.\n\nUse F9 / Analyze Screen instead."
                micStatus = "NO MIC"
                micColor = Color(white: 0.42)
                engine.startRetryTimer()
                return
            }
            // Key is present but the engine is dead (e.g. it errored earlier and its
            // monitor/retry timers are gone). This used to fall through and unmute into
            // a dead engine — the mic showed LISTENING while nothing transcribed. Start
            // it now; if it's genuinely mid-restart elsewhere, start() safely no-ops.
            dlog("SPACE: restarting dead engine before unmuting", tag: "SPACE")
            engine.start(smKey: key)
        }

        if isMuted {
            dlog("SPACE: unmuting → LISTENING", tag: "SPACE")
            isMuted = false; isListening = true
            justStartedListening = true; listenStartTicks = 0
            transcript = ""; aiAnswer = ""
            // The engine has a slow (~10s) cold start on the first listen after launch.
            // Tell the user it's warming up instead of showing a green mic that silently
            // drops the first words — this was the "Space does nothing at first" bug.
            if !engine.isReady {
                aiAnswerHint = "Warming up… audio will transcribe in a moment (first time after launch only)."
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.engine.clearLatestTxt()
                self?.engine.writeResetFlag()
                self?.engine.deletePauseFlag()
            }
            updateMicUI()
            // Wake the backend now (TLS + cold JVM) so the first answer isn't slow.
            NetworkClient.shared.warmUp()
        } else {
            dlog("SPACE: muting → sending to AI. transcript='\(transcript.prefix(80))'", tag: "SPACE")
            isListening = false
            engine.writePauseFlag()
            isMuted = true
            updateMicUI()
            // BUG-9 FIX: brief drain window — lets the Speechmatics SDK flush any audio
            // buffered before the pause flag landed, so the final transcript snapshot
            // the polling timer captures is complete before we hand it to AI.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 150_000_000)  // 150ms
                guard let self, self.isMuted, !self.isListening else { return }
                self.startAI()
            }
        }
    }

    // MARK: - AI
    /// Manual ask (Parakeet-style): type a question and answer it instantly, bypassing
    /// speech. Also the 100%-accuracy fallback when Speechmatics mishears the question.
    func askManually(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isProcessing else { return }
        if isListening {                       // a typed question takes over from listening
            isListening = false; isMuted = true
            engine.writePauseFlag(); updateMicUI()
        }
        transcript = q                          // show what was asked in the transcript bar
        startAI(manualQuestion: q)
    }

    /// Pin text as persistent steering context (Live Hints) — blended into EVERY answer,
    /// spoken or typed. This is the "live hint" half of the unified Ask / Guide bar.
    func addHint(_ text: String) {
        let h = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty else { return }
        liveHints = liveHints.isEmpty ? h : liveHints + "\n" + h
        saveHints()
    }

    private func startAI(manualQuestion: String? = nil) {
        let q = manualQuestion ?? extractLatestQuestion(from: transcript)
        guard !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Honest feedback instead of silently doing nothing — the #1 "is it broken?"
            // moment is pressing Space twice and seeing zero reaction.
            aiAnswerHint = "No speech was captured. Speak (or play the interviewer's audio), then press Space again."
            updateMicUI(); return
        }
        guard session.isLoggedIn else { aiAnswer = "⚠ Please sign in to use AI answers."; return }
        guard session.isUnlimited || session.credits > 0 else {
            aiAnswer = "⚠ 0 credits remaining. Visit coopilotxai.com to top up."; return
        }

        isProcessing = true; showThinking = true; thinkingStep = 0
        answerEpoch += 1   // new answer → scroll view jumps to top
        updateMicUI()

        let builder = PromptBuilder.shared
        let resumeFacts = ResumeParser.extractFacts(resumeText)
        let (qType, isDrill) = builder.classifyQuestion(q)
        // Light up the STAR badge when this is a behavioral question
        if case .behavioral = qType { answerIsBehavioral = true } else { answerIsBehavioral = false }

        if builder.isGreeting(q)  { finishAI(question: q, answer: builder.getGreetingResponse());  return }
        if builder.isSmallTalk(q) { finishAI(question: q, answer: builder.getSmallTalkResponse()); return }
        // Only treat as off-topic if it WASN'T recognized as a real question type —
        // otherwise short real questions ("where are you located") get wrongly dismissed.
        if case .general = qType, builder.isOffTopic(q) {
            stopThinkingUI(); return   // silence — don't respond, don't log
        }

        let messages = builder.buildMessages(resumeFacts: resumeFacts, currentQuestion: q,
                                             qTypeHint: qType, drillDownHint: isDrill,
                                             jobContext: jobContext, concise: conciseAnswers,
                                             hints: liveHints)
        let provider = useGroq ? "groq" : "openai"
        let lowBanner = (!session.isUnlimited && session.credits > 0 && session.credits < 5)
            ? "⚠ Only \(session.credits) credit(s) remaining.\n\n" : ""

        aiAnswer = "Q: \(q)\n\n\(lowBanner)"
        var accumulated = ""
        var tokenCount = 0
        resumeLocked = true

        let msgArr: [[String: String]] = messages.compactMap { dict in
            guard let role = dict["role"], let content = dict["content"] else { return nil }
            return ["role": role, "content": content]
        }

        // Capture the current generation. If the user clears / starts a new answer
        // mid-stream, answerEpoch changes and these stale callbacks are ignored.
        let epoch = answerEpoch

        NetworkClient.shared.streamAnswer(
            question: q, resume: resumeText, provider: provider, messages: msgArr,
            onToken: { [weak self] token in
                guard let self = self, self.answerEpoch == epoch else { return }
                accumulated += token; tokenCount += 1
                if tokenCount == 1 { self.showThinking = false }
                if tokenCount % 3 == 0 || token.contains("\n") {
                    self.aiAnswer = "Q: \(q)\n\n\(lowBanner)\(accumulated)"
                }
            },
            onDone: { [weak self] in
                guard let self = self, self.answerEpoch == epoch else { return }
                let final = self.cleanAIOutput(accumulated)
                self.finishAI(question: q, answer: final, prefix: "Q: \(q)\n\n\(lowBanner)")
                Task { [weak self] in await self?.fetchCredits() }
            },
            onError: { [weak self] err in
                guard let self = self, self.answerEpoch == epoch else { return }
                if err == "NO_CREDITS" {
                    if self.session.isGuestSession {
                        // A guest has no account to buy more credits on — the only next
                        // step that makes sense is signing in for a real (paid) plan.
                        self.aiAnswer = "⚠ Your 100 free credits are used up.\n\nSign in to buy more and keep going — your account is where credits are purchased."
                        NotificationCenter.default.post(name: .showLogin, object: nil)
                    } else {
                        self.aiAnswer = "⚠ Not enough credits. Visit coopilotxai.com/pricing."
                    }
                }
                else if err == "SESSION_EXPIRED" { self.engine.stop(); self.session.clear(); self.setLoggedOutUI() }
                else                         { self.aiAnswer = "⚠ Something went wrong. Please try again." }
                // DATA-LOSS FIX: previously the error paths saved nothing, so if the AI
                // failed (out of credits, connection issue) the interviewer's question was
                // lost from the session record entirely. Preserve it with a clear
                // placeholder answer so the session still reflects what was asked. Skipped
                // for SESSION_EXPIRED — the session is cleared there, so there's nothing to
                // save into.
                if err != "SESSION_EXPIRED" {
                    let reason = err == "NO_CREDITS" ? "out of credits" : "connection issue"
                    self.appendToSessionLog(q: q, a: "[No answer — \(reason). Question preserved.]")
                }
                self.stopThinkingUI()
            }
        )
    }

    private func finishAI(question: String, answer: String, prefix: String = "") {
        aiAnswer = "\(prefix)\(answer)"
        PromptBuilder.shared.addToHistory(question: question, answer: answer)
        appendToSessionLog(q: question, a: answer)
        stopThinkingUI()
    }

    func stopThinkingUI() {
        showThinking = false; isProcessing = false; isScreenAnalyzing = false
        updateMicUI(); thinkingText = "Thinking..."
    }

    // MARK: - Screen Analysis

    func runScreenAnalysis() {
        guard !isProcessing && !isScreenAnalyzing else { return }
        // Same gate as Space: signed-out → take them to sign-in, not a dead-end message.
        guard session.isLoggedIn else {
            NotificationCenter.default.post(name: .showLogin, object: nil); return
        }

        dlog("Screen analysis triggered", tag: "SCREEN")
        answerIsBehavioral = false   // screen analysis isn't a behavioral question
        answerEpoch += 1             // new answer → scroll to top
        isScreenAnalyzing = true; isProcessing = true; updateMicUI()

        Task { await _doScreenCapture(label: "📸 SCREEN ANALYSIS") }
    }

    // Toggle continuous watch mode — auto-captures every 8 seconds
    func toggleWatchMode() {
        guard session.isLoggedIn else { aiAnswer = "⚠ Please sign in first."; return }
        if isWatchMode {
            isWatchMode = false
            watchModeTimer?.invalidate(); watchModeTimer = nil
            dlog("Watch mode OFF", tag: "SCREEN")
            aiAnswer = "Screen watch mode stopped."
        } else {
            isWatchMode = true
            dlog("Watch mode ON — capturing every 8s", tag: "SCREEN")
            aiAnswer = "👁 WATCH MODE ON — capturing screen every 8 seconds automatically.\n\nThe AI will analyze everything the interviewer shares.\n\nPress Watch button again to stop."
            // Immediate first capture
            runScreenAnalysis()
            watchModeTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self = self, self.isWatchMode && !self.isProcessing else { return }
                    await self._doScreenCapture(label: "👁 AUTO-CAPTURE")
                }
            }
        }
    }

    private func _doScreenCapture(label: String) async {
        // Hide our windows so they don't appear in the screenshot.
        let toHide = NSApplication.shared.windows.filter { $0.isVisible }
        for w in toHide { w.orderOut(nil) }
        try? await Task.sleep(nanoseconds: 80_000_000)   // 80ms — compositor update
        let imageData = await captureScreen()
        for w in toHide { w.orderFrontRegardless() }

        guard let imageData = imageData, !imageData.isEmpty else {
            // macOS already showed its OWN native Screen Recording prompt (from the
            // SCShareableContent call). Do NOT show a second custom alert on top of it —
            // that's the "two popups for one permission" the user hit. Just log and bail;
            // the native prompt is enough to guide the grant.
            dlog("Screen capture returned nil — native permission prompt already shown", tag: "SCREEN")
            stopThinkingUI(); return
        }

        dlog("Screen captured: \(imageData.count) bytes", tag: "SCREEN")
        let base64 = imageData.base64EncodedString()
        let resumeFacts = ResumeParser.extractFacts(resumeText)
        let provider = useGroq ? "groq" : "openai"
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
        let currentTranscript = transcript  // pass what interviewer said too

        aiAnswer = "\(label)  [\(ts)]\n\n"
        showThinking = true
        var accumulated = ""; var tokenCount = 0
        let epoch = answerEpoch   // ignore stale callbacks if the answer is replaced

        NetworkClient.shared.streamScreenAnalysis(
            imageBase64: base64,
            resumeCtx: resumeFacts,
            provider: provider,
            transcript: currentTranscript,
            jobContext: jobContext,
            onToken: { [weak self] token in
                guard let self = self, self.answerEpoch == epoch else { return }
                accumulated += token; tokenCount += 1
                if tokenCount == 1 { self.showThinking = false }
                if tokenCount % 3 == 0 || token.contains("\n") {
                    self.aiAnswer = "\(label)  [\(ts)]\n\n\(accumulated)"
                }
            },
            onDone: { [weak self] in
                guard let self = self, self.answerEpoch == epoch else { return }
                // Screen answers use the ━━━-aware post-processor (keeps headers + code)
                let final = NetworkClient.postProcessScreen(accumulated)
                self.aiAnswer = "\(label)  [\(ts)]\n\n\(final)"
                PromptBuilder.shared.addToHistory(question: "Analyze what is on my screen", answer: final)
                self.appendToSessionLog(q: "[Screen Analysis]", a: final)
                self.stopThinkingUI()
                dlog("Screen analysis complete — \(final.count) chars", tag: "SCREEN")
            },
            onError: { [weak self] err in
                guard let self = self, self.answerEpoch == epoch else { return }
                dlog("Screen analysis error: \(err)", tag: "SCREEN")
                if err == "NO_CREDITS" && self.session.isGuestSession {
                    self.aiAnswer = "⚠ Your 100 free credits are used up.\n\nSign in to buy more and keep going — your account is where credits are purchased."
                    NotificationCenter.default.post(name: .showLogin, object: nil)
                } else if !self.isWatchMode {
                    self.aiAnswer = "⚠ Screen analysis error: \(err)"
                }
                self.stopThinkingUI()
            }
        )
    }

    private func captureScreen() async -> Data? {
        // Use SCScreenshotManager — Apple's one-shot screenshot API (macOS 14.4+).
        // When screen recording permission is not yet granted, macOS automatically shows
        // its own permission prompt. No manual System Settings navigation needed.
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { return nil }

            let config = SCStreamConfiguration()
            config.width  = display.width
            config.height = display.height

            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

            // Scale to max 800px wide, recompress at 60% — keeps payload ~150-300 KB.
            let origW = Double(cgImage.width), origH = Double(cgImage.height)
            let scale = min(1.0, 800.0 / origW)
            let newW  = max(1, Int(origW * scale)), newH = max(1, Int(origH * scale))
            guard let ctx = CGContext(
                data: nil, width: newW, height: newH,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return nil }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: newW, height: newH))
            guard let scaled = ctx.makeImage() else { return nil }
            let rep  = NSBitmapImageRep(cgImage: scaled)
            let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.6])
            dlog("Screen capture: \(data?.count ?? 0) bytes JPEG \(newW)×\(newH)", tag: "SCREEN")
            return data
        } catch {
            dlog("Screen capture failed: \(error)", tag: "SCREEN")
            return nil
        }
    }

    // MARK: - Transcript Polling
    private func startTranscriptTimer() {
        guard transcriptTimer == nil else { return }
        transcriptTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateTranscript() }
        }
    }

    private var transcriptLogTick = 0
    private func updateTranscript() {
        guard session.isLoggedIn, isListening else { return }
        if justStartedListening {
            listenStartTicks += 1; transcript = ""
            if listenStartTicks >= suppressTickCount {
                justStartedListening = false
                dlog("Transcript: suppression done, now reading latest.txt", tag: "TX")
            }
            return
        }
        let text = engine.readLatestTxt()
        transcriptLogTick += 1
        // Log every ~3 seconds (every 20 ticks at 150ms)
        if transcriptLogTick % 20 == 0 {
            dlog("Transcript poll: latest.txt='\(text.prefix(60))' engineRunning=\(engine.isRunning)", tag: "TX")
        }
        if text != transcript {
            dlog("Transcript updated: '\(text.prefix(80))'", tag: "TX")
            transcript = text
        }
    }

    // MARK: - Thinking Animation
    private func startThinkingTimer() {
        guard thinkingTimer == nil else { return }
        thinkingTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.isProcessing && !self.isScreenAnalyzing else { return }
                self.thinkingStep += 1
                let dots = String(repeating: ".", count: self.thinkingStep % 4)
                self.thinkingText = "Thinking\(dots)"
            }
        }
    }

    // MARK: - MIC UI
    func updateMicUI() {
        refreshHotkeyGate()   // login/logout & listening transitions flow through here
        if isProcessing      { micStatus = "THINKING";  micColor = .orange }
        else if isListening  { micStatus = "LISTENING"; micColor = .green }
        else if isMuted      { micStatus = "MUTED";     micColor = Color(red: 239/255, green: 68/255, blue: 68/255) }
        else                 { micStatus = isRecording ? "RECORDING" : "READY"
                               micColor = Color(red: 239/255, green: 68/255, blue: 68/255) }
    }

    // MARK: - Session
    func startNewSession() {
        // BUG FIX: refresh the global-hotkey gate now that we're logged in. Session restore
        // is async, so the gate was seeded as "signed out" at launch and Space wasn't being
        // handled globally until the user first interacted with the app (e.g. opened the
        // debug log) — the "Space does nothing / had to press F12 first" bug.
        refreshHotkeyGate()
        // Don't let a background "Update available" alert pop up over an active interview —
        // see AppUpdater.setInterviewActive for why. Resumed in endSession().
        AppUpdater.shared.setInterviewActive(true)
        resumeLocked = false
        PromptBuilder.shared.clearHistory()
        let dir = engine.appDataFolder
        var num = sessionNumber
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent("interview_\(num).txt").path) { num += 1 }
        sessionNumber = num
        sessionLogPath = dir.appendingPathComponent("interview_\(num).txt")
        cloudTurns = []; cloudSessionId = nil
        isRecording = true
        sessionSeconds = 0; sessionTimerVisible = true
        sessionTimerObj?.invalidate()
        sessionTimerObj = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.sessionSeconds += 1
                let m = self.sessionSeconds / 60, s = self.sessionSeconds % 60
                self.sessionTimerText = "\(m):\(String(format: "%02d", s))"
            }
        }
    }

    func newSession() {
        guard !isProcessing else { return }
        endSession(); transcript = ""; aiAnswer = ""
        answerEpoch += 1   // cancel any in-flight streaming callbacks
        liveHints = ""; saveHints()   // fresh interview → fresh hints
        aiAnswerHint = "New session started. Press SPACE to begin."
        startNewSession()
    }

    private func endSession() {
        isRecording = false; sessionLogPath = nil
        sessionTimerObj?.invalidate(); sessionTimerVisible = false
        PromptBuilder.shared.clearHistory()
        AppUpdater.shared.setInterviewActive(false)
    }

    private func appendToSessionLog(q: String, a: String) {
        syncTurnToCloud(q: q, a: a)
        guard let path = sessionLogPath else { return }
        let entry = "Q: \(q)\nA: \(a)\n\n"
        do {
            if !FileManager.default.fileExists(atPath: path.path) {
                // Lazy creation: write header + first entry atomically so empty
                // sessions never produce files that clutter Past Sessions view.
                let fmt = DateFormatter()
                fmt.dateFormat = "yyyy-MM-dd HH:mm"
                let resumeName = ResumeParser.extractName(resumeText)
                let header = "SESSION \(sessionNumber) | \(useGroq ? "groq" : "openai") | \(fmt.string(from: Date())) | RESUME: \(resumeName)\n\n"
                try (header + entry).write(to: path, atomically: true, encoding: .utf8)
                // Interview transcripts hold the questions asked plus every AI answer built
                // from the resume — lock to owner-only, same as the resume itself.
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
                return
            }
            let handle = try FileHandle(forWritingTo: path)
            try handle.seekToEnd()
            try handle.write(contentsOf: entry.data(using: .utf8) ?? Data())
            try handle.close()
        } catch {
            dlog("Session log write failed: \(error)", tag: "SESSION")
        }
    }

    // Cloud backup mirror of the local .txt log — same Firestore collection the
    // website's real-interview page writes to. Guests skipped: they have no
    // Firebase account for the endpoint to authenticate against. Fire-and-forget:
    // never blocks or affects the local log above.
    private func syncTurnToCloud(q: String, a: String) {
        guard session.isLoggedIn, !session.isGuestSession else { return }
        cloudTurns.append(.init(role: "interviewer", text: q))
        cloudTurns.append(.init(role: "candidate", text: a))
        let turnsSnapshot = cloudTurns
        let email = session.email, company = companyName, roleText = jobDescription
        let resume = resumeText, secs = sessionSeconds, existingId = cloudSessionId
        Task { [weak self] in
            guard let self = self else { return }
            if self.session.tokenNeedsRefresh { _ = await self.session.tryRefreshAsync() }
            NetworkClient.shared.syncSessionToCloud(
                userEmail: email, sessionId: existingId, companyName: company, role: roleText,
                resume: resume, turns: turnsSnapshot, durationSecs: secs
            ) { [weak self] newId in
                guard let self = self else { return }
                if self.cloudSessionId == nil, let newId = newId { self.cloudSessionId = newId }
            }
        }
    }

    // MARK: - Credits
    func fetchCredits() async {
        guard session.isLoggedIn else { return }
        // Only hit Firebase when the token is actually near expiry — avoids a redundant
        // network call on every 5-minute credits poll when the token is still fresh.
        if session.tokenNeedsRefresh { _ = await session.tryRefreshAsync() }
        dlog("Credits fetch starting...", tag: "CREDITS")
        if let result = await NetworkClient.shared.fetchCredits() {
            session.credits = result.credits
            session.plan = result.plan
            session.isUnlimited = result.isUnlimited
            dlog("Credits: \(result.credits), plan=\(result.plan), unlimited=\(result.isUnlimited)", tag: "CREDITS")
            updateCreditsUI(credits: result.credits, plan: result.plan, isUnlimited: result.isUnlimited)
        } else {
            dlog("Credits fetch failed — no result returned", tag: "CREDITS")
        }
    }

    private func updateCreditsUI(credits: Int, plan: String, isUnlimited: Bool) {
        showCreditsBadge = true; creditsPlanText = plan
        if isUnlimited {
            creditsText = "∞  Pro"
            creditsColor = Color(red: 167/255, green: 139/255, blue: 250/255)
            creditsPlanText = "Unlimited"; creditsIcon = "👑"
        } else {
            creditsIcon = ""
            if credits == 0 {
                creditsText = "0 credits"; creditsPlanText = "Tap to top up"
                creditsColor = Color(red: 239/255, green: 68/255, blue: 68/255)
            } else {
                let display = credits >= 1000 ? String(format: "%.1fk", Double(credits)/1000.0) : "\(credits)"
                creditsText = "⚡ \(display)"
                creditsColor = credits > 20
                    ? Color(red: 74/255, green: 222/255, blue: 128/255)
                    : credits > 5
                        ? Color(red: 245/255, green: 158/255, blue: 11/255)
                        : Color(red: 239/255, green: 68/255, blue: 68/255)
            }
        }
    }

    private func startCreditsTimer() {
        guard creditsTimer == nil else { return }
        creditsTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.fetchCredits() }
        }
    }

    // MARK: - Login / Logout
    func onLoginSuccess() {
        // A guest free-trial session claims showProfile too — but it is NOT a real
        // signed-in session, and a successful real login must REPLACE it, not get
        // swallowed by the duplicate-session guard below. Without this, a guest who
        // signs in (e.g. after exhausting the trial) stayed labeled "Guest / Free
        // trial" forever even though their account was genuinely authenticated.
        if session.isGuestSession {
            dlog("onLoginSuccess: replacing guest trial session with real account", tag: "AUTH")
            session.isGuestSession = false
            showProfile = false
        }
        // BUG-4 FIX: guard with showProfile mutex before the Task — closes the TOCTOU
        // window where restoreSession() and continueAsSaved() both reach startNewSession().
        guard !showProfile else {
            dlog("onLoginSuccess: session already active — skipping duplicate start", tag: "AUTH")
            return
        }
        // Sign-out (setLoggedOutUI) stops the transcript/thinking/credits timers, and
        // onAppear — the only other place that starts them — runs once per launch. So a
        // sign-out → sign-in without relaunching left live transcription display dead
        // (the engine wrote latest.txt but nothing polled it), the Thinking animation
        // frozen, and credits never refreshing. Restart them here; each is a no-op when
        // already running.
        startTranscriptTimer(); startThinkingTimer(); startCreditsTimer()
        showProfile = true; profileName = session.firstName
        profilePlan = "\(session.plan) plan"; avatarInitials = session.initials
        showCreditsBadge = true
        // Unlock the global Space tap the instant we know the user is signed in — don't
        // wait for the network calls below (same fix as restoreSession()).
        refreshHotkeyGate()
        // BUG FIX: Google sign-in opens the system browser for the OAuth flow, which takes
        // focus away from us for the whole exchange. Nothing brought focus back afterward —
        // so if the native mic-permission dialog (requested at launch) was still pending, it
        // sat hidden behind the browser the whole time. The user never saw it to click
        // Allow, mic authorization stayed stuck at "not decided," and only reactivating the
        // app some OTHER way (e.g. opening the debug log) coincidentally surfaced it —
        // which looked like "F12 turns on the mic." Reclaim focus now so any pending system
        // dialog is immediately visible again.
        NSApp.activate(ignoringOtherApps: true)
        mainPanel?.makeKeyAndOrderFront(nil)
        Task { @MainActor in
            await fetchCredits()
            let smOk = await session.fetchSpeechmaticsKeyAsync()
            startNewSession()
            if smOk {
                // BUG-20 FIX: don't kill and restart a healthy engine — e.g. restoreSession()
                // already started it; restarting causes a transcription gap + session log reset.
                if !engine.isRunning { engine.start(smKey: session.speechmaticsKey) }
                else { dlog("onLoginSuccess: engine already running — no restart", tag: "AUTH") }
            } else {
                micStatus = "NO MIC"; micColor = Color(white: 0.42)
                engine.startRetryTimer()
            }
        }
    }

    // Direct reference set by AppDelegate after the panel is created.
    // NSApplication.shared.windows is unreliable with .accessory activation policy.
    weak var mainPanel: NSWindow?

    func toggleCamera() {
        if showCameraOverlay {
            exitCamera()
        } else {
            // Camera mode ON: show ONLY the compact overlay, hide the main window
            showCameraOverlay = true
            AnswerOverlayWindow.show(vm: self)
            mainPanel?.orderOut(nil)
        }
    }

    // Camera mode OFF: hide the overlay and bring the main window back as key window.
    func exitCamera() {
        showCameraOverlay = false
        AnswerOverlayWindow.hide()
        mainPanel?.makeKeyAndOrderFront(nil)
    }

    // Pin on top: when ON the window floats above other apps (for the interview);
    // when OFF it's a normal window that goes behind apps you switch to.
    func togglePin() {
        isPinnedOnTop.toggle()
        mainPanel?.level = isPinnedOnTop ? .floating : .normal
        dlog("Pin-on-top \(isPinnedOnTop ? "ON" : "OFF")", tag: "WINDOW")
    }

    func signOut() {
        // Stop eye-mode overlay so its NSPanel and timers don't outlive the session.
        if showCameraOverlay { exitCamera() }
        // BUG-16 FIX: stop watch mode before clearing the session — otherwise the 8s
        // timer keeps firing _doScreenCapture() with an expired idToken after sign-out.
        if isWatchMode {
            isWatchMode = false
            watchModeTimer?.invalidate(); watchModeTimer = nil
        }
        engine.stop(); session.clear(); setLoggedOutUI()
    }

    private func setLoggedOutUI() {
        transcriptTimer?.invalidate(); transcriptTimer = nil
        thinkingTimer?.invalidate();   thinkingTimer = nil
        creditsTimer?.invalidate();    creditsTimer = nil
        showCreditsBadge = false; creditsText = "—"; endSession()
        showProfile = false
        refreshHotkeyGate()   // re-lock Space out globally now that the user is signed out
    }

    // MARK: - Resume
    func loadResume() {
        let path = engine.appDataFolder.appendingPathComponent("resume.txt")
        if let text = try? String(contentsOf: path, encoding: .utf8) { resumeText = text }
        // Live hints are intentionally NOT restored on launch — they're per-interview
        // and start fresh each time (the resume persists; the hints don't).
        liveHints = ""
        try? FileManager.default.removeItem(at: engine.appDataFolder.appendingPathComponent("hints.txt"))
        refreshSavedResumes()
    }

    func saveResume() {
        let path = engine.appDataFolder.appendingPathComponent("resume.txt")
        Self.writeSecurely(resumeText, to: path)
    }

    func saveHints() {
        let path = engine.appDataFolder.appendingPathComponent("hints.txt")
        Self.writeSecurely(liveHints, to: path)
    }

    /// Write text to disk, then lock the file to owner-only (0o600). Used for everything
    /// that contains personal data — the resume, saved resumes, live hints, and interview
    /// transcripts. macOS already puts ~/Library at 0700, but these files default to 0644,
    /// so any process running as another local user (or a lax backup/sync tool) could read
    /// full resume PII and interview answers. 0600 closes that gap — defense in depth for
    /// data at rest, costing nothing.
    static func writeSecurely(_ text: String, to path: URL) {
        do {
            try text.write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        } catch {
            dlog("writeSecurely failed for \(path.lastPathComponent): \(error.localizedDescription)", tag: "FILE")
        }
    }

    // MARK: - Resume library (switch between previously uploaded resumes)

    private var resumesFolder: URL {
        let dir = engine.appDataFolder.appendingPathComponent("resumes")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // Refresh the cached list from disk — call only on real changes (appear/upload/delete),
    // NOT from the view body.
    func refreshSavedResumes() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: resumesFolder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        savedResumes = files
            .filter { $0.pathExtension == "txt" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return da > db
            }
            .map { $0.deletingPathExtension().lastPathComponent }
    }

    func saveResumeToLibrary(name: String) {
        guard !resumeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let safe = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        let finalName = safe.isEmpty ? "Resume \(savedResumes.count + 1)" : safe
        let url = resumesFolder.appendingPathComponent("\(finalName).txt")
        Self.writeSecurely(resumeText, to: url)
        refreshSavedResumes()
    }

    func loadSavedResume(_ name: String) {
        let url = resumesFolder.appendingPathComponent("\(name).txt")
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            resumeText = text
            saveResume()   // make it the active resume
        }
    }

    func deleteSavedResume(_ name: String) {
        let url = resumesFolder.appendingPathComponent("\(name).txt")
        try? FileManager.default.removeItem(at: url)
        refreshSavedResumes()
    }

    // MARK: - Job context
    func loadJob() {
        let path = engine.appDataFolder.appendingPathComponent("job.json")
        if let data = try? Data(contentsOf: path),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            companyName = obj["company"] ?? ""
            jobDescription = obj["description"] ?? ""
        }
    }

    func saveJob() {
        let path = engine.appDataFolder.appendingPathComponent("job.json")
        let obj = ["company": companyName, "description": jobDescription]
        try? JSONSerialization.data(withJSONObject: obj).write(to: path)
    }

    // MARK: - Settings
    func loadSettings() {
        let path = engine.appDataFolder.appendingPathComponent("settings.json")
        if let data = try? Data(contentsOf: path),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            useGroq = obj["useGroq"] as? Bool ?? true
            mainWindowOpacity = obj["mainOpacity"] as? Double ?? 0.40
            overlayOpacity = obj["overlayOpacity"] as? Double ?? 0.90
            conciseAnswers = obj["concise"] as? Bool ?? false
            // Default ON: system audio + the user's own voice, so Space captures both out
            // of the box. Users who want to stay fully invisible in a real interview can
            // switch to system-audio-only in Settings.
            micCaptureEnabled = obj["micCaptureEnabled"] as? Bool ?? true

            // ONE-TIME migration: the default window opacity changed from 100% to 40%.
            // Existing users already have a saved mainOpacity (100%, the old default) from
            // before this change, so without this they'd never see the new default even
            // though their settings.json never reflected an intentional choice. Applies once
            // per install, then the slider fully respects whatever the user sets afterward.
            if obj["opacityDefaultV2Applied"] == nil {
                mainWindowOpacity = 0.40
                opacityDefaultV2Applied = true
                saveSettings()
            }
        }
    }

    private var opacityDefaultV2Applied = false

    func saveSettings() {
        let path = engine.appDataFolder.appendingPathComponent("settings.json")
        let obj: [String: Any] = ["useGroq": useGroq, "mainOpacity": mainWindowOpacity,
                                  "overlayOpacity": overlayOpacity, "concise": conciseAnswers,
                                  "micCaptureEnabled": micCaptureEnabled,
                                  "opacityDefaultV2Applied": true]
        try? JSONSerialization.data(withJSONObject: obj).write(to: path)
    }

    // MARK: - Audio capture mode (Settings toggle)

    /// On (default) = system audio + the user's own voice via the microphone, so Space
    /// captures both the interviewer AND what the user says. macOS shows its orange mic
    /// indicator while actively listening (this cannot be hidden — it's an OS privacy
    /// guarantee no app can bypass), but the mic only records during those moments.
    /// Off = system-audio-only: only the interviewer is transcribed, the mic is NEVER
    /// opened, so there's no orange indicator — fully invisible, for users who want to
    /// stay hidden in a real interview with nothing to reveal if the mic icon is checked.
    var micCaptureEnabled = true

    /// Called from Settings when the user switches audio-capture mode. Applies immediately:
    /// requests the native mic permission if needed, and restarts the engine so the change
    /// takes effect without waiting for the next launch.
    func setMicCaptureEnabled(_ enabled: Bool) {
        guard micCaptureEnabled != enabled else { return }
        micCaptureEnabled = enabled
        saveSettings()
        dlog("Audio capture mode changed → micCaptureEnabled=\(enabled)", tag: "SETTINGS")

        if enabled && AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            requestMicrophonePermission()   // native popup; engine restart below picks it up
        } else if !enabled {
            // BUG FIX: MicPrimer may already be running from earlier in this session (it
            // starts as soon as mic is authorized, before the user ever touches Settings).
            // Without this, switching to "System audio only" correctly changed what the
            // Python engine does, but the already-warmed AVAudioEngine kept running — mic
            // stayed open and the orange indicator stayed on regardless of the new setting.
            MicPrimer.shared.stop()
        }
        guard session.isLoggedIn, engine.isRunning else { return }
        engine.stop()
        engine.start(smKey: session.speechmaticsKey)
    }

    // MARK: - Helpers
    func clearAnswer() {
        resumeLocked = false
        answerEpoch += 1   // invalidate any in-flight stream so it can't re-populate
        transcript = ""; aiAnswer = ""; answerIsBehavioral = false
        aiAnswerHint = "Ready. Press SPACE to start listening, then SPACE again to get your answer."
        PromptBuilder.shared.clearHistory()
        engine.clearLatestTxt()
        stopThinkingUI()
    }

    func retryMic() {
        // Manual retry from the NO MIC badge. Always re-fetch + restart (even if a key
        // exists) — the existing key may be the rejected one we're trying to replace.
        guard session.isLoggedIn else { return }
        micStatus = "…"; micColor = Color(white: 0.42)
        Task {
            let ok = await session.fetchSpeechmaticsKeyAsync()
            if ok {
                engine.start(smKey: session.speechmaticsKey)
                micStatus = "READY"
                micColor = Color(red: 239/255, green: 68/255, blue: 68/255)
            } else {
                micStatus = "NO MIC"; micColor = Color(white: 0.42)
            }
        }
    }

    /// Speechmatics rejected the speech key (server-side config). Be honest about it and
    /// keep the app fully usable via typed questions + screen analysis. The engine keeps
    /// re-fetching in the background, so this clears itself the moment the key is fixed.
    private func handleSpeechKeyError() {
        isListening = false; isMuted = true
        micStatus = "NO MIC"; micColor = Color(white: 0.42)
        aiAnswer = """
        ⚠ Live transcription is paused

        The speech service isn't accepting connections right now (a server-side key issue). \
        Everything else still works:

        • Type your question in the Ask bar below to get an instant answer
        • Press F9 to analyze whatever is on your screen

        Transcription resumes automatically as soon as the service is restored — no action needed.
        """
    }

    private func extractLatestQuestion(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.lowercased().hasPrefix("[screen") { return trimmed }
        let sentences = trimmed.components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.count > 4 }
        if sentences.isEmpty { return trimmed }
        let latest = sentences.suffix(min(3, sentences.count)).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return latest.count < 10 ? trimmed : latest
    }

    private func cleanAIOutput(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "```[a-zA-Z]*\\n?", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "```", with: "")
        s = s.replacingOccurrences(of: "\\*{1,3}([^*\\n]+)\\*{1,3}", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: " — ", with: ", ").replacingOccurrences(of: " – ", with: ", ")
             .replacingOccurrences(of: "—", with: ", ").replacingOccurrences(of: "–", with: ", ")
        for f in ["Certainly! ","Absolutely! ","Of course! ","Great question! ","Sure! ",
                  "I'd be happy to ","I'm happy to ","Good question! "] {
            s = s.replacingOccurrences(of: f, with: "")
        }
        while s.contains("\n\n\n") { s = s.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Color hex helper
extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: h).scanHexInt64(&int)
        self.init(
            red:   Double((int >> 16) & 0xFF) / 255,
            green: Double((int >> 8)  & 0xFF) / 255,
            blue:  Double( int        & 0xFF) / 255
        )
    }
}
