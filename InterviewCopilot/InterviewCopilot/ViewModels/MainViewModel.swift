import SwiftUI
import Network
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
    /// The question the latest answer is FOR. The interviewer box shows this when nothing new has
    /// been said, so the question does not vanish the moment its answer finishes: the turn logic
    /// clears `transcript` after every answer to get ready for the next question (correctly),
    /// and the box used to follow it, leaving the answer with no question beside it. Replaced the
    /// moment the interviewer speaks again, and cleared with the session.
    private(set) var lastQuestionShown = ""
    var transcriptForDisplay: String { transcript.isEmpty ? lastQuestionShown : typedTranscript }

    /// What the interviewer box shows of `transcript`: typed in, a few characters at a time, so a
    /// burst of words flows instead of landing as a lump. Display only. See TranscriptTyping.
    private(set) var typedTranscript = ""
    @ObservationIgnored private var typingTimer: Timer?

    /// Write this interview's own words for the speech engine to listen for. Plain text, because
    /// the engine reads the file directly, so VocabTerms keeps personal details out of it. Only
    /// the count is logged, never the terms.
    private func writeVocabFile() {
        let blob = [companyName, jobDescription, liveHints, resumeText].joined(separator: "\n")
        let terms = VocabTerms.extract(from: blob, company: companyName)
        let url = engine.appDataFolder.appendingPathComponent("vocab.txt")
        do {
            try terms.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            dlog(terms.isEmpty
                 ? "VOCAB: no terms written; the engine only has its built-in list (resume \(resumeText.count) chars, company \(companyName.count), description \(jobDescription.count))"
                 : "VOCAB: wrote \(terms.count) interview terms for the speech engine", tag: "VOCAB")
        } catch {
            dlog("VOCAB: could not write the terms file: \(error.localizedDescription)", tag: "VOCAB")
        }
    }

    private func startTypingTimer() {
        guard typingTimer == nil else { return }
        typingTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tickTyping() }
        }
    }

    private func tickTyping() {
        let target = transcript
        // Nothing to type, or the person has asked their Mac for less motion.
        if target.isEmpty || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            if typedTranscript != target { typedTranscript = target }
            return
        }
        guard typedTranscript != target else { return }
        let next = TranscriptTyping.advance(shown: typedTranscript, toward: target, dt: 0.04)
        if next != typedTranscript { typedTranscript = next }
    }
    var aiAnswerHint = "Ready. Press SPACE to start listening, then SPACE again to get your answer."

    /// The idle prompt must match the ACTIVE mode. It was hardcoded to the manual
    /// instructions, so Practice Auto told the user to press SPACE — advice that is simply
    /// wrong there, and undermines trust in a mode whose entire promise is pressing nothing.
    var idleHintForCurrentMode: String {
        switch listeningMode {
        // In Interview mode the person must be told their own voice is not picked up: a
        // tester who spoke to the app for minutes saw nothing and decided it was broken
        // (Windows, 2026-09-29). Practice hears them, so it needs no such line.
        case .manual: return practiceAudioOn
            ? "Ready. Press SPACE to start listening, then SPACE again to get your answer."
            : "Ready. Press SPACE to start listening, then SPACE again to get your answer. Interview mode does not pick up your own voice. To try it by speaking, choose Practice above."
        case .auto:   return practiceAudioOn
            ? "Listening. The answer appears when the question ends."
            : "Auto is on. When the interviewer asks a question in your meeting, the answer appears here on its own. Interview mode does not pick up your own voice. To try it by speaking, choose Practice above. If an answer does not come, press SPACE."
        }
    }
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
    // ── Screening details ─────────────────────────────────────────────────────
    //
    // "Are you looking for C2C or W2 or full time?" is asked in the first two minutes of
    // nearly every US contract screen, and the answer appears on no resume ever written.
    // With nothing to go on the app produced a paragraph about wanting to grow and learn,
    // which answers none of it and reads to a screener as dodging a direct question.
    //
    // Saved with the company and role so they are answered once, not before every interview.
    static let notSpecified = "Not specified"
    static let workTypeOptions   = [notSpecified, "C2C (corp to corp)", "W2 contract",
                                    "C2H (contract to hire)", "Full time", "1099", "Open to any"]
    static let workAuthOptions   = [notSpecified, "US citizen", "Green card", "H1B", "H4 EAD",
                                    "OPT", "CPT", "TN", "L2 EAD", "No sponsorship needed",
                                    "Will need sponsorship", "Prefer not to answer"]
    static let canStartOptions   = [notSpecified, "Immediately", "In 1 week", "In 2 weeks",
                                    "In 1 month", "In 2 months", "Flexible"]
    static let locationOptions   = [notSpecified, "Remote", "Hybrid", "Onsite", "Open to relocation"]

    var workType    = MainViewModel.notSpecified
    var workAuth    = MainViewModel.notSpecified
    var canStart    = MainViewModel.notSpecified
    var workLocation = MainViewModel.notSpecified
    var payRate     = ""

    /// Only what was actually set.
    ///
    /// ANYTHING LEFT UNSET IS LEFT OUT ENTIRELY. A blank must never become a confident
    /// answer: inventing a visa status or a rate on somebody's behalf is worse than saying
    /// it is open, and both are things a recruiter writes down verbatim and checks later.
    var screeningContext: String {
        var lines: [String] = []
        let ns = Self.notSpecified
        if workType != ns    { lines.append("Work type wanted: \(workType)") }
        if workAuth == "Prefer not to answer" {
            lines.append("Work authorization: the candidate does NOT want to state this. If asked, say warmly that you are authorized to work and happy to go through specifics with the recruiter — never invent a status.")
        } else if workAuth != ns {
            lines.append("Work authorization: \(workAuth)")
        }
        if canStart != ns    { lines.append("Can start: \(canStart)") }
        if workLocation != ns { lines.append("Work location: \(workLocation)") }
        let pay = payRate.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pay.isEmpty      { lines.append("Pay expectation: \(pay)") }
        return lines.joined(separator: "\n")
    }

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
    /// On by default and remembered, as on Windows (AppConfig.KeepOnTop). Stealth keeps the
    /// window out of the Dock and ⌘Tab, so once another window covered it an unpinned window
    /// had no way back — ⌃⌥R now brings it back too.
    var isPinnedOnTop = true
    /// Settings, "Screen keys work in every app". See GlobalHotkey.isScreenKey.
    var screenKeysEverywhere = true
    /// "Real interview? Mic off in Settings", shown in place of AUTO | MANUAL for four seconds
    /// the first time Auto is chosen in a launch with the microphone on. Windows 2523ecf.
    var showMicOffHint = false
    private var micOffHintShown = false
    var mainWindowOpacity: Double = 0.40
    var overlayOpacity: Double = 0.90
    var isScreenAnalyzing = false
    /// Are screen answers ARMED — should a question about the screen be answered from it?
    ///
    /// On by default, and remembered. It used to be a toolbar switch that started off every
    /// launch, which made the feature most likely to matter in a coding round the one a
    /// candidate had to remember to arm with an interviewer already talking. The toolbar now
    /// holds the ACTION (Read Screen) instead; this is the standing preference.
    ///
    /// Defaulting it on is only safe here because capture is question-driven: there is no
    /// timer, so an armed app that nobody is talking to captures nothing at all. On Windows
    /// the same default turned a two-second capture loop into a screenshot every two seconds
    /// for as long as the app was open.
    var isWatchMode = true
    /// Auto Mode: the app decides when the interviewer finished asking and answers with
    /// nothing pressed. This is the difference between using the product in a real
    /// interview and visibly operating it while someone watches.
    var listeningMode: ListeningMode = .manual
    /// Convenience for the many existing gates that only care whether the app is deciding
    /// turn-ends on its own.
    var autoModeEnabled: Bool { listeningMode.isAutomatic }
    private var autoDetector = AutoTurnDetector()
    /// Sent as "provider" on every answer and screen request. The backend chooses the model
    /// itself (Cerebras for answers, Gemini for vision) and ignores this label, but it still
    /// validates it against an allow-list, so it must stay a string the backend accepts. It
    /// used to follow a Settings picker offering "OpenAI (GPT-4o)", an account inactive since
    /// 2026-08-22: a choice nobody could actually get. MAC_CATCHUP, 2026-09-12.
    static let providerLabel = "groq"

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
        // A SECOND PRESS MUST DO SOMETHING. macOS shows the Accessibility dialog once per
        // launch and silently ignores every later request, so this button did nothing at
        // all on the second press — no dialog, no error, no movement. The user is left
        // pressing a button that looks live and is not, which reads as a broken app.
        //
        // It is also the common case rather than an edge one: anybody who granted, came
        // back, and found the card still unticked presses it again. Send them to the pane
        // instead, where the toggle actually is.
        guard !hasPromptedAccessibility else {
            dlog("PERM: accessibility already prompted this launch — opening the pane", tag: "PERM")
            openAccessibilitySettings()
            return
        }
        hasPromptedAccessibility = true
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func openScreenRecordingSettings() {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    /// Shown on the setup screen once a grant has been asked for and still has not landed.
    ///
    /// The situation it explains is invisible otherwise: macOS identifies an app by its
    /// SIGNATURE, not its name, so a rebuilt or re-signed build is a different app to the
    /// system even though the entry in the list looks right and is switched on. The user
    /// sees "Replysis ✓" in Settings and an app insisting the permission is missing, and
    /// both are telling the truth about different binaries.
    var permissionStaleEntryHint: String {
        if screenRecordingLooksStuck {
            // The overwhelmingly common case, and the one the app used to handle worst.
            return "Already switched it on? macOS only applies Screen Recording when the app restarts — this window cannot see the change until then. Quit and reopen below.\n\nIf it is still missing afterwards, remove Replysis from the list with − and add it again: macOS identifies an app by its signature, so an updated build is a new app to it."
        }
        return "If Replysis is already listed and switched on, remove it with the − button and add it again. macOS identifies an app by its signature, so an updated build is a new app to it — the old entry stays behind and does nothing."
    }

    /// Eagerly request Screen Recording from the permissions setup screen, instead of
    /// waiting for the user's first F9/Analyze. CGRequestScreenCaptureAccess() is the
    /// dedicated Core Graphics API for exactly this: it shows the native system dialog if
    /// not yet decided, and returns the current authorization synchronously. Called off the
    /// main thread since it can block while the system dialog is on screen (same pattern as
    /// the other permission calls). Screen Recording — like Accessibility — needs the app to
    /// be relaunched for a NEW grant to actually take effect; startPermissionPolling()'s
    /// existing timer already watches for exactly this transition and relaunches.
    /// Has a grant been asked for and still not landed? Then the entry the user is looking
    /// at in Settings belongs to a different build, and no amount of pressing will help.
    var accessibilityLooksStuck: Bool { hasPromptedAccessibility && !permAccessibility }
    private(set) var screenRecordingAsked = false
    var screenRecordingLooksStuck: Bool { screenRecordingAsked && !permScreenRecording }

    func requestScreenRecordingPermission() {
        guard !screenRecordingAsked else {
            dlog("PERM: screen recording already requested — opening the pane", tag: "PERM")
            openScreenRecordingSettings()
            return
        }
        screenRecordingAsked = true
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
        // The admin dashboard shows a signed-in user as "Live" from this. Each beat checks
        // the session itself, so starting it once at launch covers signing in later.
        PresenceTracker.shared.start()
        // Keeps the answer connection warm, so the first question after a quiet minute does
        // not pay for a new connection and a cold server (see NetworkClient.startKeepWarm).
        NetworkClient.shared.startKeepWarm()
        guard !didAppear else { return }
        didAppear = true
        // Apply the persisted Stealth Mode setting to the window immediately — default is
        // ON, so a fresh install is invisible to screen sharing/recording from the first
        // frame, not just after the user finds a toggle somewhere.
        applyStealthMode()
        // loadSettings() ran in init(), so the saved mode is already active — but the hint
        // is a stored default written for Manual. Relaunching in Practice Auto therefore
        // opened telling the user to press SPACE, which is wrong there and is exactly the
        // advice that mode exists to remove.
        aiAnswerHint = idleHintForCurrentMode
        // Surface a clear message if the speech service rejects the key, instead of
        // silently showing an empty transcript forever.
        engine.onKeyError = { [weak self] in self?.handleSpeechKeyError() }
        // Tell the user the one thing they can act on. Before this it showed "connecting"
        // forever, because a concurrency refusal matched none of the failure tests.
        engine.prepareVocabulary = { [weak self] in self?.writeVocabFile() }
        engine.onConcurrencyLimit = { [weak self] in
            guard let self else { return }
            // The words live in ListeningProblems with the rest, so a test covers them. The
            // window is told through the same once-per-occurrence path as every other problem.
            let d = ListeningProblems.describe(.anotherDevice)
            self.listeningNotice = d.title
            self.aiAnswer = "\(d.title)\n\n\(d.body)"
            self.updateMicUI()
            self.tickListeningProblem()
        }
        // No audio source is permitted — say so loudly rather than capturing something the
        // active mode promised not to.
        engine.onCaptureUnavailable = { [weak self] in self?.handleCaptureUnavailable() }
        // loadSettings() restored the mode in init(), so the mic veto must be in force before
        // the engine's first start — otherwise a relaunch straight into Interview Auto could
        // open the mic on the very first spawn.
        // No mode vetoes the microphone any more. Whether it is used is the Settings switch
        // (micCaptureEnabled), which the engine reads when it starts.
        engine.micCaptureAllowed = true
        // THE turn signal. The recogniser has the waveform and tells us when the speaker
        // actually stopped; we no longer infer it from how the text is punctuated.
        engine.onUtteranceEnd = { [weak self] in self?.handleUtteranceEnd() }
        // Sweep any transcript left behind by a crash or a Force Quit. Deleting on quit
        // covers the graceful path; a process that is killed never runs that handler, and
        // the file it leaves is the last thing an interviewer said. It has no value across
        // launches either way — the engine rewrites it from scratch.
        engine.deleteLatestTxt()
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
        primeMicIfPermitted()

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
                    self.primeMicIfPermitted()   // earliest possible warmup — see MicPrimer's doc comment
                    // If the engine already came up in system-only mode before the user
                    // answered this popup, restart it into BOTH mode NOW — so the first Space
                    // press lands on an already-warm mic pipeline instead of triggering a
                    // restart at that moment.
                    if self.engine.isRunning {
                        dlog("Mic granted — restarting engine into BOTH mode ahead of first ⌥Space", tag: "PERM")
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
                // NOTE: for Screen Recording this transition CANNOT be observed.
                // CGPreflightScreenCaptureAccess() answers for the life of the process, so a
                // grant made while the app is running is invisible to it and this auto-relaunch
                // never fires — a recovery conditioned on a signal that cannot arrive. That is
                // why the setup screen offers an explicit Quit & Reopen once a request has been
                // made and not landed: the user knows they granted it, and the app cannot.
                // Accessibility does flip live, so this still does its job for that one.
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
                case 49:
                    guard GlobalHotkey.isListeningShortcut(keyCode: Int64(event.keyCode),
                            flags: CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)),
                            secondsSinceTyping: GlobalHotkey.instance?.secondsSinceTyping ?? .infinity) else { return event }
                    if !event.isARepeat { self.handleSpacePress(source: "LOCAL") }
                    return nil
                case 100: self.runScreenAnalysis(wholeScreen: false);  return nil   // F8 — this window
                case 101: self.runScreenAnalysis(wholeScreen: true);   return nil   // F9 — main screen
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
            onF8Pressed:    { [weak self] in self?.runScreenAnalysis(wholeScreen: false) },
            onF9Pressed:    { [weak self] in self?.runScreenAnalysis(wholeScreen: true) },
            onF12Pressed:   { },
            onKillPressed:  {
                // ⌃⇧F4 exists for "someone just walked in", so it stays instant and
                // unconfirmed — a prompt defeats the point. Windows keeps theirs the same
                // way (2026-09-22). What was missing on both sides is the record of it.
                dlog("Kill chord ⌃⇧F4 pressed — quitting immediately, no confirmation", tag: "LIFECYCLE")
                MainViewModel.quitWithoutAsking = true
                NSApplication.shared.terminate(nil)
            }
        )
        hotkey?.onBringToFront = { [weak self] in self?.bringToFront() }
        hotkey?.onRegionAnalysisPressed = { [weak self] in self?.runRegionAnalysis() }
        hotkey?.onPreviousAnswer = { [weak self] in self?.showPreviousAnswer() }
        hotkey?.onNextAnswer = { [weak self] in self?.showNextAnswer() }
        hotkey?.setScreenKeysEverywhere(screenKeysEverywhere)
        refreshHotkeyGate()   // seed the tap's consume/pass-through state
    }

    /// Push the current sign-in + text-editing state to the global hotkey tap so it knows
    /// when to CONSUME Space (clean push-to-talk) vs pass it through (typing / signed out).
    /// Called on the main thread whenever either can change. (No need to track the login
    /// sheet separately: while it's up the user isn't signed in yet, so Space already
    /// passes through and types into the email/password fields.)
    func refreshHotkeyGate() {
        // On the Setup page Space is for typing, not for listening.
        let editing = isEditingText || needsPermissionSetup || appStep == .setup
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
        // The Setup page is for preparing, not for listening. Start interview is the one way in.
        if appStep == .setup {
            dlog("⌥ SPACE from \(source): on the Setup page — ignoring", tag: "SPACE")
            return
        }

        if !session.isLoggedIn {
            // BUG-5 FIX: if async restore is still in flight, swallow the press — the user
            // has a valid saved session, they just haven't been authenticated yet (~1-2s lag).
            // Without this guard, Space fires .showLogin before the Keychain restore completes
            // and the user sees a login sheet for an account they're already signed into.
            if isRestoringSession {
                dlog("⌥ SPACE from \(source): session restore in flight — ignoring to avoid premature login prompt", tag: "SPACE")
                return
            }
            dlog("⌥ SPACE from \(source): not signed in → prompting sign-in", tag: "SPACE")
            NotificationCenter.default.post(name: .showLogin, object: nil)
            return
        }

        // Lazy microphone permission — ONLY when the user has opted into it from Settings
        // (Audio Capture: "System audio + my voice"). With the default "System audio only"
        // mode, the mic is never touched and never prompted for, so the app stays fully
        // invisible (no orange indicator, nothing in the mic list if checked).
        // Gated on the EFFECTIVE rule, not the saved preference: in Interview Auto this used
        // to fire the macOS microphone prompt, and route the user to the mic privacy pane,
        // for a device that mode never opens.
        if micCaptureActive {
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
                            dlog("Mic granted on first ⌥Space — restarting engine in BOTH mode", tag: "SPACE")
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

        dlog("⌥ SPACE pressed from \(source) | loggedIn=\(session.isLoggedIn) | engineRunning=\(engine.isRunning) | isMuted=\(isMuted) | isProcessing=\(isProcessing)", tag: "SPACE")

        if isProcessing {
            // One press cancels the answer on its way and listens again, as on Windows
            // (InterruptAiAndListen). The interviewer who follows up fast must not have to wait
            // for an answer they no longer need before they can ask. Only in Manual, where the
            // mic is shut while answering: in Auto the mic is open and Space means something else.
            guard isMuted, !autoModeEnabled, !isScreenAnalyzing else {
                dlog("⌥ SPACE ignored — AI is processing", tag: "SPACE"); return
            }
            dlog("⌥ SPACE: interrupting the answer — back to listening", tag: "SPACE")
            answerEpoch += 1
            isProcessing = false
            showThinking = false
        }
        let now = Date()
        guard now.timeIntervalSince(lastSpaceTime) >= spaceDebounceMs else {
            dlog("⌥ SPACE debounced", tag: "SPACE"); return
        }
        lastSpaceTime = now

        if session.isLoggedIn && !engine.isRunning && isMuted {
            let key = session.speechmaticsKey
            dlog("⌥ SPACE: engine not running, smKey length=\(key.count)", tag: "SPACE")
            if key.isEmpty {
                // BUG-1 FIX: if session restore is still in flight the key just hasn't been
                // fetched yet — don't cry "NO MIC" and lock in a 60s retry; just wait.
                if isRestoringSession {
                    dlog("⌥ SPACE: key not yet fetched (restore in flight), ignoring", tag: "SPACE")
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
            dlog("⌥ SPACE: restarting dead engine before unmuting", tag: "SPACE")
            engine.start(smKey: key)
        }

        if isMuted {
            dlog("⌥ SPACE: unmuting → LISTENING", tag: "SPACE")
            stoppedForIdle = false   // the user is back; the room is not empty any more
            isMuted = false; isListening = true
            justStartedListening = true; listenStartTicks = 0
            resetAutoTurnState()   // fresh turn — nothing from the last one carries over
            clearAnswerForNewTurn()
            // The engine has a slow (~10s) cold start on the first listen after launch.
            // Tell the user it's warming up instead of showing a green mic that silently
            // drops the first words — this was the "Space does nothing at first" bug.
            if engine.statusText == "NO ENGINE" || engine.statusText == "ENGINE ERR" {
                // Never promise a warm-up that cannot happen. The binary is missing or
                // failed to spawn, so nothing will ever transcribe — say so, instead of
                // leaving "warming up" on screen forever while the user waits.
                aiAnswerHint = "⚠ The speech engine isn't available in this build, so audio can't be transcribed.\n\nTyping a question and F9 screen analysis still work."
            } else if !engine.isReady {
                aiAnswerHint = "Warming up… audio will transcribe in a moment (first time after launch only)."
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.engine.clearLatestTxt()
                self?.engine.writeResetFlag()
                self?.engine.deletePauseFlag()
            }
            listenTurnID = UUID()
            confirmCaptureResumed(listenTurnID)
            updateMicUI()
            // Wake the backend now (TLS + cold JVM) so the first answer isn't slow.
            NetworkClient.shared.warmUp()
        } else {
            dlog("⌥ SPACE: muting → sending to AI. transcript='\(transcript.prefix(80))'", tag: "SPACE")
            listenTurnID = UUID()      // any recheck still running belongs to the turn that just ended
            isListening = false
            // The engine is NOT paused here. It is paused when the flush below has the end of
            // the question. Pausing first and then waiting for the tail waited for words that
            // could no longer come: pressed as the voice stopped, the last words were still
            // inside the engine, the pause dropped them, and "What is a binary search tree?" was
            // answered as "What is a" (found by testing, 2026-10-01).
            isMuted = true
            updateMicUI()
            Task { @MainActor [weak self] in
                await self?.flushTranscriptThenAnswer()
            }
        }
    }

    /// Wait for the TAIL of the sentence, then answer.
    ///
    /// Speech recognition runs behind live speech, so at the moment the user stops the
    /// last words they said are still arriving. Sending immediately sends a truncated
    /// question. A FIXED delay is the wrong fix in both directions: too short and it cuts
    /// the question, too long and the user waits for nothing — and that wait is felt
    /// directly, because it happens before the request is even sent, while the model
    /// itself answers in about 0.15s.
    ///
    /// So this watches the transcript instead of guessing:
    ///   • poll every 20ms
    ///   • when it has stopped GROWING for 100ms, the utterance has landed — send it
    ///   • if nothing was ever transcribed, give up after 400ms and say so, rather than
    ///     waiting out a long cap for a sentence that was never spoken
    private func flushTranscriptThenAnswer() async {
        let pollNs: UInt64 = 20_000_000          // 20ms
        // People press Space the moment they stop talking, and often a beat before, so the
        // mode most people use was the only one that cut them off mid-sentence: "do you know
        // coding or coding language? You" went to the model exactly like that. Being told to
        // press more carefully is not a fix. A finished sentence never reaches this branch,
        // so the ordinary case pays nothing.
        let stableTicksFinished = 5              // 5 x 20ms = 100ms of no growth
        let stableTicksUnfinished = 40           // 40 x 20ms = 800ms, still inside maxTicks
        // Nothing transcribed yet is not the same as nothing said. The speech service answers a
        // second or two behind the voice, so a short question pressed the instant it ended has
        // no text for a while ("What is a binary search tree?" answered nothing). When the audio
        // was loud a moment ago, wait for the words; when it was silent, the old 400ms is plenty
        // to say "no speech was captured".
        var heardAudioJustNow = micCaptureActive
        if #available(macOS 14.2, *), SystemAudioTapper.shared.secondsSinceAudio < 3.0 { heardAudioJustNow = true }
        // On a poor connection the first words have been seen to take 5 seconds to come back, so
        // when audio was heard the wait is long, and says what it is waiting for.
        let emptyTicksNeeded  = heardAudioJustNow ? 300 : 20     // 6s, or 400ms of nothing at all
        let maxTicks = heardAudioJustNow ? 450 : 64              // hard ceiling: 9s, or ~1.28s
        let pressedAt = Date()
        // When the last sound was heard, so an end-of-sentence signal from BEFORE it is not
        // mistaken for the end of what is still arriving.
        var lastSoundAt = Date.distantPast
        if #available(macOS 14.2, *), SystemAudioTapper.shared.lastAudioAt > 0 {
            lastSoundAt = Date(timeIntervalSinceReferenceDate: SystemAudioTapper.shared.lastAudioAt)
        }

        var question = engine.readLatestTxt().trimmingCharacters(in: .whitespacesAndNewlines)
        var stable = 0
        var empty = 0

        for _ in 0..<maxTicks {
            try? await Task.sleep(nanoseconds: pollNs)
            // The user pressed Space again during the flush — a fresh listening turn has
            // taken over and this one must not also fire.
            guard isMuted, !isListening else {
                dlog("FLUSH: interrupted — a new turn took over", tag: "SPACE")
                return
            }
            let t = engine.readLatestTxt().trimmingCharacters(in: .whitespacesAndNewlines)
            if t.count > question.count {
                question = t; stable = 0; empty = 0
            } else if !question.isEmpty {
                stable += 1
                let ending = AutoTurnDetector.classifyTurnEnding(question)
                let needed = ending == .finished ? stableTicksFinished : stableTicksUnfinished
                // Text that still stops mid-sentence, with the voice only just over: the rest is
                // arriving late (on a poor connection the words were seen 8 seconds behind, and the
                // question was answered as its first 58 characters, the rest thrown away when the
                // engine paused). Wait for the recogniser to say the sentence is over.
                let sentenceOver = engine.lastUtteranceEndAt > pressedAt || engine.lastUtteranceEndAt > lastSoundAt
                let lateWords = heardAudioJustNow && ending != .finished && !sentenceOver
                if stable >= needed && !lateWords { break }
            } else {
                empty += 1
                if empty >= emptyTicksNeeded { break }
            }
        }

        // Now the question is whole, stop listening.
        engine.writePauseFlag()
        if !question.isEmpty { transcript = question }
        startAI()
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
        if !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lastQuestionShown = q }
        // WATCH MODE: the interviewer is sharing their screen, so every question is about
        // what is on it. Answer from the screen rather than from the words alone — but only
        // now, when a question actually exists, rather than on a timer.
        // Watching a screen does not make every question about the screen. A behavioural
        // question sent down this path comes back as an answer about a code editor — the
        // wrong shape, a picture nobody asked about paid for, and a quiet signal to the
        // interviewer that something is reading their screen. isPersonalQuestion is narrow
        // on purpose: anything uncertain stays on the screen path, and "solve this" or
        // "this code" always wins, so "do you prefer this code or that one" still counts.
        // THE SCREEN IS USED WHEN THE QUESTION IS ABOUT THE SCREEN — not whenever the app
        // can see one. This was written the wrong way round: everything except a short list
        // of personal questions went down the screen path, so "tell me what is Java?" was
        // answered by sending a photograph of the desktop. Three times the tokens, a worse
        // answer, and the minute's allowance spent on a question that never needed a
        // picture. Watching became a tax on every question rather than a feature for some.
        //
        // Trigger phrase FIRST, then continuation — the order matters, and isPersonalQuestion
        // short-circuits on a screen reference so "this code" beats "do you prefer".
        //
        // Armed by default, so a brand-new user without Screen Recording must not walk into
        // a permission wall on their first question: without it we answer from what was
        // said, which is the answer the app gave before screen answers existed.
        let canReadScreen = CGPreflightScreenCaptureAccess()
        let namesTheScreen = PromptBuilder.refersToScreen(q)

        // ASKED ABOUT THE SCREEN, AND WE CANNOT SEE IT.
        //
        // Falling through to the speech path here was my earlier decision and it was wrong.
        // The reasoning — answer from what was said rather than fail the question — holds
        // for a question that merely ARRIVED while a screen was up. It does not hold for a
        // question that is explicitly ABOUT the screen: the model, asked what is on a
        // screen it was never given, improvises, and what it improvises is a denial. It
        // told a candidate "I still can't see your screen, I'm just a person you're talking
        // to, you'll have to be my eyes" — read aloud, mid-interview, that is worse than
        // any silence.
        //
        // So say the true thing in one line, and say how to fix it.
        if namesTheScreen && isWatchMode && !canReadScreen {
            dlog("SCREEN: asked about the screen without permission to read it", tag: "SCREEN")
            answerEpoch += 1
            isProcessing = false; showThinking = false
            aiAnswer = "⚠ That question is about your screen, and macOS has not granted screen access yet.\n\nSystem Settings → Privacy & Security → Screen & System Audio Recording → enable Replysis, then reopen the app.\n\nUntil then, spoken questions are answered normally."
            updateMicUI()
            return
        }
        let inheritsScreen = lastAnswerUsedScreen && screenFollowUpBudget > 0
            && !PromptBuilder.isPersonalQuestion(q)
        let aboutTheScreen = isWatchMode && canReadScreen && (namesTheScreen || inheritsScreen)
        if namesTheScreen && isWatchMode && canReadScreen {
            screenFollowUpBudget = maxScreenFollowUps       // refilled by an explicit ask
        } else if inheritsScreen {
            screenFollowUpBudget -= 1                       // drawn down per follow-up
        } else {
            screenFollowUpBudget = 0                        // zeroed by anything else
        }
        lastAnswerUsedScreen = aboutTheScreen
        if aboutTheScreen, !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isScreenAnalyzing {
            // Watching means the SCREEN. "Frontmost window" in a mode nobody is touching is
            // whichever window was clicked last, which is how an answer ends up confidently
            // describing something the interviewer is not looking at.
            capturingWholeScreen = true
            isScreenAnalyzing = true; isProcessing = true
            startBusyWatchdog()
            answerEpoch += 1
            updateMicUI()
            Task { await _doScreenCapture(label: "👁 SCREEN") }
            return
        }
        guard !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Honest feedback instead of silently doing nothing — the #1 "is it broken?"
            // moment is pressing Space twice and seeing zero reaction.
            aiAnswerHint = "No speech was captured. Speak (or play the interviewer's audio), then press Space again."
            updateMicUI(); return
        }
        guard session.isLoggedIn else { aiAnswer = "⚠ Please sign in to use AI answers."; return }
        // Blocked below ONE answer, not below one credit: 1 to 4 credits buys nothing, and
        // letting it through only earns a refusal from the server mid-question.
        guard PlanFacts.mayAsk(balanceKnown: session.creditsKnown, credits: session.credits,
                               isUnlimited: session.isUnlimited) else {
            showOutOfAnswers(); return
        }
        // Not known yet: ask the server (it has the real number) and look again in the background.
        if !session.creditsKnown { Task { [weak self] in await self?.fetchCredits() } }

        isProcessing = true; showThinking = true; thinkingStep = 0
        startBusyWatchdog()
        answerEpoch += 1   // new answer → scroll view jumps to top
        updateMicUI()

        let builder = PromptBuilder.shared
        let resumeFacts = ResumeParser.extractFacts(resumeText)
        let (qType, isDrill) = builder.classifyQuestion(q)
        // Light up the STAR badge when this is a behavioral question
        if case .behavioral = qType { answerIsBehavioral = true } else { answerIsBehavioral = false }

        if builder.isGreeting(q)  { finishAI(question: q, answer: builder.getGreetingResponse());  return }
        if builder.isSmallTalk(q) { finishAI(question: q, answer: builder.getSmallTalkResponse()); return }
        // A repeat "any other questions?" or the final sign-off gets a short, human reply
        // instead of another invented question. The first invitation still reaches the model.
        // Same order as Windows. See PromptBuilder.closingResponse.
        if let reply = builder.closingResponse(to: q) { finishAI(question: q, answer: reply); return }
        // No more "off-topic" silence. Short turns with no interview keyword were dropped
        // with no answer and no log — "Kafka partitions?" got nothing. Windows removed the
        // same step: when the turn is uncertain, the model decides, never a local guess.

        let messages = builder.buildMessages(resumeFacts: resumeFacts, currentQuestion: q,
                                             qTypeHint: qType, drillDownHint: isDrill,
                                             jobContext: jobContext,
                                             hints: liveHints, screening: screeningContext)
        let provider = Self.providerLabel
        // Amber at two answers left or fewer, in answers, never credits.
        let lowBanner = (session.creditsKnown && !session.isUnlimited && PlanFacts.isLow(session.credits) && !PlanFacts.isEmpty(session.credits))
            ? PlanFacts.lowWarning(credits: session.credits, freeTrial: onFreeTrial) + "\n\n" : ""

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

        // Time the answer. This app is sold on being fast and has never measured itself, so
        // "it feels slow" had no number attached and no way to tell WHERE the time goes:
        // the recogniser deciding the turn ended, the network, or the model generating. The
        // three have completely different fixes and look identical from the outside.
        let askedAt = Date()
        let heardEndAt = lastUtteranceEndAt

        NetworkClient.shared.streamAnswer(
            question: q, resume: resumeText, provider: provider, messages: msgArr,
            onToken: { [weak self] token in
                guard let self = self, self.answerEpoch == epoch else { return }
                accumulated += token; tokenCount += 1
                if tokenCount == 1 {
                    self.showThinking = false
                    let toFirst = Date().timeIntervalSince(askedAt)
                    // Time from the speaker stopping, which is what the user actually feels —
                    // the request is only the second half of their wait.
                    let sinceSpeech = heardEndAt == .distantPast
                        ? -1 : Date().timeIntervalSince(heardEndAt)
                    dlog(String(format: "LATENCY: first token %.2fs after request%@",
                                toFirst,
                                sinceSpeech < 0 ? "" : String(format: ", %.2fs after they stopped speaking", sinceSpeech)),
                         tag: "PERF")
                }
                if tokenCount % 3 == 0 || token.contains("\n") {
                    self.aiAnswer = "Q: \(q)\n\n\(lowBanner)\(accumulated)"
                }
            },
            onDone: { [weak self] in
                guard let self = self, self.answerEpoch == epoch else { return }
                dlog(String(format: "LATENCY: complete in %.2fs (%d tokens)",
                            Date().timeIntervalSince(askedAt), tokenCount), tag: "PERF")
                let final = self.cleanAIOutput(accumulated)
                self.finishAI(question: q, answer: final, prefix: "Q: \(q)\n\n\(lowBanner)",
                              historyAnswer: accumulated)
                Task { [weak self] in await self?.fetchCredits() }
            },
            onError: { [weak self] err in
                guard let self = self, self.answerEpoch == epoch else { return }
                if err == "NO_CREDITS" {
                    self.showOutOfAnswers()
                }
                else if err == "SESSION_EXPIRED" { self.engine.stop(); self.session.clear(); self.setLoggedOutUI() }
                else if err.hasPrefix("RATE_LIMIT") {
                    self.aiAnswer = Self.rateLimitMessage(err)
                }
                else if err.hasPrefix("SERVER_MSG:") {
                    // The server said something specific and useful. Replacing it with a
                    // generic line here would throw away the only message that knows which
                    // allowance ran out and how long it takes to come back.
                    self.aiAnswer = "⏳ " + String(err.dropFirst("SERVER_MSG:".count))
                }
                else                         { self.aiAnswer = "⚠ Something went wrong. Please try again." }
                // DATA-LOSS FIX: previously the error paths saved nothing, so if the AI
                // failed (out of credits, connection issue) the interviewer's question was
                // lost from the session record entirely. Preserve it with a clear
                // placeholder answer so the session still reflects what was asked. Skipped
                // for SESSION_EXPIRED — the session is cleared there, so there's nothing to
                // save into.
                if err != "SESSION_EXPIRED" {
                    let reason = err == "NO_CREDITS" ? "no answers left" : "connection issue"
                    self.appendToSessionLog(q: q, a: "[No answer — \(reason). Question preserved.]")
                }
                self.stopThinkingUI()
            }
        )
    }

    /// - Parameter historyAnswer: what to remember, when that differs from what to show.
    ///   Display strips code fences; history must KEEP them, because the fences are how a
    ///   later turn finds the code block to collapse. Without them the code is still there,
    ///   indistinguishable from prose, and rides along in every later prompt forever.
    /// Say a rate limit IS a rate limit.
    ///
    /// "The AI service is temporarily unavailable" is true and useless: nothing is broken,
    /// this minute's allowance is spent, and it comes back on its own. Saying so is the
    /// difference between a user waiting twenty seconds and a user filing a bug.
    ///
    /// A wait under fifteen seconds is never printed. An early version on Windows managed
    /// "try again in about 1 seconds", which is worse than saying nothing — it reads as
    /// broken twice over, and by the time it is read the number is wrong anyway.
    static func rateLimitMessage(_ err: String) -> String {
        let seconds = Int(err.split(separator: ":").last.map(String.init) ?? "") ?? 0
        let when = seconds >= 15 ? "in about \(seconds) seconds" : "in a moment"
        return """
        ⏳ This minute's allowance for the AI service is spent

        Nothing is broken and nothing was lost — the limit resets on its own. Ask again \(when).

        The free tier allows 8,000 tokens a minute, and a full-screen analysis costs about \
        1,800 of them, so a few screen questions in quick succession will reach it.
        """
    }

    /// Set by the kill chord so the quit confirmation is skipped for that one path.
    nonisolated(unsafe) static var quitWithoutAsking = false

    // ── First-run flow: Setup, Interview, Finish, Past sessions ────────────────────────
    //
    // The window opens on a full-page Setup, then moves to the Interview view. Ported from
    // Windows (3665daa, 2026-09-28), with the rules that cost it real bugs:
    //   1. Picking Auto on Setup does NOT start listening. Listening begins only after the
    //      step changes to Interview.
    //   2. No screen capture on Setup, on Past sessions, or after Finish. Windows kept
    //      capturing the desktop behind Past sessions after Finish.
    //   3. Watch Screen stays ON by default (the owner's decision, 2026-09-17).
    //   4. Finish stops the mic WITHOUT sending the partial sentence, waits up to 5 s for the
    //      transcript writer, then opens Past sessions. It refuses while an answer streams.
    //   5. Starting again from Setup creates a fresh session file.
    enum AppStep { case setup, interview }
    var appStep: AppStep = .setup
    /// Start interview has been pressed at least once this session; the screen-preparation
    /// timer runs only once it has, and never on Setup.
    private(set) var interviewStarted = false
    /// Past sessions is on screen.
    var sessionsOpen = false
    /// Shows "Saving..." on the Finish button.
    private(set) var finishing = false
    var inSetup: Bool { appStep == .setup }

    /// May the screen be captured on a timer? Only in a live interview, and never behind Past
    /// sessions. On-demand reads (F7, F8, F9, Read screen) are the person's own action.
    var screenPreparationAllowed: Bool { appStep == .interview && interviewStarted && !sessionsOpen }

    /// Short or Detailed answers (Setup page, Settings). Short is the long-standing behaviour.
    var answerDetailed = false
    func setAnswerDetailed(_ detailed: Bool) {
        guard answerDetailed != detailed else { return }
        answerDetailed = detailed
        PromptBuilder.shared.detailedAnswers = detailed
        saveSettings()
        dlog("Answer length -> \(detailed ? "Detailed" : "Short")", tag: "SETTINGS")
    }

    // ── First-run welcome ─────────────────────────────────────────────────────────────
    var showOnboarding = false
    private var onboardingSeenURL: URL { engine.appDataFolder.appendingPathComponent("onboarding_seen") }

    /// DEBUG builds only: "start:6,back:4,finish:4" runs each step, waiting N seconds after it.
    func runFlowScriptIfAny() {
        guard let script = DeveloperOverrides.flowScript, !script.isEmpty else { return }
        // "watch": take one action name per line from a file, so a test driver can press the
        // app's own controls between the things it says and the keys it sends.
        if script == "watch" {
            let url = engine.appDataFolder.appendingPathComponent("flow.cmd")
            Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
                    try? FileManager.default.removeItem(at: url)
                    for line in text.split(separator: "\n") { self.performFlowAction(String(line)) }
                }
            }
            return
        }
        var delay: TimeInterval = 8          // let the window settle first
        for part in script.split(separator: ",") {
            let bits = part.split(separator: ":")
            let action = String(bits.first ?? ""), wait = TimeInterval(bits.dropFirst().first ?? "3") ?? 3
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.performFlowAction(action) }
            delay += wait
        }
    }

    private func performFlowAction(_ action: String) {
        dlog("FLOWSCRIPT: \(action)", tag: "FLOW")
        switch action {
        case "start":  startInterview()
        case "back":   backToSetup()
        case "finish": Task { _ = await finishInterview() }
        case "closesessions": sessionsOpen = false
        case "busy":   engine.debugSimulateConcurrencyRefusal()
        case "weak":   engine.debugSimulateConnectionTrouble()
        // The buttons on the answer bar and the history controls, pressed by name.
        case "clear":    clearAnswer()
        case "new":      newSession()
        case "short":    setAnswerDetailed(false)
        case "detailed": setAnswerDetailed(true)
        case "prev":     showPreviousAnswer()
        case "next":     showNextAnswer()
        case "live":     returnToLive()
        case "dump":     dlog("FLOWSTATE: step=\(appStep) sessions=\(sessionsOpen) answer='\(aiAnswer.prefix(60))' transcript='\(transcript.prefix(40))' shownQuestion='\(transcriptForDisplay.prefix(40))' history=\(answerHistory.count) detailed=\(answerDetailed)", tag: "FLOW")
        default: break
        }
    }

    func showOnboardingIfFirstRun() {
        if !FileManager.default.fileExists(atPath: onboardingSeenURL.path) { showOnboarding = true }
    }
    func dismissOnboarding() {
        showOnboarding = false
        try? "1".write(to: onboardingSeenURL, atomically: true, encoding: .utf8)
    }
    func replayIntro() { showOnboarding = true }

    func startInterview() {
        guard appStep == .setup, !finishing else { return }
        sessionsOpen = false
        // Finish closes the previous session before showing Past sessions, so starting again
        // prepares a fresh transcript instead of reusing the finished file.
        let needsFreshSession = !isRecording
        if needsFreshSession {
            transcript = ""; aiAnswer = ""; lastQuestionShown = ""; answerEpoch += 1
            liveHints = ""; saveHints()
        }
        appStep = .interview
        interviewStarted = true
        problemsShown.removeAll()
        stoppedForIdle = false
        heardEverThisRun = false; interviewSilentTipShown = false
        if needsFreshSession { prepareSession() }
        beginInterviewClock()
        aiAnswerHint = idleHintForCurrentMode
        refreshHotkeyGate()
        updateMicUI()
        dlog("INTERVIEW: started (\(autoModeEnabled ? "Auto" : "Manual"), \(practiceAudioOn ? "Practice" : "Interview") audio)", tag: "FLOW")
    }

    /// Back to Setup without ending the session. The microphone is closed: a listening app
    /// with the mic controls out of sight would be listening to nobody who could see it.
    func backToSetup() {
        guard appStep == .interview else { return }
        stopListeningForSetup()
        appStep = .setup
        refreshHotkeyGate()
        dlog("INTERVIEW: back to Setup (session kept)", tag: "FLOW")
    }

    private func stopListeningForSetup() {
        guard isListening else { return }
        stopListeningMeter()
        isListening = false; isMuted = true
        autoTurnSubmitting = false
        resetAutoTurnState()
        engine.writePauseFlag()
        updateMicUI()
    }

    /// Finish the interview and open Past sessions, so the last answer and the duration are
    /// always in it. Returns a reason when it refuses, for the caller to show.
    func finishInterview() async -> String? {
        guard !finishing else { return nil }
        if isProcessing || isScreenAnalyzing {
            showAlert(title: "Answer still finishing",
                      body: "Wait for the current answer to finish, then choose Finish again so the complete turn is saved.")
            return "busy"
        }
        finishing = true
        defer { finishing = false }
        // Finishing is not the same action as submitting a question. If the microphone is
        // open, stop capture WITHOUT sending the partial sentence to the model.
        stopListeningForSetup()
        let hadSession = isRecording
        let number = sessionNumber
        endSession()
        // Wait off the main thread so Past sessions never opens on a file whose final answer
        // is still queued behind the writer.
        let saved = await Task.detached(priority: .userInitiated) { () -> Bool in
            MainViewModel.drainSessionLog(timeout: 5)
            return true
        }.value
        _ = saved
        appStep = .setup            // Start interview begins a fresh session from here
        sessionsOpen = true
        refreshHotkeyGate()
        if hadSession { dlog("INTERVIEW: session \(number) finished and opened in Past sessions", tag: "FLOW") }
        return nil
    }

    // ── Answers you can go back to ─────────────────────────────────────────────
    //
    // A live interview only ever showed the newest answer. A stray voice in the room, a
    // colleague talking past the mic, or the interviewer moving on mid-read was enough to
    // replace an answer somebody was still speaking from — and it was gone. Every answer
    // this session is kept in memory, so stepping back is instant and costs nothing.
    struct AnsweredTurn: Identifiable {
        let id = UUID()
        let question: String
        let answer: String
        let at: Date
    }
    private(set) var answerHistory: [AnsweredTurn] = []
    /// Which past answer is on screen, or nil when showing the live one.
    private(set) var historyIndex: Int?
    /// An answer arrived while a past one was being read: never steal the screen, say so.
    private(set) var newerAnswerWaiting = false
    private var liveAnswer = ""
    private var liveTranscript = ""

    var isShowingHistory: Bool { historyIndex != nil }
    var historyPosition: String {
        guard let i = historyIndex else { return "" }
        return "\(i + 1) of \(answerHistory.count)"
    }
    var canGoBack: Bool {
        guard !answerHistory.isEmpty else { return false }
        return historyIndex == nil || (historyIndex ?? 0) > 0
    }
    var canGoForward: Bool { historyIndex != nil }

    /// Starting a turn empties the answer panel — unless a past answer is being read, in
    /// which case it empties the LIVE one underneath and leaves the screen alone. Windows
    /// found this live (2026-09-22): listening cleared the box, so the moment the
    /// interviewer began the next question the answer just recovered was wiped, which is
    /// the exact loss this feature exists to prevent, one second later.
    private func clearAnswerForNewTurn() {
        if historyIndex != nil {
            liveTranscript = ""; liveAnswer = ""
            return
        }
        transcript = ""; aiAnswer = ""
    }

    /// How many answers have arrived while a past one was being read.
    private(set) var newerAnswerCount = 0
    var newerAnswerBadge: String {
        newerAnswerCount <= 0 ? "" : (newerAnswerCount == 1 ? "1 new answer" : "\(newerAnswerCount) new answers")
    }

    /// One answer back. Instant: it reads memory and never calls the model.
    func showPreviousAnswer() {
        guard !answerHistory.isEmpty else { return }
        if historyIndex == nil {
            liveAnswer = aiAnswer
            liveTranscript = transcript
            historyIndex = answerHistory.count - 1
        } else if let i = historyIndex, i > 0 {
            historyIndex = i - 1
        } else {
            return
        }
        applyHistoryView()
    }

    /// Forward again, and past the newest one back to the live answer.
    func showNextAnswer() {
        guard let i = historyIndex else { return }
        if i + 1 < answerHistory.count {
            historyIndex = i + 1
            applyHistoryView()
        } else {
            returnToLive()   // past the newest: follow the live answer again
        }
    }

    func returnToLive() {
        guard historyIndex != nil else { return }
        historyIndex = nil
        newerAnswerWaiting = false
        newerAnswerCount = 0
        aiAnswer = liveAnswer
        transcript = liveTranscript
        answerEpoch += 1          // scroll back to the top of the live answer
        dlog("HISTORY: back to the live answer", tag: "HISTORY")
    }

    private func applyHistoryView() {
        guard let i = historyIndex, answerHistory.indices.contains(i) else { return }
        let turn = answerHistory[i]
        transcript = turn.question
        aiAnswer = turn.answer
        answerEpoch += 1
        dlog("HISTORY: showing answer \(i + 1) of \(answerHistory.count)", tag: "HISTORY")
    }

    private func finishAI(question: String, answer: String, prefix: String = "",
                          historyAnswer: String? = nil) {
        answerHistory.append(AnsweredTurn(question: question, answer: answer, at: Date()))
        // Bounded: an interview is dozens of turns, and this is only ever read by a person.
        if answerHistory.count > 60 { answerHistory.removeFirst() }
        // READING A PAST ANSWER IS NOT INTERRUPTED. The new answer is live underneath and
        // one press of ⌃⌥→ away; taking the screen is exactly the loss this exists to stop.
        if historyIndex != nil {
            liveAnswer = "\(prefix)\(answer)"
            liveTranscript = question
            newerAnswerWaiting = true
            newerAnswerCount += 1
            lastAnsweredAnswer = answer
            PromptBuilder.shared.addToHistory(question: question, answer: historyAnswer ?? answer)
            appendToSessionLog(q: question, a: answer)
            stopThinkingUI()
            return
        }
        aiAnswer = "\(prefix)\(answer)"
        // Remembered so the next utterance can be checked against it. In Practice Auto the
        // user reads this aloud to rehearse, and without this the app hears its own answer
        // coming back and treats it as a fresh question.
        lastAnsweredAnswer = answer
        PromptBuilder.shared.addToHistory(question: question, answer: historyAnswer ?? answer)
        appendToSessionLog(q: question, a: answer)
        stopThinkingUI()
    }

    func stopThinkingUI() {
        showThinking = false; isProcessing = false; isScreenAnalyzing = false
        busyWatchdog?.invalidate(); busyWatchdog = nil
        answerSettledAt = Date()
        updateMicUI(); thinkingText = "Thinking..."
        // Listening again is what makes Auto Mode continuous rather than single-shot.
        rearmAutoModeIfNeeded()
    }

    // MARK: - Screen Analysis

    /// - Parameter wholeScreen: take the whole display instead of the front window.
    ///   F9 is labelled "main screen" and F8 "this screen"; both called this with no
    ///   distinction, so the two badges in the header described a difference that did not
    ///   exist. They differ now, which also gives an explicit way to grab a whole monitor
    ///   without turning watch mode on.
    func runScreenAnalysis(wholeScreen: Bool = false) {
        guard !isProcessing && !isScreenAnalyzing else { return }
        // Same gate as Space: signed-out → take them to sign-in, not a dead-end message.
        guard session.isLoggedIn else {
            NotificationCenter.default.post(name: .showLogin, object: nil); return
        }

        dlog("Screen analysis triggered (wholeScreen=\(wholeScreen))", tag: "SCREEN")
        answerIsBehavioral = false   // screen analysis isn't a behavioral question
        answerEpoch += 1             // new answer → scroll to top
        capturingWholeScreen = wholeScreen
        isScreenAnalyzing = true; isProcessing = true; startBusyWatchdog(); updateMicUI()

        Task { await _doScreenCapture(label: wholeScreen ? "MAIN SCREEN" : "THIS SCREEN") }
    }

    // Arms screen answers. While armed and listening, the screen is prepared every 2 seconds
    // (see tickPreparedShots); the model reads it only when a question is asked.
    /// Settings toggle. Kept separate from the toolbar, which now performs an action.
    func setScreenAnswers(_ enabled: Bool) {
        guard isWatchMode != enabled else { return }
        isWatchMode = enabled
        saveSettings()
        dlog("Screen answers \(enabled ? "ARMED" : "off")", tag: "SCREEN")
    }

    func toggleWatchMode() {
        guard session.isLoggedIn else { aiAnswer = "⚠ Please sign in first."; return }
        if isWatchMode {
            isWatchMode = false
            dlog("Watch mode OFF", tag: "SCREEN")
            aiAnswer = "Screen watch mode stopped."
        } else {
            isWatchMode = true
            dlog("Watch mode ON — screen prepared every 2s while listening; read only when a question is asked", tag: "SCREEN")
            aiAnswer = "👁 WATCH MODE ON — for when the interviewer is sharing their screen.\n\nEvery question is now answered from what is on screen, with nothing to press.\n\nPress Watch again to go back to answering from what was said."
            // The model reads the screen only when a question is asked, so there is still
            // one vision call per question, never one per frame. What runs every 2 seconds
            // is the capture and, when the screen changed, the upload ahead of the question
            // (see tickPreparedShots) — the schedule the privacy policy describes.
        }
    }

    private func _doScreenCapture(label: String) async {
        // No hide/show dance: captureScreen() either targets the frontmost OTHER window or
        // excludes this app from the display capture, so our window is never in the pixels
        // to begin with. The old approach ordered every window out, slept 80ms for the
        // compositor, then ordered them back — which read as the whole app blinking on
        // every single capture, and cost 80ms of the user's wait for nothing.
        // In watch mode the capture taken on the last 2-second tick IS the screen now; using
        // it takes the capture out of the candidate's wait. An F8 window capture always
        // captures fresh, since the prepared ones are of the whole screen.
        var imageData: Data?
        if capturingWholeScreen, pendingRegionRect == nil, let prepared = freshPreparedShot() {
            dlog("SCREEN: using the capture from \(Int(Date().timeIntervalSince(preparedShotDataAt) * 1000))ms ago; no capture wait", tag: "SCREEN")
            imageData = prepared
        } else {
            imageData = await captureScreen()
        }

        guard let imageData = imageData, !imageData.isEmpty else {
            // Failing SILENTLY here is not acceptable: the user asked a question, watched
            // nothing happen, and had no way to know why. macOS shows its own permission
            // prompt, but that can be dismissed or already-declined, in which case every
            // future capture fails with no visible reason at all. Say what happened and
            // what fixes it, and turn Watch Mode off so it does not keep failing per
            // question for the rest of the interview.
            dlog("Screen capture returned nil — telling the user instead of failing silently", tag: "SCREEN")
            let wasWatching = isWatchMode
            if wasWatching {
                isWatchMode = false
            }
            aiAnswer = """
            ⚠ Screen Recording permission is needed to read your screen.

            macOS blocked the capture, so there is nothing to answer from.\(wasWatching ? " Watch Screen has been switched off." : "")

            To fix it: System Settings → Privacy & Security → Screen & System Audio Recording → enable Replysis, then quit and reopen the app.

            Speech still works — ask by voice, or press SPACE.
            """
            stopThinkingUI(); return
        }

        dlog("Screen captured: \(imageData.count) bytes", tag: "SCREEN")
        let base64 = imageData.base64EncodedString()
        let resumeFacts = ResumeParser.extractFacts(resumeText)
        let provider = Self.providerLabel
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
        let currentTranscript = transcript  // pass what interviewer said too

        aiAnswer = "\(label)   \(ts)\n\n"
        showThinking = true
        var accumulated = ""; var tokenCount = 0
        let epoch = answerEpoch   // ignore stale callbacks if the answer is replaced

        NetworkClient.shared.streamScreenAnalysis(
            imageBase64: base64,
            resumeCtx: resumeFacts,
            provider: provider,
            transcript: currentTranscript,
            jobContext: jobContext,
            captureSource: lastCaptureSource,
            // When the picture went up while they were still speaking, the question carries
            // its id and not two hundred kilobytes. Nil falls back to sending the bytes.
            imageIds: usableImageIds(matching: Self.coarseSignature(imageData)),
            onToken: { [weak self] token in
                guard let self = self, self.answerEpoch == epoch else { return }
                accumulated += token; tokenCount += 1
                if tokenCount == 1 { self.showThinking = false }
                if tokenCount % 3 == 0 || token.contains("\n") {
                    self.aiAnswer = "\(label)   \(ts)\n\n\(accumulated)"
                }
            },
            onDone: { [weak self] in
                guard let self = self, self.answerEpoch == epoch else { return }
                // Screen answers use the ━━━-aware post-processor (keeps headers + code)
                let final = NetworkClient.postProcessScreen(accumulated)
                self.aiAnswer = "\(label)   \(ts)\n\n\(final)"
                PromptBuilder.shared.addToHistory(question: "Analyze what is on my screen", answer: final)
                self.appendToSessionLog(q: "[Screen Analysis]", a: final)
                self.stopThinkingUI()
                dlog("Screen analysis complete — \(final.count) chars", tag: "SCREEN")
                // The answer said part of the problem was off-screen. Watch for them to
                // scroll and read the rest by ourselves, rather than telling them to scroll
                // and then ignoring them for doing it.
                if final.contains(Self.scrollMarker) {
                    self.armScrollWatch(question: currentTranscript.isEmpty
                                          ? "Analyze what is on my screen" : currentTranscript,
                                        signature: Self.coarseSignature(imageData))
                }
            },
            onError: { [weak self] err in
                guard let self = self, self.answerEpoch == epoch else { return }
                dlog("Screen analysis error: \(err)", tag: "SCREEN")
                if err == "NO_CREDITS" {
                    // A screen read uses an answer too, so it says exactly the same thing.
                    self.showOutOfAnswers()
                } else if err.hasPrefix("SERVER_MSG:") {
                    self.aiAnswer = "⏳ " + String(err.dropFirst("SERVER_MSG:".count))
                } else if err.hasPrefix("RATE_LIMIT") {
                    self.aiAnswer = Self.rateLimitMessage(err)
                } else {
                    // NOT gated on watch mode any more. Errors were being swallowed there —
                    // exactly where they are least visible, because in watch mode nobody
                    // pressed anything and there is no obvious moment to blame. A question
                    // was asked, nothing appeared, and nothing said why. Reading a screen is
                    // also the most expensive request the app makes, so it is the first to be
                    // rate limited and the one most likely to fail.
                    self.aiAnswer = "⚠ Screen analysis error: \(err)"
                }
                self.stopThinkingUI()
            }
        )
    }

    /// What the last capture actually looked at, so the answer can name it. Vision answers
    /// about the wrong window are otherwise indistinguishable from bad answers about the
    /// right one.
    private(set) var lastCaptureSource = ""

    /// Longest side we upload. Vision models downscale until the SHORT side is 768px, so a
    /// 4K screenshot is read at ~1365x768 no matter what we send — the extra pixels are
    /// decoded, thrown away, and billed for. Capping here sends a fraction of the bytes for
    /// a byte-identical result on the model side.
    private static let visionMaxEdge: Double = 1536
    /// A single window arrives close to its real size and reads well at a 768 short edge.
    /// A whole monitor does not: 1920x1080 shrunk to fit 768 becomes 1365x768, and body
    /// text on a coding site goes from about fourteen pixels to ten — the edge of what a
    /// vision model reads rather than recalls. The evidence was an answer that named Two
    /// Sum, described the right approach, and never mentioned "Compile Error" in large red
    /// type across half the same screen. Two Sum is the most memorised problem there is, so
    /// a recalled answer and a read one look identical until the question is one the model
    /// has not seen before — which is every question that matters.
    ///
    /// A 1080p monitor is now sent at its own resolution rather than three quarters of it.
    private static let visionMaxShortEdgeFullScreen: Double = 1100
    private static let visionMaxLongEdgeFullScreen: Double  = 2560

    /// The area chosen with F7, in CoreGraphics screen coordinates, for the next capture.
    private var pendingRegionRect: CGRect?

    /// F7 — drag a box around one part of the screen and read only that. Windows has had
    /// this since before the Mac existed; a full-screen capture spends its pixel budget on
    /// the whole IDE when the question is about eight lines of it.
    func runRegionAnalysis() {
        guard !isProcessing && !isScreenAnalyzing else { return }
        guard session.isLoggedIn else {
            NotificationCenter.default.post(name: .showLogin, object: nil); return
        }
        dlog("Region capture: picker opened (F7)", tag: "SCREEN")
        RegionPicker.shared.pick { [weak self] rect in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard let rect = rect else {
                    dlog("Region capture: cancelled", tag: "SCREEN")
                    return
                }
                self.pendingRegionRect = rect
                self.answerIsBehavioral = false
                self.answerEpoch += 1
                self.capturingWholeScreen = true          // a region is cut from the display
                self.isScreenAnalyzing = true; self.isProcessing = true
                self.startBusyWatchdog(); self.updateMicUI()
                await self._doScreenCapture(label: "SELECTED AREA")
                self.pendingRegionRect = nil
            }
        }
    }

    /// Whether this capture should take the whole display rather than the front window.
    ///
    /// Targeting the frontmost window is right for an explicit hotkey — the user is looking
    /// at a thing and pressing a key about it. It is wrong for a mode left running, where
    /// "frontmost" becomes whichever window was clicked last, and the answer quietly
    /// describes the wrong thing. Watching a screen means the screen.
    private var capturingWholeScreen = false

    // ── A picture, sent before the question ───────────────────────────────────
    //
    // Sending the screenshot ahead was the larger half of the wait: 1,483ms to first word,
    // of which the model was 720ms and most of the rest was the image going up the wire.
    //
    // SCHEDULE — the owner's product decision, matching Windows and the privacy policy
    // (MainWindow.xaml.cs PreparedShotInterval / PreparedShotIntervalWhileMuted /
    // PrepareShotsAfterMicWithin): with screen answers on, one capture every 2 seconds while
    // listening; after the mic stops, one every 15 seconds, and nothing at all once it has
    // been off for 5 minutes. Only a screen that actually changed is uploaded; the server
    // keeps each for at most 90 seconds, hands it back once, and deletes it. Read Screen and
    // F8/F9 still capture on demand. An app left open with no interview captures nothing.
    static let preparedShotInterval: TimeInterval = 2
    static let preparedShotIntervalWhileMuted: TimeInterval = 15
    static let prepareShotsAfterMicWithin: TimeInterval = 5 * 60
    /// How old a prepared capture may be and still stand in for a fresh one: one interval
    /// plus the time a capture takes, so the latest tick is always usable.
    static let preparedShotMaxAge: TimeInterval = 2.5
    /// Most views one question carries, and the bytes they may total (two full-screen
    /// captures fit; the newest always goes first so it is never the one dropped).
    static let maxShotsPerQuestion = 3
    static let maxTotalShotBytes = 1_000 * 1024

    private var preparedImageId: String?
    private var preparedImageAt: Date = .distantPast
    private var preparedSignature: [UInt8] = []
    private var preparingScreenshot = false
    /// The server holds a cached image for ninety seconds; stay well inside that.
    private let preparedImageLifetime: TimeInterval = 60
    private var preparedShotData: Data?
    private var preparedShotDataAt: Date = .distantPast
    private var lastPreparedShotTickAt: Date = .distantPast
    private var lastMicLiveAt: Date = .distantPast
    /// The distinct views uploaded since the last question, oldest first. A problem that
    /// needs scrolling is read top to bottom; by the time they ask, both halves are here.
    private var recentShots: [(id: String, bytes: Int, at: Date)] = []
    private var lastKeptSignature: [UInt8] = []

    /// Driven from the always-running transcript poll, so it needs no timer of its own and
    /// cannot be left running by a mode change.
    private var preparingShotsActive = false

    private func tickPreparedShots() {
        // Said once per change, so the log shows WHEN the screen is being watched and when it
        // stops. The captures themselves only log when the picture changed.
        let allowed = screenPreparationAllowed
        if allowed != preparingShotsActive {
            preparingShotsActive = allowed
            dlog(allowed ? "SCREEN: preparing screenshots started (interview under way)"
                         : "SCREEN: preparing screenshots stopped (Setup, Past sessions or finished)", tag: "SCREEN")
        }
        guard allowed else { return }
        let now = Date()
        if isListening { lastMicLiveAt = now }
        guard isWatchMode, session.isLoggedIn, !preparingScreenshot, !isProcessing, !isScreenAnalyzing else { return }
        guard now.timeIntervalSince(lastMicLiveAt) <= Self.prepareShotsAfterMicWithin else { return }
        let interval = isListening ? Self.preparedShotInterval : Self.preparedShotIntervalWhileMuted
        guard now.timeIntervalSince(lastPreparedShotTickAt) >= interval else { return }
        lastPreparedShotTickAt = now
        Task { [weak self] in await self?.prepareScreenshotAhead() }
    }

    /// Capture now and upload, so the question only has to carry an id.
    ///
    /// Skips the upload entirely when the screen has not actually MOVED. A page with a live
    /// "2,332 Online" counter produces different bytes every two seconds, so comparing bytes
    /// re-sent a still screen constantly and doubled the token cost of every question. A
    /// coarse 16x16 sixteen-grey signature tells scrolling from a ticking counter.
    private func prepareScreenshotAhead() async {
        guard isWatchMode, session.isLoggedIn, !preparingScreenshot, screenPreparationAllowed else { return }
        guard Date().timeIntervalSince(lastMicLiveAt) <= Self.prepareShotsAfterMicWithin || isListening else { return }
        preparingScreenshot = true
        defer { preparingScreenshot = false }

        // Watching means the screen. Passed explicitly rather than through the shared
        // flag, so a timed capture can never flip an F8 window capture mid-flight.
        guard let image = await captureCGImage(wholeScreen: true) else { return }
        // COMPARE BEFORE ENCODING. Measured on this Mac: the 2-second prepare costs
        // 2.3-13.4% of a core with screen answers on and 1.1-2.2% with them off, and the
        // difference is almost entirely scaling and encoding a screen nobody changed.
        // The 16x16 signature comes straight off the capture, so a still screen stops here.
        let signature = Self.coarseSignature(image: image)
        if Self.signaturesMatch(signature, preparedSignature),
           Date().timeIntervalSince(preparedImageAt) < preparedImageLifetime, preparedImageId != nil {
            preparedShotDataAt = Date()   // the picture on hand still shows what is there
            return
        }
        guard let data = Self.encodeCapture(image, wholeScreen: true), !data.isEmpty else { return }
        preparedShotData = data
        preparedShotDataAt = Date()
        guard let id = await NetworkClient.shared.cacheScreenshot(imageBase64: data.base64EncodedString()) else {
            preparedImageId = nil; preparedSignature = []
            return
        }
        preparedImageId = id
        preparedImageAt = Date()
        preparedSignature = signature
        // A moved page is a new view; the same view re-uploaded only replaces the newest.
        let entry = (id: id, bytes: data.count, at: Date())
        recentShots.removeAll { Date().timeIntervalSince($0.at) >= preparedImageLifetime }
        if recentShots.isEmpty || !Self.signaturesMatch(signature, lastKeptSignature) {
            lastKeptSignature = signature
            recentShots.append(entry)
        } else {
            recentShots[recentShots.count - 1] = entry
        }
        while recentShots.count > Self.maxShotsPerQuestion { recentShots.removeFirst() }
        dlog("SCREEN: uploaded ahead of the question (id \(id.prefix(8)), \(recentShots.count) view\(recentShots.count == 1 ? "" : "s") held)", tag: "SCREEN")
    }

    /// The prepared capture when it is fresh enough to stand in for a new one.
    private func freshPreparedShot() -> Data? {
        guard let data = preparedShotData,
              Date().timeIntervalSince(preparedShotDataAt) <= Self.preparedShotMaxAge else { return nil }
        return data
    }

    /// Has the screen actually MOVED?
    ///
    /// Comparing signatures for exact equality is not enough, and measuring it is the only
    /// way to find that out: a live "2,332 Online" counter still shifts three of the 256
    /// cells, while scrolling the same page shifts eighty-one. Exact equality therefore
    /// counted the counter as a change and re-uploaded a still screen anyway — the very
    /// thing the signature exists to prevent, quietly doubling the token cost of every
    /// question while looking like it worked.
    ///
    /// A handful of cells is noise; a moved page is dozens. The gap between the two is wide,
    /// which is why the threshold can sit well clear of both.
    static func signaturesMatch(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard !a.isEmpty, a.count == b.count else { return false }
        var moved = 0
        for (x, y) in zip(a, b) where abs(Int(x) - Int(y)) > 1 {
            moved += 1
            if moved > 6 { return false }
        }
        return true
    }

    /// A 16x16, sixteen-level greyscale fingerprint. Coarse ON PURPOSE: fine enough that
    /// scrolling or a new panel changes it, blunt enough that a ticking counter does not.
    /// The most bytes a screenshot may occupy BEFORE base64.
    ///
    /// Measured against production rather than read from a document: /screen-cache accepts
    /// a raw 750 KB payload and rejects 1000 KB with a 413, so the ceiling is on the REQUEST
    /// body at about a megabyte. The backend's documented rule is two megabytes per image —
    /// that limit is real but never reached, because a smaller request-size cap fires first
    /// and base64 inflates everything by a third on the way. 700 KB raw is ~930 KB encoded,
    /// which leaves room for the prompt and the JSON around it.
    static let screenshotByteBudget = 700_000

    /// Encode a screenshot to fit the budget, giving up as little legibility as possible.
    ///
    /// PNG first, because a screenshot is text on flat colour — the exact case JPEG is worst
    /// at, and its ringing around glyph edges is the difference between the model reading
    /// "l" and reading "1", which in code is a wrong answer.
    ///
    /// When PNG does not fit, quality is given up BEFORE resolution. A high-quality JPEG of
    /// the whole screen keeps every character where it was; a smaller PNG moves the text
    /// below the size a vision model reads reliably, which is the failure the larger capture
    /// was introduced to fix. Shrinking is the last resort, not the first.
    static func encodeWithinBudget(_ rep: NSBitmapImageRep, width: Int, height: Int) -> Data? {
        if let png = rep.representation(using: .png, properties: [:]), png.count <= screenshotByteBudget {
            dlog("Screen capture: \(png.count) bytes PNG \(width)x\(height)", tag: "SCREEN")
            return png
        }
        for quality in [0.92, 0.85, 0.75, 0.6] {
            guard let jpg = rep.representation(using: .jpeg,
                                               properties: [.compressionFactor: quality]) else { continue }
            if jpg.count <= screenshotByteBudget {
                dlog("Screen capture: \(jpg.count) bytes JPEG q\(quality) \(width)x\(height) — PNG exceeded the budget", tag: "SCREEN")
                return jpg
            }
        }
        let last = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.5])
        dlog("Screen capture: \(last?.count ?? 0) bytes JPEG q0.5 \(width)x\(height) — still over budget, sending anyway", tag: "SCREEN")
        return last
    }

    static func coarseSignature(_ jpeg: Data) -> [UInt8] {
        guard let src = NSBitmapImageRep(data: jpeg)?.cgImage else { return [] }
        return coarseSignature(image: src)
    }

    static func coarseSignature(image src: CGImage) -> [UInt8] {
        let n = 16
        var pixels = [UInt8](repeating: 0, count: n * n)
        guard let ctx = CGContext(data: &pixels, width: n, height: n, bitsPerComponent: 8,
                                  bytesPerRow: n, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: n, height: n))
        return pixels.map { $0 >> 4 }   // sixteen grey levels
    }

    /// The prepared id, if it is still fresh enough for the server to honour.
    // ── Answer again once they have scrolled ──────────────────────────────────
    //
    // The first version asked the candidate to scroll and then ignored them for doing it,
    // so they had to work out for themselves that they should ask the same question twice.
    // Being told to scroll and then abandoned is worse than not being told.
    private var scrollWatchUntil: Date?
    private var scrollWatchSignature: [UInt8] = []
    private var scrollWatchTimer: Timer?
    private var scrollWatchQuestion = ""
    /// The marker the screen prompt emits when the statement is cut off.
    static let scrollMarker = "━━━ SCROLL ━━━"

    /// Watch for the screen to move, and answer once more when it does.
    ///
    /// ONCE ONLY and inside twenty-five seconds. A standing re-answer would fire on every
    /// scroll for the rest of the interview and spend a credit each time; twenty-five
    /// seconds is long enough to read and scroll, short enough that it cannot follow them
    /// into the next question.
    private func armScrollWatch(question: String, signature: [UInt8]) {
        guard isWatchMode else { return }
        scrollWatchUntil = Date().addingTimeInterval(25)
        scrollWatchSignature = signature
        scrollWatchQuestion = question
        scrollWatchTimer?.invalidate()
        scrollWatchTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.checkScrollWatch() }
        }
        dlog("SCREEN: answer said something was cut off — watching for a scroll", tag: "SCREEN")
    }

    private func disarmScrollWatch() {
        scrollWatchTimer?.invalidate(); scrollWatchTimer = nil
        scrollWatchUntil = nil
        scrollWatchSignature = []
        scrollWatchQuestion = ""
    }

    private func checkScrollWatch() async {
        guard let until = scrollWatchUntil else { disarmScrollWatch(); return }
        guard Date() < until else {
            dlog("SCREEN: nothing scrolled within the window — standing down", tag: "SCREEN")
            disarmScrollWatch(); return
        }
        // Never while an answer is streaming, and never while they are speaking: replacing
        // an answer mid-read, or mid-sentence, is worse than the gap it fills.
        guard !isProcessing, !isScreenAnalyzing else { return }
        guard Date().timeIntervalSince(lastSpeechHeardAt) > 1.5 else { return }

        capturingWholeScreen = true
        guard let data = await captureScreen(), !data.isEmpty else { return }
        let now = Self.coarseSignature(data)
        guard !Self.signaturesMatch(now, scrollWatchSignature) else { return }   // nothing moved

        let question = scrollWatchQuestion
        disarmScrollWatch()   // once only
        dlog("SCREEN: they scrolled — answering the same question again", tag: "SCREEN")
        thinkingText = "You scrolled — reading the rest…"
        answerEpoch += 1
        capturingWholeScreen = true
        isScreenAnalyzing = true; isProcessing = true; startBusyWatchdog(); updateMicUI()
        transcript = question
        Task { await _doScreenCapture(label: "AFTER SCROLL") }
    }

    /// The prepared ids, but ONLY if the newest still shows the screen being asked about.
    ///
    /// Matching the signature is what makes this safe. Sending an id prepared moments ago
    /// alongside a screen that has since scrolled would answer a picture the candidate is no
    /// longer looking at — a wrong answer that reads as a confident one. When they differ,
    /// the fresh bytes go inline and the only thing lost is the head start.
    ///
    /// With the newest, the OLDEST view held is sent too when it fits: someone reading a
    /// problem scrolls from the top down, so that is the statement they scrolled past.
    private func usableImageIds(matching signature: [UInt8]) -> [String]? {
        guard let id = preparedImageId,
              Date().timeIntervalSince(preparedImageAt) < preparedImageLifetime,
              Self.signaturesMatch(signature, preparedSignature) else { return nil }
        var ids = [id]
        var total = recentShots.last?.bytes ?? 0
        if recentShots.count > 1, let oldest = recentShots.first, oldest.id != id,
           Date().timeIntervalSince(oldest.at) < preparedImageLifetime,
           total + oldest.bytes <= Self.maxTotalShotBytes {
            ids.insert(oldest.id, at: 0)   // top of the page first
            total += oldest.bytes
        }
        // The server returns a cached image EXACTLY ONCE, so every id sent is spent.
        preparedImageId = nil
        preparedSignature = []
        recentShots.removeAll()
        lastKeptSignature = []
        dlog("SCREEN: question carries \(ids.count) prepared view\(ids.count == 1 ? "" : "s") (\(total / 1024) KB)", tag: "SCREEN")
        return ids
    }

    private func captureScreen(wholeScreen: Bool? = nil) async -> Data? {
        guard let cgImage = await captureCGImage(wholeScreen: wholeScreen) else { return nil }
        return Self.encodeCapture(cgImage, wholeScreen: wholeScreen ?? capturingWholeScreen)
    }

    /// The raw capture, before any scaling or encoding.
    private func captureCGImage(wholeScreen: Bool? = nil) async -> CGImage? {
        let wholeScreenCapture = wholeScreen ?? capturingWholeScreen
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

            // Prefer the FRONTMOST window over the whole display. A full-screen grab spends
            // most of its 768px budget on desktop, dock and menu bar; the coding problem or
            // shared screen being asked about gets whatever is left. One window puts the
            // pixels where the question actually is. Falls back to the display when there is
            // no sensible foreground window (e.g. only the desktop is showing).
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let candidate = wholeScreenCapture ? nil : content.windows.first { w in
                guard w.isOnScreen, w.frame.width > 200, w.frame.height > 200 else { return false }
                guard let app = w.owningApplication else { return false }
                // Never target ourselves — the user wants what is BEHIND this app.
                guard app.processID != ownPID else { return false }
                let layerIsNormal = w.windowLayer == 0          // excludes dock, menu bar, overlays
                return layerIsNormal
            }

            let cgImage: CGImage
            let config = SCStreamConfiguration()
            config.showsCursor = false

            if let win = candidate {
                config.width  = Int(win.frame.width)
                config.height = Int(win.frame.height)
                let filter = SCContentFilter(desktopIndependentWindow: win)
                cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                let owner = win.owningApplication?.applicationName ?? "window"
                let title = win.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                lastCaptureSource = title.isEmpty ? owner : "\(owner) — \(title)"
            } else {
                guard let display = content.displays.first else { return nil }
                config.width  = display.width
                config.height = display.height
                // EXCLUDE our own app from the capture instead of hiding the window first.
                // Hiding and waiting for the compositor makes the app visibly blink on every
                // single capture; exclusion is invisible and has no wait at all.
                let ourApp = content.applications.first { $0.processID == ownPID }
                let filter = SCContentFilter(display: display,
                                             excludingApplications: ourApp.map { [$0] } ?? [],
                                             exceptingWindows: [])
                let shot = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                if let region = pendingRegionRect {
                    // The capture is in pixels and the selection is in points; on a Retina
                    // display those differ by the backing scale, so convert before cropping.
                    let scale = Double(shot.width) / Double(max(display.width, 1))
                    let bounds = CGDisplayBounds(display.displayID)
                    let local = CGRect(x: (region.origin.x - bounds.origin.x) * scale,
                                       y: (region.origin.y - bounds.origin.y) * scale,
                                       width: region.width * scale, height: region.height * scale)
                    let clamped = local.intersection(CGRect(x: 0, y: 0, width: shot.width, height: shot.height))
                    if let cropped = clamped.isNull || clamped.width < 8 || clamped.height < 8
                        ? nil : shot.cropping(to: clamped) {
                        cgImage = cropped
                        lastCaptureSource = "selected area"
                        dlog("SCREEN: region \(Int(clamped.width))x\(Int(clamped.height)) px", tag: "SCREEN")
                    } else {
                        cgImage = shot
                        lastCaptureSource = "full screen"
                    }
                } else {
                    cgImage = shot
                    lastCaptureSource = "full screen"
                }
            }

            return cgImage
        } catch {
            dlog("Screen capture failed: \(error)", tag: "SCREEN")
            return nil
        }
    }

    /// Scale and encode a capture. Split out so a prepared shot can compare the picture
    /// BEFORE paying for the encode: measured on this Mac, the 2-second prepare costs
    /// 2.3-13.4% of a core with screen answers on against 1.1-2.2% with them off, and
    /// almost all of that is encoding a screen that has not changed.
    static func encodeCapture(_ cgImage: CGImage, wholeScreen wholeScreenCapture: Bool) -> Data? {
            // Downscale by the LONGEST edge (the old code only ever considered width, so a
            // tall narrow window came through far larger than intended).
            let origW = Double(cgImage.width), origH = Double(cgImage.height)
            guard origW > 0, origH > 0 else { return nil }
            // Never upscale, and cap the SHORT edge too — the short edge is what the model
            // downscales to, so it is the one that decides whether text survives.
            let shortEdge = min(origW, origH), longEdge = max(origW, origH)
            let scale: Double
            if wholeScreenCapture {
                scale = min(1.0, Self.visionMaxShortEdgeFullScreen / shortEdge,
                                 Self.visionMaxLongEdgeFullScreen / longEdge)
            } else {
                scale = min(1.0, Self.visionMaxEdge / longEdge)
            }
            let newW  = max(1, Int((origW * scale).rounded()))
            let newH  = max(1, Int((origH * scale).rounded()))

            guard let ctx = CGContext(
                data: nil, width: newW, height: newH,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return nil }
            ctx.interpolationQuality = .high
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: newW, height: newH))
            guard let scaled = ctx.makeImage() else { return nil }

            // PNG, not JPEG. A screenshot is text on flat colour — the exact case JPEG is
            // worst at. Its ringing around glyph edges is the difference between the model
            // reading "l" and reading "1", which in code is a wrong answer.
            let rep  = NSBitmapImageRep(cgImage: scaled)
            return Self.encodeWithinBudget(rep, width: newW, height: newH)
    }

    // MARK: - Transcript Polling
    private func startTranscriptTimer() {
        startTypingTimer()
        guard transcriptTimer == nil else { return }
        transcriptTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateTranscript() }
        }
    }

    private var transcriptLogTick = 0
    private var autoBlockLogTick = 0
    private var lastEngineReady = false
    private var lastTokenRenewalCheckAt = Date.distantPast
    private var lastTokenRenewalAt = Date.distantPast
    /// Set while the "live transcription is paused" notice is on screen, with what the app was
    /// doing before it appeared. Without these, the notice outlived the failure: see the
    /// recovery in updateTranscript and handleSpeechKeyError.
    private var keyErrorNoticeShowing = false
    private var wasListeningBeforeKeyError = false
    private func updateTranscript() {
        tickListeningProblem()
        tickPreparedShots()
        checkAudioSourceTip()
        renewSpeechTokenIfExpiring()
        // THE ROOM IS NOT QUIET ANY MORE. The microphone is shut, but the system-audio tap
        // keeps running, so the interviewer starting to talk in Zoom is visible even now.
        // Armed before a call that starts ten minutes late, the app stopped after three
        // minutes and stayed stopped — silently, until somebody pressed Space, which is the
        // one thing an automatic mode promises nobody has to do. Resuming only on REAL audio
        // keeps the saving the stop exists for: a genuinely empty room stays quiet.
        //
        // It lives here, before the guard below, because stopForIdle() invalidates the meter
        // timer — a check inside the meter tick could never fire once the thing it recovers
        // from had happened. This timer runs for the life of the app.
        if stoppedForIdle, autoModeEnabled, appStep == .interview, session.isLoggedIn, !isProcessing, engine.isRunning {
            if #available(macOS 14.2, *), SystemAudioTapper.shared.secondsSinceAudio < 2 {
                dlog("METER: audio in the room again — listening resumes on its own", tag: "METER")
                stoppedForIdle = false
                isMuted = false; isListening = true
                justStartedListening = true; listenStartTicks = 0
                resetAutoTurnState()
                transcript = ""          // the answer on screen stays; only the heard text resets
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    self?.engine.clearLatestTxt()
                    self?.engine.writeResetFlag()
                    self?.engine.deletePauseFlag()
                }
                startListeningMeter()
                showListeningNotice("LISTENING AGAIN")
                updateMicUI()
            }
        }
        // Transcription can drop mid-interview — network, session timeout, engine crash —
        // and an automatic mode then quietly answers nothing while the header still looks
        // armed. This poll already runs; use it to notice the flip in BOTH directions, so
        // the drop is visible and the recovery clears itself without the user doing anything.
        if engine.isReady != lastEngineReady {
            let cameBack = engine.isReady && !lastEngineReady
            lastEngineReady = engine.isReady
            dlog("Transcription live=\(engine.isReady)", tag: "AUTO")
            // Coming back from an outage starts a clean slate. The words the engine
            // produces first are built from audio captured while transcription was down,
            // and answering those is answering something nobody asked.
            if cameBack {
                transcript = ""
                resetAutoTurnState()
                lastRawTranscript = ""
            }
            if autoModeEnabled && isListening {
                aiAnswerHint = engine.isReady
                    ? idleHintForCurrentMode
                    : "⚠ Reconnecting to the speech service — nothing is being heard right now."
            }
            // THE NOTICE MUST NOT OUTLIVE THE FAILURE. Measured 2026-09-16: the speech key was
            // rejected at 14:31, the app re-fetched a good key and was ONLINE again at 14:41 —
            // and the "live transcription is paused" notice stayed on screen for five hours,
            // muted, while transcription worked. The line above is the only thing that clears
            // the warning and it is gated on isListening, which handleSpeechKeyError had just
            // set to false: a recovery behind the flag its own failure handler cleared.
            if engine.isReady, keyErrorNoticeShowing {
                keyErrorNoticeShowing = false
                if aiAnswer.hasPrefix("⚠ Live transcription is paused") { aiAnswer = "" }
                dlog("AUTO: the speech service is back — clearing the paused notice", tag: "AUTO")
                if wasListeningBeforeKeyError, session.isLoggedIn, !isProcessing {
                    wasListeningBeforeKeyError = false
                    stoppedForIdle = false
                    isMuted = false; isListening = true
                    justStartedListening = true; listenStartTicks = 0
                    resetAutoTurnState()
                    transcript = ""
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        self?.engine.clearLatestTxt()
                        self?.engine.writeResetFlag()
                        self?.engine.deletePauseFlag()
                    }
                    startListeningMeter()
                    showListeningNotice("TRANSCRIPTION IS BACK")
                    aiAnswerHint = idleHintForCurrentMode
                } else {
                    aiAnswerHint = "Transcription is back. Press SPACE to listen."
                }
            }
            updateMicUI()
        }
        // Keep reading the transcript even while an answer is streaming: in an automatic
        // mode the app stays open, and a question that continues must still be seen.
        guard session.isLoggedIn, isListening || (autoModeEnabled && isProcessing) else { return }
        if justStartedListening {
            listenStartTicks += 1; transcript = ""
            if listenStartTicks >= suppressTickCount {
                justStartedListening = false
                dlog("Transcript: suppression done, now reading latest.txt", tag: "TX")
            }
            return
        }
        let raw = engine.readLatestTxt()
        if raw != lastRawTranscript {
            // The gap since the last words is this speaker's own pace. Anything over two
            // seconds is a turn boundary rather than a pause inside one, so it is not
            // allowed to stretch the wait.
            let gap = Date().timeIntervalSince(lastSpeechHeardAt)
            if gap <= 2.0 && gap > longestMidTurnGap { longestMidTurnGap = gap }
            lastRawTranscript = raw
            lastSpeechHeardAt = Date()   // somebody is speaking — the room is not empty
            heardAnythingThisSession = true
            heardEverThisRun = true
            if pendingSpeechStartedAt == nil, !lastAnsweredQuestion.isEmpty,
               !remainingSpeech(raw).isEmpty {
                pendingSpeechStartedAt = Date()
                pendingSpeechBeganWhileLoading = isProcessing || showThinking
                pendingSpeechBeganBeforeAnswer = pendingSpeechBeganWhileLoading
                    || Date().timeIntervalSince(answerSettledAt) < answerReadGrace
            }
            // THE QUESTION IS OVER AND THE CANDIDATE HAS STARTED TALKING. The end of speech is
            // reported only when the room goes quiet, and a candidate saying "good question,
            // let me think" or starting their answer keeps it from going quiet, so the answer
            // waited for them to stop. See AutoTurnDetector.questionBeforeCandidateTail. Not
            // while an earlier answer is still coming: speech then is joined to that question
            // (handleUtteranceEnd), and answering it alone here is the bug that fixed.
            if autoModeEnabled, isListening, micCaptureActive, !isProcessing, !isScreenAnalyzing,
               !autoTurnSubmitting, engine.isReady,
               !(pendingSpeechStartedAt != nil && pendingSpeechBeganBeforeAnswer),
               let question = AutoTurnDetector.questionBeforeCandidateTail(remainingSpeech(raw)) {
                commitBeforeCandidateTail(question)
            }
            // More arrived, so the ending was not the end. The new speech forms its own
            // turn and will be classified on its own utterance-end.
            if unclearDeadline != nil {
                // Past the ceiling, more speech is no longer evidence of a pause — it is
                // someone repeating themselves because nothing has answered them. Commit
                // what we have rather than resetting the wait again.
                if Date().timeIntervalSince(unclearChainStartedAt) >= maxUnclearChain {
                    let pending = unclearPendingText.isEmpty ? raw : unclearPendingText
                    dlog("AUTO: waited \(Int(maxUnclearChain))s without a clear ending — answering anyway", tag: "AUTO")
                    unclearDeadline = nil; unclearPendingText = ""; unclearChainStartedAt = .distantPast; unclearChainStartedAt = .distantPast
                    if !pending.isEmpty { commitAutomaticTurn(pending) }
                } else {
                    // RE-ARM, never abandon. Clearing the pending text here threw the
                    // question away: "Okay. What is a JPA" was held, the "?" landed 20ms
                    // later and counted as "more speech", the pending text was deleted —
                    // and no further utterance-end came, because the speaker had finished.
                    // The question was destroyed while waiting to be asked, and the app sat
                    // polling that same line forever while the owner waited.
                    //
                    // More speech means the answer is not ready YET. It never means there is
                    // no question. Keep the latest text, restart the short wait, and leave
                    // the chain anchor alone so the ceiling above still guarantees a commit.
                    let latest = remainingSpeech(raw)
                    if latest.isEmpty {
                        unclearDeadline = nil; unclearPendingText = ""; unclearChainStartedAt = .distantPast
                    } else {
                    // It has BECOME a question. Every new word restarted the wait, so context
                    // followed by "How would you debug a slow service?" was answered 4.4s after
                    // the speaker stopped. A finished question needs no more waiting.
                    if AutoTurnDetector.classifyTurnEnding(latest) == .finished,
                       AutoTurnDetector.isLikelyCompleteQuestion(AutoTurnDetector.lastSentence(latest),
                                                                 requireInterrogative: true) {
                        unclearDeadline = nil; unclearPendingText = ""; unclearChainStartedAt = .distantPast
                        commitAutomaticTurn(latest)
                    } else {
                        unclearPendingText = latest
                        unclearDeadline = Date().addingTimeInterval(unclearSilence)
                        dlog("AUTO: more speech arrived — still holding '\(latest.suffix(40))'", tag: "AUTO")
                    }
                    }
                }
            }
        }
        // Nothing more came, so the unclear ending really was the end — unless the words now
        // held plainly stop mid-sentence. Measured: "What is Java? Where" was answered as it
        // stood, because this committed whatever the wait was holding without looking at it
        // again, and "Where" had arrived since the wait began. The ceiling above still
        // guarantees an answer, so waiting on a dangling word cannot hang.
        if let deadline = unclearDeadline, Date() >= deadline {
            let pending = unclearPendingText
            if !pending.isEmpty,
               AutoTurnDetector.classifyTurnEnding(pending) == .unfinished,
               Date().timeIntervalSince(unclearChainStartedAt) < maxUnclearChain {
                unclearDeadline = Date().addingTimeInterval(unclearSilence)
                dlog("AUTO: the wait ran out mid-sentence — still waiting: '\(pending.suffix(40))'", tag: "AUTO")
            } else {
                unclearDeadline = nil; unclearPendingText = ""; unclearChainStartedAt = .distantPast
                if !pending.isEmpty { commitAutomaticTurn(pending) }
            }
        }
        // Context that never became a question. See the hold in handleUtteranceEnd. Stepped past
        // only if nothing was said since; if something was, the next end of speech judges it all.
        if let held = contextHeldSince, Date().timeIntervalSince(held) >= contextHold {
            contextHeldSince = nil
            if lastSpeechHeardAt <= held {
                consumedPrefix = raw
                pendingSpeechStartedAt = nil
                dlog("AUTO: held context never became a question — stepping past it", tag: "AUTO")
            }
        }
        let text = remainingSpeech(raw)
        transcriptLogTick += 1
        // Log every ~3 seconds (every 20 ticks at 150ms)
        if transcriptLogTick % 20 == 0 {
            dlog("Transcript poll: latest.txt='\(text.prefix(60))' engineRunning=\(engine.isRunning)", tag: "TX")
        }
        if text != transcript {
            dlog("Transcript updated: '\(text.prefix(80))'", tag: "TX")
            transcript = text
        }
        // AUTO MODE: the same polled text that drives the on-screen transcript also tells
        // us when the interviewer stopped talking. No extra timer, no extra file read.
        // engine.isReady is the ONLY honest signal that transcription is genuinely live.
        // Without this an auto mode keeps submitting turns into a dropped session: the user
        // speaks into nothing, gets no answer and no error, and it recovers silently later
        // so it can never be reproduced.
        if autoModeEnabled {
            // Log WHY a turn is being skipped. "Sometimes it doesn't answer" is impossible
            // to diagnose when every rejection is silent, and these are the four states
            // that block a submission.
            if autoBlockLogTick % 20 == 0 {
                if isProcessing || isScreenAnalyzing {
                    dlog("AUTO: blocked — busy (processing=\(isProcessing) capturing=\(isScreenAnalyzing))", tag: "AUTO")
                } else if !engine.isReady {
                    dlog("AUTO: blocked — transcription not live (engine.isReady=false)", tag: "AUTO")
                }
            }
            autoBlockLogTick += 1
        }
        // NOTE: turns are driven by handleUtteranceEnd(), from the recogniser's own
        // acoustic silence detection. No text-timing fallback runs here: two independent
        // triggers would race and double-answer, and the text one is the guess we removed.
    }

    /// The recogniser reported real acoustic silence — the speaker has finished.
    ///
    /// This replaces the text-timing heuristics entirely: no counting full stops, no
    /// waiting for the transcript to stop changing, no guessing whether a pause was a
    /// breath or an ending. The only judgement left is whether what was said is worth
    /// answering, which is a question about MEANING and genuinely does belong in text.
    /// The question we last answered, and when — so a slow speaker who pauses mid-sentence
    /// gets their FULL question answered rather than the first half of it.
    private var lastAnsweredQuestion = ""
    /// The answer we last put on screen, so speech that echoes it can be recognised.
    private var lastAnsweredAnswer = ""
    private var lastAnsweredAt = Date.distantPast
    /// How long after an answer a further utterance still counts as the same question.
    private let continuationWindow: TimeInterval = 20
    /// How soon the CONTINUATION has to START to count as one, measured from the answer it
    /// would be glued onto. Windows requires 4s (AutoTurnRules), "so the next question's
    /// opening words are not glued onto the previous question". Mac only bounded the whole
    /// chain at 20s, and a soak run showed exactly the failure Windows names: "What is a
    /// load balancer?", asked eleven seconds after TCP was answered, came back as
    /// "What is TCP? What is a load balancer?" — one answer covering two questions, and the
    /// second question's own answer never given.
    private let continuationStartWindow: TimeInterval = 4
    /// When the CURRENT run of continuations began.
    ///
    /// The window used to be measured from the last answer, and every merge produced a new
    /// answer — so the window reset itself and never closed. With someone talking nearby,
    /// each short fragment merged, re-answered, and extended the chain again: one API call
    /// and one credit per fragment, and a "question" that grew into a paragraph of noise
    /// before the service finally rejected it. Anchoring to the START of the chain gives it
    /// an end.
    /// An ending that could go either way, waiting to see if more arrives.
    private var unclearPendingText = ""
    private var unclearDeadline: Date?
    /// When the current run of unclear endings began. Anchors the ceiling below.
    private var unclearChainStartedAt = Date.distantPast
    /// The longest anyone waits without an answer, however the endings are classified.
    private let maxUnclearChain: TimeInterval = 4.0
    /// The longest gap this speaker leaves MID-question, so the wait can follow their pace
    /// rather than a number tuned on somebody else. Capped while collecting: a gap longer
    /// than two seconds is a turn boundary, not a pause inside one.
    private var longestMidTurnGap: TimeInterval = 0
    private let unclearSilence: TimeInterval = 0.82
    private let maxUnclearSilence: TimeInterval = 1.25

    /// When the recogniser last said the speaker stopped. The user's wait starts here, not
    /// when the request goes out — everything before it is time they are already spending.
    var lastUtteranceEndAt = Date.distantPast

    private var continuationChainStartedAt = Date.distantPast
    private var continuationCount = 0
    /// A question that has genuinely been split by a pause takes one or two more pieces to
    /// finish, never five, and never runs to a paragraph.
    private let maxContinuations = 2
    private let maxContinuationWords = 60
    /// A tail with no joining word ("C2C or W2 or full time.") follows its question within
    /// seconds — the interviewer paused mid-sentence. Measured: fifteen seconds after an answer,
    /// "Our team runs about 40 microservices on Kubernetes." was joined onto the question before
    /// it, and the question it was really introducing was then answered without it. Speech that
    /// began before the answer was up is not bound by this; it is the same question by
    /// definition.
    private let tailWindow: TimeInterval = 6
    /// Speech that began before its answer was on screen is the interviewer's question going
    /// on, not a tail, so it may run longer. maxContinuations still ends the chain, which is
    /// what stops talk in the room growing a question without limit.
    private let maxGapMergeWords = 120
    /// When the current answer finished arriving.
    private var answerSettledAt = Date.distantPast

    // MARK: - An answer that never arrives
    //
    // While the app is "busy" it answers nothing automatically — every path is gated on
    // isProcessing and isScreenAnalyzing — and the only thing that clears those is a request
    // calling back. URLSession gives up after 60s idle or 300s total, so a stalled request
    // can leave the app deaf for minutes with nothing on screen saying why. In an interview
    // that is indistinguishable from the app being broken. No real answer takes this long:
    // spoken answers finish in about a second, screen answers in ten.
    private var busyWatchdog: Timer?
    private var busyStartedAt = Date.distantPast
    private let busyLimit: TimeInterval = 45

    private func startBusyWatchdog() {
        busyStartedAt = Date()
        busyWatchdog?.invalidate()
        busyWatchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.checkBusyWatchdog() }
        }
    }

    private func checkBusyWatchdog() {
        guard isProcessing || isScreenAnalyzing else {
            busyWatchdog?.invalidate(); busyWatchdog = nil
            return
        }
        guard Date().timeIntervalSince(busyStartedAt) > busyLimit else { return }
        dlog("WATCHDOG: \(Int(busyLimit))s with no answer — releasing so listening resumes", tag: "AUTO")
        if Self.answerBody(aiAnswer).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            aiAnswer = "⚠ No answer came back — the connection stalled. Ask again."
        }
        stopThinkingUI()
    }
    /// Speech that starts this soon after an answer lands began before anyone could read it.
    /// Was 1.5s, and measured too short: the second half of "What is the difference between
    /// ... an abstract class and an interface?" began 1.76s after a 0.45s answer and was
    /// answered on its own. Nobody reads an answer and gets a follow-up out of the
    /// interviewer in three seconds.
    private let answerReadGrace: TimeInterval = 3.0
    /// When the speech we have not answered yet began, and whether its answer was still
    /// loading at that moment. Cleared whenever that speech is answered or stepped past.
    private var pendingSpeechStartedAt: Date?
    private var pendingSpeechBeganBeforeAnswer = false
    /// Stricter than the flag above: the answer was still LOADING when these words began, not
    /// merely seconds old. Nobody can read aloud an answer that is not on screen yet, so
    /// read-back detection must not be applied to this speech — it is the interviewer finishing
    /// their question. Measured: "an abstract class and an interface?" was thrown away as our
    /// own answer being read back, because the answer to the half-question it followed was
    /// about abstract classes and interfaces.
    private var pendingSpeechBeganWhileLoading = false
    /// True only while the speech that began during the load is still the unanswered speech.
    private var speechBeganWhileLoading: Bool {
        pendingSpeechStartedAt != nil && pendingSpeechBeganWhileLoading
    }
    /// Between deciding a turn is over and taking the snapshot of what to answer (the 150ms
    /// drain). Two triggers now exist — the recogniser's end of speech and a question
    /// followed by the candidate talking — and both firing inside that window would answer
    /// the same question twice.
    private var autoTurnSubmitting = false
    /// When finished speech that asks nothing began being held for a question to follow it.
    private var contextHeldSince: Date?
    /// How long context waits for its question before it is stepped past.
    private let contextHold: TimeInterval = 4

    /// The part of latest.txt that has ALREADY been answered.
    ///
    /// The mic deliberately stays open while an answer streams, so the next question is
    /// often already being spoken when the previous answer lands. Clearing the file at that
    /// moment — which is what re-arming used to do unconditionally — cut that question in
    /// half: the surviving tail no longer read as a question, so nothing was answered at
    /// all and the user sat in silence in front of the interviewer. Subtracting a remembered
    /// prefix keeps every word instead, and still gives each turn a clean slate.
    private var consumedPrefix = ""
    /// Consecutive utterance-ends that yielded no new speech. Two means the consumed prefix
    /// has drifted out of step with the engine's file, not that nobody is talking.
    private var emptyTurnStreak = 0

    /// What has been said that we have NOT already answered.
    ///
    /// Falls back to the whole transcript whenever the prefix stops matching — the
    /// recogniser revises its earlier words, and the engine clears the file on reset — so a
    /// stale prefix can never subtract text that is actually new.
    private func remainingSpeech(_ raw: String) -> String {
        let full = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let consumed = consumedPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !consumed.isEmpty else { return full }
        guard full.hasPrefix(consumed) else {
            // Resynchronise by words rather than giving up. Returning the whole file here sent
            // an already-answered question back through as new speech: measured, a question and
            // a stall from a minute earlier were joined onto the next question and re-answered.
            let fresh = AutoTurnDetector.newSpeech(full: full, consumed: consumed)
            dlog("TX: the recogniser rewrote text already answered — keeping the new part: '\(fresh.prefix(60))'", tag: "TX")
            consumedPrefix = fresh.count < full.count ? String(full.dropLast(fresh.count)) : ""
            return fresh.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(full.dropFirst(consumed.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Forget the previous turn completely.
    ///
    /// Continuation merging, the duplicate guard and the consumed prefix all describe ONE
    /// stretch of listening. Left standing across a mode change or a new session they get
    /// applied to speech they have nothing to do with — the first thing said in Practice
    /// Auto was being glued onto a question asked in Interview Auto.
    /// Pieces of a question set aside as filler or as an echo, kept for a moment in case the rest
    /// of the sentence follows. See AutoTurnDetector.question(afterCarrying:then:).
    private var carriedFragments: [(text: String, at: Date)] = []
    private let fragmentCarrySeconds: TimeInterval = 10
    /// The start of a question put back on the front of what is being submitted.
    private var carriedPrefixForTurn = ""
    private var carriedPrefixAt = Date.distantPast

    private func carryFragment(_ text: String) {
        guard AutoTurnDetector.isQuestionOpening(text) else { return }
        carriedFragments.append((text, Date()))
        if carriedFragments.count > 4 { carriedFragments.removeFirst(carriedFragments.count - 4) }
        dlog("AUTO: keeping '\(text.prefix(30))' for a moment, in case the rest of the question follows", tag: "AUTO")
    }

    private func resetAutoTurnState() {
        carriedFragments = []; carriedPrefixForTurn = ""
        // Cleared here too: a mode change or a new session must never inherit a latch that
        // blocks answering.
        autoTurnSubmitting = false
        autoDetector.forgetLastAnswered()
        lastAnsweredQuestion = ""
        lastAnsweredAt = .distantPast
        consumedPrefix = ""
        pendingSpeechStartedAt = nil
        contextHeldSince = nil
        continuationChainStartedAt = .distantPast
        continuationCount = 0
        unclearDeadline = nil; unclearPendingText = ""; unclearChainStartedAt = .distantPast
        longestMidTurnGap = 0
    }

    private func handleUtteranceEnd() {
        guard autoModeEnabled, isListening, !isScreenAnalyzing, !autoTurnSubmitting, engine.isReady else { return }
        // Stamped here, before any of the deciding, because this is the moment the user
        // stopped talking and started waiting.
        lastUtteranceEndAt = Date()
        let rawNow = engine.readLatestTxt()
        var text = remainingSpeech(rawNow)
        // A speaker finished, the recogniser has text, and we can see nothing new in it.
        //
        // remainingSpeech subtracts a stored prefix from a file the engine keeps appending
        // to, and that arithmetic only holds while the file grows cleanly. Recognisers
        // REVISE — a final transcript is not always the partial with words added — and the
        // file is only reset after a turn when nothing was left over. Once the prefix covers
        // everything, every later question subtracts to nothing and is dropped HERE, with no
        // log line and no answer: the app looks alive, the mic is open, and it has quietly
        // stopped listening. That is the "it stops answering after a few questions".
        //
        // Two in a row is not a coincidence, it is a desync. Resynchronise instead of
        // returning a third time: drop the prefix, clear the engine's file, and let the next
        // sentence be heard whole.
        if text.isEmpty {
            emptyTurnStreak += 1
            if emptyTurnStreak >= 2, !rawNow.isEmpty {
                dlog("AUTO: \(emptyTurnStreak) turns produced no new speech from a \(rawNow.count)-char transcript — resynchronising", tag: "AUTO")
                emptyTurnStreak = 0
                consumedPrefix = ""
                pendingSpeechStartedAt = nil
                transcript = ""
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    self?.engine.clearLatestTxt()
                    self?.engine.writeResetFlag()
                }
            }
            return
        }
        emptyTurnStreak = 0

        // Filling the silence while the answer loads is neither more of the question nor a new
        // one. See AutoTurnDetector.isStallPhrase.
        if !lastAnsweredQuestion.isEmpty, AutoTurnDetector.isStallPhrase(text) {
            dlog("AUTO: filler while waiting — stepping past: '\(text.prefix(40))'", tag: "AUTO")
            carryFragment(text)
            consumedPrefix = rawNow
            pendingSpeechStartedAt = nil
            return
        }

        // The question again, late: the microphone hearing the speakers after the system tap
        // already delivered it. Joining it on would re-answer a stutter. See repeatsQuestion.
        // Only while that late copy can still be arriving. A minute later it is the interviewer
        // asking again, and is answered like any other question.
        if !lastAnsweredQuestion.isEmpty,
           Date().timeIntervalSince(lastAnsweredAt) < AutoTurnDetector.duplicateWindow,
           AutoTurnDetector.repeatsQuestion(text, lastAnsweredQuestion) {
            dlog("AUTO: the question heard a second time — stepping past: '\(text.prefix(40))'", tag: "AUTO")
            carryFragment(text)
            consumedPrefix = rawNow
            pendingSpeechStartedAt = nil
            return
        }

        // The candidate talking — starting their answer, or talking about themselves — is not a
        // question, and not more of one. See AutoTurnDetector.soundsLikeCandidate. Only with the
        // microphone on: without it the candidate cannot be heard at all.
        // Known here rather than below, because who is talking depends on WHEN: see
        // soundsLikeCandidate(includePlural:).
        let saidBeforeAnswer = pendingSpeechStartedAt != nil && pendingSpeechBeganBeforeAnswer

        if micCaptureActive {
            // Only the candidate's OWN words go. Measured: "With an example from Spring. Sure.
            // Let me think." was dropped whole — the stall on the end made the lot read as the
            // candidate — and the interviewer's addition to the question went with it.
            let front = AutoTurnDetector.withoutCandidateTail(text, includePlural: saidBeforeAnswer)
            if front != text, !front.isEmpty,
               !AutoTurnDetector.soundsLikeCandidate(front, includePlural: saidBeforeAnswer) {
                dlog("AUTO: dropped the candidate's words off the end — keeping: '\(front.prefix(50))'", tag: "AUTO")
                text = front
            } else if AutoTurnDetector.soundsLikeCandidate(text, includePlural: saidBeforeAnswer) {
                dlog("AUTO: the candidate talking, not a question — stepping past: '\(text.prefix(50))'", tag: "AUTO")
                consumedPrefix = rawNow
                pendingSpeechStartedAt = nil
                return
            }
        }

        // SAID BEFORE THE ANSWER WAS UP (declared above). The owner, 2026-09-15: the question
        // is asked, and while the answer is still coming the interviewer adds one more line —
        // and the app answered that line alone and threw the question away. Speech that begins
        // before anyone could have read the answer cannot be a reply to it, so it is the same
        // question continuing, whatever it looks like on its own. The joining-word test below
        // is for speech heard AFTER an answer, where a new question is the likelier reading;
        // "Where have you used it?" fails it, and was answered as if nothing came before.
        // CONTINUATION: silence alone cannot tell "finished" from "thinking mid-sentence".
        // A slow speaker, or one on a laggy connection, says "what's the difference between
        // W2 and C2C" ... pause ... "and full time" — and a pure silence trigger answers
        // the first half. Rather than waiting longer for everyone (which makes the app feel
        // slow for normal speakers), treat speech that arrives soon after an answer as the
        // SAME question continuing: merge it with what was already asked and answer the
        // whole thing, replacing the partial answer.
        let sinceAnswer = Date().timeIntervalSince(lastAnsweredAt)
        let chainAge = Date().timeIntervalSince(continuationChainStartedAt)
        // Cleaned here as well as in extractLatestQuestion: a joined question is sent as it
        // stands, and never passes through there.
        // Measured: "Tell me about a time you handled a production outage." was re-answered as
        // "... outage. last" — one word off the front of the candidate's own sentence.
        let addition = AutoTurnDetector.withoutCandidateTail(text, includePlural: saidBeforeAnswer)
        let additionWords = addition.split(whereSeparator: { $0 == " " }).count
        let mergedCandidate = AutoTurnDetector.stripTrailingStalls(
            AutoTurnDetector.collapseRepeats((lastAnsweredQuestion + " " + addition)
                .trimmingCharacters(in: .whitespacesAndNewlines)))
        let mergedWords = mergedCandidate.split(whereSeparator: { $0 == " " }).count
        // When this speech BEGAN, not when it ended: a genuine addition can start inside
        // the window and run on for several seconds.
        let startedAt = pendingSpeechStartedAt ?? Date()
        let startedWithinWindow = startedAt.timeIntervalSince(lastAnsweredAt) < continuationStartWindow
        if !lastAnsweredQuestion.isEmpty, additionWords >= 2, sinceAnswer < continuationWindow,
           startedWithinWindow || speechBeganWhileLoading || saidBeforeAnswer,
           // ...and it has to be an ADDITION, not the next question. Speaking over the
           // answer used to be enough on its own, which glued separate questions together.
           AutoTurnDetector.isFollowUpAddition(addition),
           chainAge < continuationWindow,
           continuationCount < maxContinuations,
           mergedWords <= (saidBeforeAnswer ? maxGapMergeWords : maxContinuationWords),
           !AutoTurnDetector.isFragmentedNoise(mergedCandidate),
           // The FRAGMENT, judged on its own. Testing only the merged text hides a noisy
           // fragment behind a legitimate question: the merge is mostly the real question,
           // so the ratio stays healthy no matter what is being glued onto it.
           !AutoTurnDetector.isChoppyFragment(text),
           !AutoTurnDetector.looksLikeForeignSpeech(text),
           // Not if the "continuation" is the user rehearsing the answer we just gave.
           // This test existed further down and was unreachable from here: the merge runs
           // first, so speech that was plainly an echo got merged and re-answered before
           // anything looked at it. Observed three times in one session — the question, then
           // the question plus "Yeah. So my day to day activities is my usually kicks off",
           // then that plus "Kick kicks in", each answered in full.
           //
           // A check placed after the branch that bypasses it is not a check.
           speechBeganWhileLoading
            || !AutoTurnDetector.isEchoOfPrevious(text,
                                                  lastQuestion: lastAnsweredQuestion,
                                                  lastAnswer: lastAnsweredAnswer),
           saidBeforeAnswer
            || (sinceAnswer < tailWindow
                && Self.looksLikeContinuation(previous: lastAnsweredQuestion, next: text)) {
            // Joined on but not finished — "and also" then a breath. Answering now would ask
            // the question with a dangling "and also" on the end; the rest is on its way, and
            // this speech stays unanswered so it is joined again, whole, when it arrives.
            if AutoTurnDetector.classifyTurnEnding(mergedCandidate) == .unfinished {
                dlog("AUTO: more of the question is still coming — waiting: '\(text.suffix(40))'", tag: "AUTO")
                return
            }
            // Nothing new in it: "What is the CAP theorem?" plus "Good question." cleans back to
            // the question already answered. Re-answering spends a credit and replaces the answer
            // being read with the same words. Measured 2026-09-16, 01:09.
            if AutoTurnDetector.repeatsQuestion(Self.questionText(from: mergedCandidate), lastAnsweredQuestion) {
                dlog("AUTO: nothing new in what followed — not re-answering: '\(text.prefix(40))'", tag: "AUTO")
                consumedPrefix = rawNow
                pendingSpeechStartedAt = nil
                return
            }
            continuationCount += 1
            let merged = mergedCandidate
            dlog("AUTO: continuation\(saidBeforeAnswer ? ", said before the answer was up" : "") — re-answering the full question: '\(merged.prefix(90))'", tag: "AUTO")
            // Say WHY the answer just changed. Without this the replacement looks like the
            // app glitched and lost the answer, right when the user is reading it.
            thinkingText = "You added more — re-answering the full question…"
            text = merged
            // Replace rather than stack: the partial answer is now wrong.
            answerEpoch += 1
            isProcessing = false
            showThinking = false
            transcript = merged
            lastAnsweredQuestion = merged
            lastAnsweredAt = Date()
            submitAutomaticTurn(question: merged)
            return
        }

        // THE USER SPEAKING THE ANSWER IS NOT A NEW QUESTION.
        //
        // In Practice Auto the microphone is open by design, and the moment an answer
        // appears the user reads it out loud — that is the entire point of the mode. The
        // mic hears that and, without this, treats the candidate's own answer as the next
        // question and answers its own answer. In a real interview the same thing happens
        // when the candidate delivers the reply to the interviewer.
        //
        // Detected by overlap rather than timing: a cooldown would either be too short for
        // a long answer or deafen the app to a genuine follow-up. If what was just heard is
        // largely made of words from the answer on screen, it is the answer being spoken.
        // Only when the microphone is actually open. With it switched off in Settings the
        // candidate cannot be heard, so any match is a false positive, and a false positive
        // discards the utterance and wipes the transcript.
        if micCaptureActive, !speechBeganWhileLoading,
           Self.echoesOurAnswer(spoken: text, answer: Self.answerBody(aiAnswer)) {
            dlog("AUTO: our own answer being read aloud — discarding it", tag: "AUTO")
            // DISCARD it rather than just ignoring it. The transcript accumulates, so an
            // echo left in place gets glued to the next real question — "…learn more about
            // the role. Okay. So tell me about yourself." — and the combined text still
            // looks mostly like the answer, so the genuine question is thrown out with it.
            // Clearing here means the next thing said stands on its own.
            transcript = ""
            resetAutoTurnState()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.engine.clearLatestTxt()
                self?.engine.writeResetFlag()
            }
            return
        }

        // NOT THE LANGUAGE WE ARE LISTENING FOR — or a conversation across the room. The
        // engine is configured for English and maps whatever it hears onto English words, so
        // Telugu (or a phone call nearby) arrives as confident nonsense that passes every
        // question test and costs a credit each time. Drop it, and step past it so it cannot
        // glue itself to a real question later.
        if AutoTurnDetector.isFragmentedNoise(text) || AutoTurnDetector.looksLikeForeignSpeech(text) {
            dlog("AUTO: transcript is not answerable speech — discarding: '\(text.prefix(60))'", tag: "AUTO")
            consumedPrefix = engine.readLatestTxt()
            pendingSpeechStartedAt = nil
            transcript = ""
            return
        }

        // Still skip backchannel and self-corrections — "okay", "yes sir", "sorry" are
        // complete utterances acoustically, and answering them would burn a credit and
        // put a pointless answer on screen mid-interview.
        // No longer demands a question form. That rule belonged to Practice Auto and rejected
        // first-person statements; with one mode the microphone is open in real interviews
        // too, and it would also drop "I'd like to hear about a conflict you handled". The
        // candidate reading an answer back is caught by read-back detection above. Rehearsing
        // in entirely their own words is not, which is the known residual; Manual avoids it.
        // Drop an opening pleasantry so the question behind it survives. "Hello How are you
        // What is Java" was answered "Doing really well, thanks!" — the greeting answered,
        // the question discarded — and the owner then asked twice more. Those repeats read
        // as the bug and were the symptom.
        let stripped = AutoTurnDetector.stripLeadingPleasantries(text)
        if stripped != text {
            dlog("AUTO: dropped an opening greeting — asking '\(stripped.prefix(60))'", tag: "AUTO")
            text = stripped
        }

        // Reading the app's own answer back is not a new question. See isEchoOfPrevious —
        // from a real session, where the owner rehearsed aloud and was answered again,
        // identically, at the cost of another credit.
        if !speechBeganWhileLoading,
           AutoTurnDetector.isEchoOfPrevious(text,
                                             lastQuestion: lastAnsweredQuestion,
                                             lastAnswer: lastAnsweredAnswer,
                                             secondsSinceAnswer: Date().timeIntervalSince(lastAnsweredAt)) {
            dlog("AUTO: that is our own previous turn being read back — not answering again",
                 tag: "AUTO")
            consumedPrefix = engine.readLatestTxt()
            pendingSpeechStartedAt = nil
            transcript = ""
            return
        }

        // Context and then the question is judged by its last sentence too. Judged whole, "We are
        // building a payments platform ... fifty milliseconds. How would you design the database
        // layer?" had full stops before any question word and read as background talk.
        func endsOnQuestionNow(_ t: String) -> Bool {
            t.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
                || AutoTurnDetector.isLikelyCompleteQuestion(AutoTurnDetector.lastSentence(t), requireInterrogative: true)
        }
        var endsOnQuestion = endsOnQuestionNow(text)
        var answerable = endsOnQuestion || AutoTurnDetector.isLikelyCompleteQuestion(AutoTurnDetector.normalize(text),
                                                                                       requireInterrogative: false)
        // A very slow speaker: the start of the question was set aside a moment ago. Put it back
        // when this is not a question by itself and the two together are.
        carriedFragments.removeAll { Date().timeIntervalSince($0.at) > fragmentCarrySeconds }
        // Not a question by itself, or a start that stops mid-sentence ("How would you") followed by
        // words that are not a question's own start ("design a rate limiter...?"): the second half
        // of that sentence, which answered alone loses what was asked.
        if !answerable
            || (AutoTurnDetector.carriedPrefixLeavesSentenceOpen(carriedFragments.map(\.text))
                && !AutoTurnDetector.opensLikeQuestion(text)) {
            if let joined = AutoTurnDetector.question(afterCarrying: carriedFragments.map(\.text), then: text) {
                dlog("AUTO: slow speaker — joined '\(joined.prefix)' with '\(text.prefix(40))' into one question", tag: "AUTO")
                carriedPrefixForTurn = joined.prefix
                carriedPrefixAt = Date()
                carriedFragments = []
                text = joined.question
                endsOnQuestion = endsOnQuestionNow(text)
                answerable = true
            }
        }
        guard answerable else {
            // IGNORING IS NOT ENOUGH. Rejected speech stays in the file and gets glued to the
            // next real question, and once the pile carries two full stops with no
            // interrogative in its opening words it is rejected FOREVER — every later
            // question dies with it and the app never answers again until New Session.
            // Practice Auto guarantees this: saying the answer out loud is the point of the
            // mode, none of it is a question, and paraphrasing means echo detection never
            // catches it either. So step past speech that is spent.
            // HOLD CONTEXT BRIEFLY FIRST. An interviewer sets the scene and then asks: measured,
            // "We are building a payments platform ... under fifty milliseconds." ended a turn, and
            // "How would you design the database layer?" followed a breath later — answered
            // without the context that made it answerable, because this stepped past it at once.
            // Held for a few seconds it joins the question. Long speech is still stepped past
            // straight away, so nothing can pile up (see isSpentSpeech).
            let words = text.split(separator: " ").count
            if words < 80 {
                // EVERY leftover, not only the finished ones. Measured: "We are building a payment
                // platform ... under fifty milliseconds" ended without a full stop, so it counted
                // as unfinished, was neither held nor stepped past, and simply stayed — twenty-five
                // seconds later the NEXT question was glued to it and answered as one. Held, it
                // joins a question that follows within seconds and is stepped past if none does.
                if contextHeldSince == nil {
                    dlog("AUTO: no question in it yet — holding it \(Int(contextHold))s for one: '\(text.prefix(50))'", tag: "AUTO")
                }
                contextHeldSince = Date()   // each new burst restarts the hold
            } else if AutoTurnDetector.isSpentSpeech(text) {
                consumedPrefix = engine.readLatestTxt()
                pendingSpeechStartedAt = nil
                contextHeldSince = nil
                transcript = ""
                dlog("AUTO: not a question and finished — stepping past it so the next one stands alone: '\(text.prefix(50))'", tag: "AUTO")
            } else {
                dlog("AUTO: utterance ended but it is not a question — ignoring: '\(text.prefix(50))'", tag: "AUTO")
            }
            return
        }
        // HOW the sentence ends decides whether to answer now, wait, or not at all. This
        // runs BEFORE the duplicate guard on purpose: an unfinished turn must stay askable,
        // and marking it as submitted here would silence the real question when it arrives.
        // NOT ANSWERED MID-SENTENCE, deliberately. Answering the question a speaker had
        // just finished while they carried straight on was tried and measured: it answered
        // all eight of eight rapid questions, but several answers went to fragments
        // ("What is a", "semaphore?") because the submission consumes the transcript and
        // the half-said tail then arrived as its own turn. A fragment answered confidently
        // is worse than an answer that waits for the pause.
        switch AutoTurnDetector.classifyTurnEnding(text) {
        case .unfinished:
            // Silence proves they paused, never that they finished. Waiting costs nothing
            // because their next word submits the turn.
            dlog("AUTO: sentence still in the air — waiting: '\(text.suffix(40))'", tag: "AUTO")
            return
        case .unclear:
            // Follow this speaker's own pace when it is slower than the default, so a
            // deliberate talker is not cut off by a number tuned on somebody quicker.
            let paceFloor = longestMidTurnGap * 1.3
            let wait = min(max(unclearSilence, paceFloor), maxUnclearSilence)
            unclearPendingText = text
            unclearDeadline = Date().addingTimeInterval(wait)
            // When this run of waiting BEGAN. The per-fragment deadline above is reset every
            // time more speech arrives, which is correct for a speaker pausing mid-sentence
            // and fatal when they repeat themselves: each repeat cleared the deadline, so the
            // turn never committed, so nothing was answered, so they repeated again. Observed
            // live — "So what is JPA ? What is JPA ? What is JPA ?" never answered, with
            // "the unclear ending was a pause" logged on every cycle.
            //
            // A bound reset by the thing it is bounding is not a bound. This one is anchored.
            if unclearChainStartedAt == .distantPast { unclearChainStartedAt = Date() }
            // An unclear ending buys 820ms or more — enough to have the picture up before
            // the turn even commits.
            if isWatchMode { Task { [weak self] in await self?.prepareScreenshotAhead() } }
            dlog("AUTO: ending unclear — giving it \(Int(wait * 1000))ms: '\(text.suffix(40))'", tag: "AUTO")
            return
        case .finished:
            // A finished STATEMENT is often context with the question still to come. It gets the
            // longest unclear wait rather than being answered alone; a statement that really is
            // the question ("I'd like to hear about your Kafka work.") costs only that wait.
            // "Hi, how are you?" is a finished question and gets answered with a pleasantry, so
            // when the real question follows a breath later it arrives after the canned reply is
            // already on screen. Measured: "Hi, how are you doing today? Tell me about yourself."
            // answered "Doing really well, thanks!". A pleasantry waits like a statement does.
            if !endsOnQuestion || PromptBuilder.shared.isGreetingOrSmallTalk(text) {
                unclearPendingText = text
                unclearDeadline = Date().addingTimeInterval(maxUnclearSilence)
                if unclearChainStartedAt == .distantPast { unclearChainStartedAt = Date() }
                dlog("AUTO: a statement, not a question — giving it \(Int(maxUnclearSilence * 1000))ms for one: '\(text.suffix(40))'", tag: "AUTO")
                return
            }
            // The upload overlaps the drain and the answer request, so by the time the
            // question is sent the picture is usually already there.
            if isWatchMode { Task { [weak self] in await self?.prepareScreenshotAhead() } }
            commitAutomaticTurn(text)
        }
    }

    /// Replace the transcription token before it expires, in a quiet moment.
    ///
    /// The token lasts about an hour and the engine is handed it once, at launch, so a long
    /// interview outlives it: Windows measured a real session going silent for good after an
    /// hour — Deepgram refused, Speechmatics refused the same stale key, nothing recovered
    /// (MAC_CATCHUP, 2026-09-17, CRITICAL). Renewing early costs a one-second restart nobody
    /// sees; waiting for the failure costs the question being asked when it happens.
    ///
    /// Windows renews only while not listening. That cannot work here: in Auto the Mac is
    /// listening nearly all the time, so the rule would never fire. A quiet moment is the
    /// Mac's equivalent — nothing being answered, no turn being submitted, no speech for 3s.
    private func renewSpeechTokenIfExpiring() {
        let now = Date()
        guard now.timeIntervalSince(lastTokenRenewalCheckAt) >= 30 else { return }
        lastTokenRenewalCheckAt = now
        guard session.isLoggedIn, engine.isRunning, !isProcessing, !autoTurnSubmitting,
              now.timeIntervalSince(lastSpeechHeardAt) > 3,
              now.timeIntervalSince(lastTokenRenewalAt) > 5 * 60,
              let expiry = session.speechKeyExpiresAt,
              expiry.timeIntervalSince(now) < 8 * 60 else { return }
        lastTokenRenewalAt = now
        dlog("STT_KEY: token expires in \(max(0, Int(expiry.timeIntervalSince(now) / 60))) min — renewing it in a quiet moment", tag: "AUTH")
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await self.session.fetchSpeechmaticsKeyAsync(forceRefresh: true) else {
                dlog("STT_KEY: early renewal failed — the rejection path will still recover", tag: "AUTH")
                return
            }
            guard !self.isProcessing, !self.autoTurnSubmitting else { return }
            self.engine.stop()
            self.engine.start(smKey: self.session.speechmaticsKey)
        }
    }

    /// Answer a finished question now, because the candidate has started talking after it.
    /// See the call in updateTranscript. The words after the question are consumed with it, so
    /// the end of speech that follows finds only the rest of the candidate's talking.
    private func commitBeforeCandidateTail(_ question: String) {
        let q = AutoTurnDetector.stripLeadingPleasantries(AutoTurnDetector.collapseRepeats(question))
        // Never answer a pleasantry early — the question it precedes is usually a second behind.
        guard !PromptBuilder.shared.isGreetingOrSmallTalk(q) else { return }
        guard !AutoTurnDetector.repeatsQuestion(q, lastAnsweredQuestion),
              !AutoTurnDetector.isEchoOfPrevious(q, lastQuestion: lastAnsweredQuestion,
                                                 lastAnswer: lastAnsweredAnswer) else { return }
        disarmScrollWatch()
        unclearDeadline = nil; unclearPendingText = ""; unclearChainStartedAt = .distantPast
        guard autoDetector.acceptUtterance(q) else { return }
        dlog("AUTO: question over and the candidate has started talking — answering now: '\(q.prefix(60))'", tag: "AUTO")
        lastUtteranceEndAt = Date()
        if isWatchMode { Task { [weak self] in await self?.prepareScreenshotAhead() } }
        lastAnsweredQuestion = q
        lastAnsweredAt = Date()
        continuationChainStartedAt = Date()
        continuationCount = 0
        submitAutomaticTurn(question: q)
    }

    /// The answer TEXT, without the "Q: <question>" header the answer pane is built with.
    ///
    /// The header repeats the question verbatim, so comparing speech against the whole pane
    /// meant a repeated or rephrased question scored as an echo of ourselves and was thrown
    /// away — the one moment the user most needs an answer.
    static func answerBody(_ pane: String) -> String {
        guard pane.hasPrefix("Q: "), let split = pane.range(of: "\n\n") else { return pane }
        return String(pane[split.upperBound...])
    }

    /// Everything between deciding a turn is over and actually answering it. Shared by the
    /// immediate path and the one that waited out an unclear ending.
    private func commitAutomaticTurn(_ text: String) {
        // A new question supersedes the old one, so the watch must not fire twenty seconds
        // later and re-answer something nobody is asking about any more.
        disarmScrollWatch()
        unclearDeadline = nil; unclearPendingText = ""; unclearChainStartedAt = .distantPast
        // The question just answered, arriving again — the recogniser re-sending its final after
        // the transcript was cleared, or with the start of a stall on it. acceptUtterance compares
        // exact text, and measured, the same question was answered twice a second apart. Judged
        // on the question this text would actually send.
        let asked = AutoTurnDetector.withoutCandidateTail(AutoTurnDetector.stripTrailingStalls(
            AutoTurnDetector.stripLeadingPleasantries(AutoTurnDetector.collapseRepeats(text))))
        if !lastAnsweredQuestion.isEmpty,
           Date().timeIntervalSince(lastAnsweredAt) < AutoTurnDetector.duplicateWindow,
           AutoTurnDetector.repeatsQuestion(asked, lastAnsweredQuestion) {
            dlog("AUTO: the question just answered, again — ignoring: '\(text.prefix(60))'", tag: "AUTO")
            consumedPrefix = engine.readLatestTxt()
            pendingSpeechStartedAt = nil
            return
        }
        guard autoDetector.acceptUtterance(text) else {
            dlog("AUTO: duplicate of the question just answered — ignoring", tag: "AUTO")
            return
        }
        if isProcessing {
            dlog("AUTO: more of the question arrived — replacing the in-flight answer", tag: "AUTO")
            answerEpoch += 1
            isProcessing = false
            showThinking = false
        }
        // Several complete questions in one turn: answer the one they just asked.
        var text = text
        if let latest = AutoTurnDetector.latestQuestionIfMultiple(text) {
            dlog("AUTO: several questions in one turn — answering the last: '\(latest.prefix(70))'", tag: "AUTO")
            text = latest
        }
        dlog("AUTO: speaker finished — answering: '\(text.prefix(70))'", tag: "AUTO")
        lastAnsweredQuestion = text
        lastAnsweredAt = Date()
        submitAutomaticTurn()
    }

    /// Is the speech we just heard the candidate reading the answer on screen aloud?
    ///
    /// One test, shared with the continuation merge and the question gate, so the three
    /// paths cannot disagree about what an echo is. See AutoTurnDetector.isEchoOfPrevious
    /// for why it measures word order rather than shared vocabulary.
    static func echoesOurAnswer(spoken: String, answer: String) -> Bool {
        AutoTurnDetector.isEchoOfPrevious(spoken, lastQuestion: "", lastAnswer: answer)
    }

    /// Is `next` a continuation of `previous` rather than a brand-new question?
    ///
    /// Two signals, either is enough:
    ///   • it opens with a joining word — "and full time", "or W2", "also what about..."
    ///   • it is a short fragment that is not itself a question — the tail of a sentence
    ///     someone paused in the middle of
    static func looksLikeContinuation(previous: String, next: String) -> Bool {
        let n = next.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return false }
        // A TAIL IS SHORT. Measured: "Our team runs about 40 microservices on Kubernetes." was
        // joined onto a question asked fifteen seconds earlier — it asks nothing, so every test
        // below called it a tail — and the question it was actually introducing was then
        // answered without it. Windows caps a tail at eight words for the same reason.
        let wordCount = n.split(whereSeparator: { $0 == " " }).count
        let joiners = ["and ", "or ", "also ", "plus ", "but ", "as well", "along with",
                       "versus ", "vs ", "compared to", "what about", "how about", "then "]
        for j in joiners where n.hasPrefix(j) { return wordCount <= 12 }
        guard wordCount <= 8 else { return false }

        // FILLERS ARE NOT CONTINUATIONS, and this exclusion has to come first.
        //
        // "Okay" after an answer asks nothing, so every test below says continuation, and
        // the merge re-runs the question that was just answered — a second identical answer
        // and a second credit for a word that meant "I heard you".
        let words = n.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let fillers: Set<String> = ["okay", "ok", "yeah", "yes", "yep", "right", "sure",
                                    "mhm", "hmm", "uh", "um", "got", "it", "thanks",
                                    "thank", "you", "alright", "cool", "fine", "good"]
        if words.allSatisfy({ fillers.contains($0) }) { return false }

        // THE TEST IS "ASKS NOTHING", not "is too short to be a sentence".
        //
        // "C2C or W2 or full time." is well formed, is six words, and is obviously the rest
        // of "what are you looking for" — a word count rejected it for being long enough to
        // look like a sentence, which is not the question being asked. What matters is
        // whether it asks anything by itself; if it does not, it is the tail of something
        // that did.
        //
        // requireInterrogative is what makes "asks nothing" mean what it says. The looser
        // reading accepts any finished statement of five or more words as a question, and
        // "C2C or W2 or full time." is exactly that — so the tail of the question got
        // treated as a new one and was answered on its own.
        if !AutoTurnDetector.isLikelyCompleteQuestion(next, requireInterrogative: true) { return true }
        return false
    }

    /// End the listening turn and answer, exactly as a second Space press would, but
    /// triggered by the interviewer falling silent instead of by the user's hand.
    private func submitAutomaticTurn(question: String? = nil) {
        guard isListening else { return }
        let forced = question
        autoTurnSubmitting = true
        // DO NOT pause the engine here. Pausing made the app deaf for the whole time it
        // was answering, so anything said during that window was lost — and the person
        // asking does not stop talking just because we started thinking. Worse, when the
        // turn fired early on a fragment, the REST of the real question landed in that
        // deaf window and could never be recovered.
        //
        // Staying open is also what makes firing early safe: if more of the question
        // arrives, it forms a new turn and supersedes this answer (see updateTranscript).
        Task { @MainActor [weak self] in
            // RELEASED ON EVERY PATH OUT. The latch was cleared after the drain below, and the
            // guard on the next line returns before that: switch to Manual during the 150-600ms
            // drain and it stayed true forever. Both answer paths are gated on it, so auto mode
            // would answer nothing again until the app was restarted, silently. That exact shape
            // — a latch with one clear behind an early return — is what stopped auto mode on
            // Windows for a whole interview.
            defer { self?.autoTurnSubmitting = false }
            // Brief drain: recognition runs behind live speech, so the tail is still
            // arriving at the moment we decided the turn was over.
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self, self.autoModeEnabled else { return }
            // STILL MID-SENTENCE? Then the rest is on its way. Recognition runs behind live
            // speech, and one fixed 150ms was not always enough: measured, the model was asked
            // "What is the difference between an abstract class and an" — the last three words
            // of the question still in flight. Up to 450ms more, only while the words plainly
            // cannot end a sentence, so a question that has finished waits for nothing.
            var extraWaits = 0
            while extraWaits < 3,
                  AutoTurnDetector.classifyTurnEnding(
                      self.remainingSpeech(self.engine.readLatestTxt())) == .unfinished {
                try? await Task.sleep(nanoseconds: 150_000_000)
                extraWaits += 1
            }
            // Everything heard up to this instant is what we are about to answer. Record it
            // BEFORE answering, so whatever arrives next can be told apart from it without
            // clearing the file out from under a speaker who is still mid-sentence.
            let raw = self.engine.readLatestTxt()
            let heard = self.remainingSpeech(raw)
            self.consumedPrefix = raw
            self.pendingSpeechStartedAt = nil
            self.contextHeldSince = nil
            if let forced, !forced.isEmpty {
                self.transcript = forced
                self.lastAnsweredQuestion = forced
                self.lastAnsweredAt = Date()
                self.startAI(manualQuestion: forced)
                return
            }
            // The drain above exists precisely because the tail of the question was still
            // arriving. Record what we are ACTUALLY answering, not the shorter text that
            // triggered the turn — otherwise a continuation merges against a truncated copy
            // and re-asks half the question back to the model.
            // The start of the question that was set aside for a slow speaker, put back in front.
            let carried = Date().timeIntervalSince(self.carriedPrefixAt) < 8 ? self.carriedPrefixForTurn : ""
            self.carriedPrefixForTurn = ""
            if !heard.isEmpty {
                let asked = Self.questionText(from: carried.isEmpty ? heard : carried + " " + heard)
                self.transcript = asked
                self.lastAnsweredQuestion = asked
                self.lastAnsweredAt = Date()
                // A fresh question ends whatever chain preceded it, so the next continuation
                // gets its own full budget rather than inheriting a spent one.
                self.continuationChainStartedAt = Date()
                self.continuationCount = 0
                self.startAI(manualQuestion: asked)
                return
            }
            self.startAI()
        }
    }

    /// After an answer lands, start listening again on our own — otherwise Auto Mode
    /// answers exactly one question and then silently stops being automatic.
    private func rearmAutoModeIfNeeded() {
        guard autoModeEnabled, session.isLoggedIn, !isProcessing else { return }
        // Setup is not an interview. Picking Auto there must not open the microphone.
        guard appStep == .interview else { return }
        // The mic gave up on a silent room. Re-arming here would reopen it seconds later
        // and spend the time the stop just saved — and the message on screen says Space.
        guard !stoppedForIdle else {
            dlog("AUTO: stopped for idle — waiting for ⌥Space rather than re-arming", tag: "METER")
            return
        }
        guard engine.isRunning else {
            dlog("AUTO: engine not running — cannot arm", tag: "AUTO")
            return
        }
        // Also never re-arm mid-answer or mid-capture. Windows had a latch bug exactly
        // here that stopped auto mode permanently for the rest of the interview.
        guard !isScreenAnalyzing, !showThinking else {
            dlog("AUTO: busy (answering/capturing) — not arming yet", tag: "AUTO")
            return
        }
        // The mic now stays OPEN while answering, so isListening is still true when we get
        // here and this is the path that actually runs after every answer. It must leave the
        // app genuinely ready for the next question; the fuller re-arm below only applies
        // when the mic really was muted.
        if isListening {
            // Somebody may be MID-SENTENCE right now — the mic stayed open through the whole
            // answer on purpose. Clear only when nothing new is waiting; otherwise keep the
            // words and let the consumed prefix separate them from what we already answered.
            let remainder = remainingSpeech(engine.readLatestTxt())
            if remainder.isEmpty {
                consumedPrefix = ""
                pendingSpeechStartedAt = nil
                transcript = ""
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    self?.engine.clearLatestTxt()
                    self?.engine.writeResetFlag()
                }
                dlog("AUTO: ready for the next question (mic stayed open)", tag: "AUTO")
            } else {
                transcript = remainder
                dlog("AUTO: next question already being spoken — keeping it: '\(remainder.prefix(60))'", tag: "AUTO")
            }
            return
        }
        dlog("AUTO: re-arming for the next question", tag: "AUTO")
        isMuted = false; isListening = true
        justStartedListening = true; listenStartTicks = 0
        transcript = ""
        resetAutoTurnState()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.engine.clearLatestTxt()
            self?.engine.writeResetFlag()
            self?.engine.deletePauseFlag()
        }
        updateMicUI()
    }

    // ══════════════════════════════════════════════════════════════════════════
    // LISTENING TIME
    //
    // Credits count questions. Speechmatics charges by the hour of audio, and
    // nothing was counting that, so the expensive half of the bill was invisible:
    // a microphone left open all afternoon cost real money and showed up nowhere.
    //
    // Two halves. This side measures the time and reports it AS IT GOES, because
    // an app that is force-quit, a lid that closes and a connection that drops all
    // look identical afterwards and would otherwise be free. The server keeps the
    // running total and refuses a new speech token once the month is spent — which
    // is why the Mac app was already capped by this allowance while contributing
    // nothing to it. That was the largest single gap against Windows.
    //
    // And the mic switches itself off after a long silence. Most of the waste will
    // never be anybody being greedy, it will be somebody who opened the app and
    // went to lunch, and an empty room bills the same as an interview.
    // ══════════════════════════════════════════════════════════════════════════

    /// Three minutes, because in a real interview somebody speaks every few seconds and
    /// even a long thinking pause is well under a minute. Meant to catch an empty room,
    /// never a person deciding what to say.
    // ══════════════════════════════════════════════════════════════════════════
    // WHAT A CUSTOMER IS CHARGED
    //
    // The arithmetic is here, unaltered and in one place, because it decides somebody's
    // bill and was previously two inequalities at two call sites that nobody had compared.
    //
    // Two roundings run in OPPOSITE directions and compound. The tick FLOORS whole minutes
    // and carries the remainder; the stop path ROUNDS that remainder — up at 30s or more,
    // away entirely below it. And a turn is not a sitting: both Manual and Auto stop the
    // meter at the end of every exchange, so whichever rounding applies, it applies once
    // PER TURN. The error therefore scales with the NUMBER of turns rather than their
    // length, which is worst in the shape a real interview actually takes.
    //
    // Measured against this app's own arithmetic:
    //
    //     one 90s turn         1.5 min listened →   2 min billed    +33%
    //     ten 40s turns        6.7 min listened →  10 min billed    +50%
    //     20 turns of 45s     15.0 min listened →  20 min billed    +33%
    //     one 600s turn       10.0 min listened →  10 min billed      0%
    //     45 min, 40 turns    45.0 min listened →  40 min billed    -11%
    //     30 turns of 25s     12.5 min listened →   0 min billed   -100%
    //
    // DECIDED — the owner chose the session as the billing unit, and this is that rule.
    // Turns BANK their seconds and report only whole minutes, carrying the remainder into
    // the next turn. Nothing is rounded up until the sitting ends. The thirty-second floor
    // survives, so a genuinely brief interview is still not free — but it applies ONCE, at
    // the end, instead of once per turn.
    //
    //     ten 40s turns        6.7 min listened →   7 min billed   (was 10)
    //     thirty 25s turns    12.5 min listened →  13 min billed   (was  0)
    //     one 600s turn       10.0 min listened →  10 min billed   (unchanged)
    //
    // THE INVARIANT, which is the thing worth testing rather than the figures: the same
    // wall time costs the same however it was broken up. Six minutes bills as six whether
    // it arrived as one answer, twelve 30-second turns, ninety four-second turns or a
    // ragged mixture — verified on all five shapes. The old arithmetic was CORRECT for one
    // long turn and wrong for every other shape, so a single-shape test would have passed
    // it, which is presumably part of why it survived so long.
    //
    // Identical to the Windows rule by agreement: a Mac user and a Windows user billed
    // differently for the same interview is its own problem.
    //
    // THE LAST ROW MATTERS MOST, and it inverts the comment that defends the floor. The
    // thirty-second floor exists so that "rounding every short turn to nothing would make
    // an interview of brief exchanges free". It does that for turns of thirty seconds or
    // more. BELOW thirty seconds it causes precisely the outcome it was written to prevent:
    // every turn is discarded and a twelve-minute interview bills nothing at all.
    //
    // NOTHING HERE HAS BEEN CHANGED. The floor was a deliberate decision and remains one.
    // What was never decided is what happens when it is applied per turn to a remainder
    // that has already had its whole minutes removed — nobody chose that, the arithmetic
    // chose it. Which direction to correct is the owner's call, because it is his revenue
    // and his promise to customers, and it has to land on both platforms at once: a Mac
    // user and a Windows user billed differently for the same interview is its own problem.
    enum ListeningBilling {
        /// How long after words stop arriving the meter keeps counting. Long enough that a
        /// pause between two sentences is not a gap, short enough that a silent room is not
        /// billed. Windows ListeningBilling.SpeechWindow.
        static let speechWindow: TimeInterval = 6

        /// The part of an interval that counts as listening.
        ///
        /// LISTENING TIME IS SPEECH TIME (owner, 2026-09-29): an open microphone that hears
        /// nobody costs the user nothing. It was mic-open time, and Auto keeps the mic open
        /// for the whole sitting, so an hour of Auto with twenty questions billed about sixty
        /// minutes and the hidden fair use allowance was gone in one sitting; after that
        /// the app refused to listen. Now that same hour bills about five.
        ///
        /// The interval [start, now] counts in full when words arrived in it, or in the
        /// speechWindow before it; otherwise it counts for nothing. `lastWords` is when a
        /// NON-EMPTY transcript last arrived, so an empty result from a silent room never
        /// starts the clock. nil means nothing has been heard yet.
        static func countableSeconds(start: Date, now: Date, lastWords: Date?) -> Double {
            guard now > start, let lastWords = lastWords else { return 0 }
            return lastWords > start.addingTimeInterval(-speechWindow) ? now.timeIntervalSince(start) : 0
        }

        /// Mid-turn: whole minutes only, remainder carried forward.
        static func minutesFromTick(unreported: Double) -> (report: Int, carry: Double) {
            guard unreported >= 60 else { return (0, unreported) }
            let m = Int(unreported / 60)
            return (m, unreported - Double(m) * 60)
        }
        /// END OF SITTING — the only place anything is rounded up. Called once per
        /// session, by the exit flush and nowhere else.
        ///
        /// The thirty-second floor survives: a genuinely brief interview is still not free.
        /// What changed is that it applies ONCE, at the end, rather than once per turn to a
        /// remainder that had already had its whole minutes removed.
        static func minutesAtSessionEnd(unreported: Double) -> Int {
            guard unreported >= 30 else { return 0 }
            return max(1, Int((unreported / 60.0).rounded()))
        }
    }

    /// How often the listening meter ticks. NAMED, because it is half of an agreement with
    /// the Windows client and was previously a bare 5.0 inside a Timer call.
    ///
    /// THE CONTRACT: the deaf threshold is the promise; this interval is an implementation
    /// detail; the observable behaviour is a RANGE — a warning appears between the threshold
    /// and the threshold plus one interval. With 12s and 5s the ticks land at 5, 10, 15, so
    /// the measured latency is 15s and not 12. Windows measured 15s too, but by both
    /// happening to use a 5s meter rather than by agreement — which is exactly the kind of
    /// agreement that stops being true without anyone noticing.
    ///
    /// Changing either number changes what a user waits. Change them together, deliberately.
    static let listeningMeterInterval: TimeInterval = 5

    private let idleListeningTimeout: TimeInterval = 180
    /// Auto's ONE idle rule: fifteen minutes of real silence (Windows AutoIdleListeningTimeout).
    /// Auto listens by design and re-arms itself after every answer, so the Space-press
    /// timeouts cannot apply to it. Now that listening is metered by speech, an open mic in a
    /// quiet room costs the person nothing, so stopping it after three minutes only left the
    /// next question unheard while the candidate was still answering.
    private let autoIdleListeningTimeout: TimeInterval = 900
    private var interviewSilentTipShown = false
    /// How long to wait when nothing has been said AT ALL.
    ///
    /// Three minutes is right for a pause inside a conversation, where somebody is thinking
    /// and will speak again. It is far too patient for a session where not one word ever
    /// arrived: that is a key pressed by mistake, not a pause, and waiting three minutes to
    /// notice turns a stray press into a notice that appears over and over. Once anything
    /// has been said, the three minutes applies for the rest of that session.
    private let silentSessionTimeout: TimeInterval = 45
    private let listeningReportInterval: TimeInterval = 60

    /// Has anything been heard at all in the current listening session?
    private var heardAnythingThisSession = false
    /// Anything at all heard since the app started. The 45-second Interview tip reads this,
    /// not heardAnythingThisSession, which is reset every time listening restarts.
    private var heardEverThisRun = false

    /// A passing state worth knowing about, shown in the header beside the other passing
    /// states — never in the answer panel. See stopForIdle.
    var listeningNotice = ""
    private var listeningNoticeTimer: Timer?

    private func showListeningNotice(_ text: String) {
        listeningNotice = text
        listeningNoticeTimer?.invalidate()
        listeningNoticeTimer = Timer.scheduledTimer(withTimeInterval: 20.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.listeningNotice = "" }
        }
    }

    private var listeningMeterTimer: Timer?
    private var listeningSince: Date?
    private var lastSpeechHeardAt = Date()
    private var unreportedListeningSeconds: Double = 0
    private var lastRawTranscript = ""
    /// -1 = unlimited, or not yet known. Never a count.
    var audioMinutesRemaining = -1
    /// Did the PREVIOUS answer come from the screen?
    ///
    /// This is what lets "and what is the time complexity?" follow "solve this" without
    /// naming the screen again. Sticky with no timeout, matching Windows deliberately so the
    /// two apps cannot drift — but it IS a weakness, not a design: a question asked four
    /// minutes later about something else entirely still counts as a continuation, as long
    /// as it is not on the personal list. A time bound or a turn count is probably right,
    /// and that is a decision to take on both platforms at once rather than diverge on.
    private var lastAnswerUsedScreen = false
    /// How many more follow-ups may inherit the screen without naming it.
    ///
    /// A sticky flag with no bound let a question four minutes later still count as a
    /// continuation. The failure is topic DRIFT, not elapsed time — "what's the complexity?"
    /// three minutes on is still about the screen, while "tell me about yourself" ten
    /// seconds on is not. A time bound cuts the legitimate slow case and still allows the
    /// illegitimate fast one, so this counts turns instead.
    ///
    /// Three: the complexity, the edge case, the alternative — the run that actually
    /// follows "solve this". Refilled by an explicit screen question, drawn down per
    /// follow-up, zeroed by anything else. Same number as Windows, deliberately.
    private var screenFollowUpBudget = 0
    private let maxScreenFollowUps = 3

    /// Last time the user was told transcription looked deaf. At most once a minute — a
    /// warning that repeats buries the answer it is warning about.
    private var lastDeafWarningAt = Date.distantPast

    /// Set when the mic gave up on a silent room, so an automatic mode does not simply
    /// re-arm itself and undo the saving. Cleared the moment the user presses Space.
    private var stoppedForIdle = false

    /// Keep the meter in step with `isListening`. Called from updateMicUI, which every
    /// listening transition already flows through, so no individual call site can forget.
    private func syncListeningMeter() {
        let running = listeningMeterTimer != nil
        if isListening && !running { startListeningMeter() }
        else if !isListening && running { stopListeningMeter() }
    }

    private func startListeningMeter() {
        // A reconnect RESUMES the meter rather than restarting it — otherwise a dropped
        // connection would reset the idle clock for free.
        listeningSince = Date()
        lastSpeechHeardAt = Date()
        heardAnythingThisSession = false
        engine.resetDeafDetection()   // a fresh turn never starts already accused
        listeningNoticeTimer?.invalidate(); listeningNotice = ""   // a new session, not the old one's news
        listeningMeterTimer?.invalidate()
        listeningMeterTimer = Timer.scheduledTimer(withTimeInterval: Self.listeningMeterInterval,
                                                   repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.listeningMeterTick() }
        }
        // Breaks loudly if someone changes one half of the agreement without the other.
        // The figure the two clients compare is the range, not the threshold alone.
        assert(Self.listeningMeterInterval == 5 && SpeechmaticsEngine.deafWordSilence == 12,
               "Deaf-warning latency is a contract with the Windows client: threshold \(SpeechmaticsEngine.deafWordSilence)s + one \(Self.listeningMeterInterval)s poll. Changing either changes what a user waits — update both sides and the documented range.")
        dlog("METER: listening started", tag: "METER")
    }

    private func stopListeningMeter() {
        listeningMeterTimer?.invalidate(); listeningMeterTimer = nil
        if let since = listeningSince {
            unreportedListeningSeconds += ListeningBilling.countableSeconds(
                start: since, now: Date(), lastWords: heardAnythingThisSession ? lastSpeechHeardAt : nil)
            listeningSince = nil
        }
        // Anything past half a minute still counts. Rounding every short turn down to
        // nothing would make an interview of brief exchanges free, which is the opposite
        // of what the meter is for.
        // A TURN IS NOT A SITTING. Whole minutes are reported and the remainder is BANKED
        // into the next turn — nothing is rounded up here. Rounding per turn charged every
        // exchange for its final partial minute, which overcharged short exchanges by half
        // and, below the thirty-second floor, discarded them entirely.
        let (minutes, carry) = ListeningBilling.minutesFromTick(unreported: unreportedListeningSeconds)
        unreportedListeningSeconds = carry
        if minutes > 0 { reportListeningMinutes(minutes) }
    }

    private func listeningMeterTick() {
        guard isListening else { stopListeningMeter(); return }
        let now = Date()

        // AUDIO GOING IN, NOTHING COMING OUT. The engine looks healthy in every status line
        // it prints, so without this the app cannot tell working from deaf — which is how
        // three separate FIFO-reader bugs each reached a user before anyone noticed.
        if engine.looksDeaf, now.timeIntervalSince(lastDeafWarningAt) > 60 {
            lastDeafWarningAt = now
            dlog("METER: audio arriving but no words for 12s — transcription looks deaf", tag: "METER")
            showListeningNotice("HEARING AUDIO BUT NO WORDS — CHECK TRANSCRIPTION")
        }

        // A pause and a stray keypress are not the same situation, and only one of them
        // deserves three minutes of patience.
        //
        // The 45-second rule exists for a key pressed by mistake — and in an automatic mode
        // no key was pressed. The user deliberately chose a mode whose whole promise is that
        // it keeps listening with nothing touched, and switching the microphone off 45
        // seconds later contradicts the thing they just asked for: armed before a call that
        // has not started yet is the ordinary case, not a mistake. Three minutes still
        // catches the app left open on an empty room, which is what the waste actually is.
        let patience = autoModeEnabled
            ? autoIdleListeningTimeout
            : (heardAnythingThisSession ? idleListeningTimeout : silentSessionTimeout)

        // INTERVIEW MODE HEARS THE MEETING ONLY, never the person's own voice, by design, and
        // nothing said so. After 45 seconds with nothing heard at all, say it once and offer
        // the switch (Windows ListeningMeterTick, 2026-09-29).
        // Measured on the SESSION clock, as Windows does (_sessionSeconds >= 45). An earlier
        // version measured from listeningSince, which this tick re-stamps every five seconds,
        // so the condition could never be true and the tip never appeared.
        if !heardEverThisRun, !interviewSilentTipShown, !practiceAudioOn,
           appStep == .interview, sessionSeconds >= 45, alertTitle.isEmpty {
            interviewSilentTipShown = true
            dlog("MODE: Interview mode heard nothing for 45s; offered a switch to Practice", tag: "MODE")
            showAlert(title: "Nothing heard yet",
                      body: "Interview mode listens to your meeting only, so your own voice is not picked up. If you are speaking yourself, switch to Practice.",
                      actionLabel: "Switch to Practice") { [weak self] in
                self?.selectAudioSource(practice: true)
            }
        }

        if now.timeIntervalSince(lastSpeechHeardAt) >= patience {
            // The WORDING follows the same condition as the wait. It used to be chosen by
            // heardAnythingThisSession alone while the wait was chosen by that OR auto mode,
            // so an automatic session that had heard nothing yet waited the full three
            // minutes and then reported "nothing heard in 45s" — a log line that sent me
            // looking for a bug in the timeout that was working correctly.
            dlog(patience == idleListeningTimeout
                 ? "METER: no speech for \(Int(idleListeningTimeout / 60)) minutes — stopping the microphone"
                 : "METER: nothing heard in \(Int(silentSessionTimeout))s — stopping the microphone",
                 tag: "METER")
            stopForIdle()
            return
        }

        if let since = listeningSince {
            unreportedListeningSeconds += ListeningBilling.countableSeconds(
                start: since, now: now, lastWords: heardAnythingThisSession ? lastSpeechHeardAt : nil)
            listeningSince = now
        }
        let (minutes, carry) = ListeningBilling.minutesFromTick(unreported: unreportedListeningSeconds)
        if minutes > 0 {
            unreportedListeningSeconds = carry
            reportListeningMinutes(minutes)
        }
    }

    /// Ends a listening session nobody is using, and says so plainly.
    ///
    /// Stopping silently would be worse than the waste it prevents: somebody coming back
    /// to the app would speak into a microphone they believed was on.
    private func stopForIdle() {
        stopListeningMeter()
        stoppedForIdle = true
        isListening = false; isMuted = true
        engine.writePauseFlag()
        resetAutoTurnState()
        // Said in the HEADER, not in the answer.
        //
        // Writing it into the answer panel replaced an answer somebody was still reading
        // with a message about the microphone — and it fired exactly then, because in an
        // automatic mode the mic stays open through the whole answer by design. The mic
        // going quiet is worth knowing and is not worth losing the answer over.
        // ALWAYS say how to come back. "MIC OFF — NOTHING HEARD" was shown whenever nothing
        // had been said yet — which in an automatic mode is the ordinary case of being armed
        // before the call starts — and it told the user the one thing they did not need to
        // know while leaving out the one thing they did.
        var wakesOnAudio = false
        if #available(macOS 14.2, *) { wakesOnAudio = autoModeEnabled }
        if wakesOnAudio {
            showListeningNotice("STANDBY. WAKES WHEN SOMEONE SPEAKS")
        } else {
            showListeningNotice(heardAnythingThisSession
                ? "MIC OFF AFTER A QUIET STRETCH. SPACE TO RESUME"
                : "MIC OFF, NOTHING HEARD YET. SPACE TO RESUME")
        }
        updateMicUI()
    }

    /// End of the sitting. THE ONLY PLACE the banked remainder is ever billed.
    ///
    /// Under per-turn billing a missing flush cost a fraction of a minute. Under
    /// per-session billing it is the whole thing: without this, every session silently
    /// discards up to fifty-nine seconds, and any sitting under a minute of total
    /// listening bills nothing at all, ever.
    ///
    /// - Parameter synchronously: block briefly for the send. Used on app termination,
    ///   where an async Task would be killed with the process before it reached the wire.
    func flushListeningMeterOnExit(synchronously: Bool = false) {
        // The last answer must be on disk before the process can end.
        if synchronously { Self.drainSessionLog() }
        if let since = listeningSince {
            // Speech time here too. This is the last place the wall clock was still being
            // billed, so an app quit while listening to a silent room charged for the wait.
            unreportedListeningSeconds += ListeningBilling.countableSeconds(
                start: since, now: Date(), lastWords: heardAnythingThisSession ? lastSpeechHeardAt : nil)
            listeningSince = nil
        }
        let minutes = ListeningBilling.minutesAtSessionEnd(unreported: unreportedListeningSeconds)
        unreportedListeningSeconds = 0
        guard minutes > 0, session.isLoggedIn else { return }
        dlog("METER: session ended — flushing \(minutes) min", tag: "METER")
        if synchronously {
            NetworkClient.shared.reportListeningMinutesBlocking(minutes)
        } else {
            reportListeningMinutes(minutes)
        }
    }

    /// Never fail an interview over accounting: a failed report loses a minute, never the
    /// call. The gate that protects the money is server-side already.
    private func reportListeningMinutes(_ minutes: Int) {
        guard minutes > 0, session.isLoggedIn else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let remaining = await NetworkClient.shared.reportListeningMinutes(minutes) {
                self.audioMinutesRemaining = remaining
                dlog("METER: reported \(minutes) min; \(remaining) left this month", tag: "METER")
                self.updateCreditsUI(credits: self.session.credits, plan: self.session.plan,
                                     isUnlimited: self.session.isUnlimited)
                self.warnIfListeningTimeLow()
            } else {
                dlog("METER: report of \(minutes) min did not land — carrying on", tag: "METER")
            }
        }
    }

    /// Warns BEFORE the allowance runs out. Transcription stopping without warning in the
    /// middle of an interview is the worst possible way to learn a limit exists.
    ///
    /// Only when it is reached, and in words. Listening is a hidden fair use guard, not a
    /// meter: counting its minutes down on screen (it used to say "12 minutes of listening
    /// time left") turns a guard into a number people shop by, and no customer text may
    /// state minutes or hours. Same words as Windows ListeningProblems.NoListeningTime.
    private func warnIfListeningTimeLow() {
        guard audioMinutesRemaining == 0 else { return }
        aiAnswerHint = "You have reached this month's fair use limit for listening. You still have answers left, but nothing more can be heard until the limit renews or you upgrade. Reading your screen with F8 still works."
    }

    /// Current allowance without reporting anything, so the badge is honest before the
    /// first minute of a session has been spent.
    func fetchListeningTime() async {
        guard session.isLoggedIn else { return }
        if let remaining = await NetworkClient.shared.fetchListeningTime() {
            audioMinutesRemaining = remaining
            dlog("METER: \(remaining) listening minutes left this month", tag: "METER")
            updateCreditsUI(credits: session.credits, plan: session.plan, isUnlimited: session.isUnlimited)
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
        syncListeningMeter()  // ...and so does the listening meter, for the same reason
        if isProcessing      { micStatus = "THINKING";  micColor = .orange }
        else if isListening  {
            // An automatic mode with no live transcription answers NOTHING, silently — the
            // user speaks, waits, and gets no answer and no error. A green LISTENING pill
            // through that window actively tells them the opposite of what is true, so say
            // CONNECTING until the recogniser is genuinely online.
            if !engine.isReady {
                micStatus = "CONNECTING"; micColor = .orange
            } else {
                micStatus = "LISTENING"; micColor = .green
            }
        }
        // Auto mode pauses the mic after a quiet stretch and wakes by itself on the next
        // audio. A red MUTED there reads as broken; it is only waiting.
        else if isMuted && stoppedForIdle && autoModeEnabled { micStatus = "STANDBY"; micColor = .orange }
        else if isMuted      { micStatus = "MUTED";     micColor = Color(red: 239/255, green: 68/255, blue: 68/255) }
        // "RECORDING" was shown whenever a session was open, but the Mac never records audio —
        // isRecording only means a session log is being written. Telling someone in an
        // interview that they are being recorded when they are not is the one status that must
        // never be wrong. Windows made the same change (MAC_CATCHUP, 2026-09-17).
        else                 { micStatus = "READY"
                               micColor = Color(red: 239/255, green: 68/255, blue: 68/255) }
    }

    // MARK: - Session
    /// The answers of the interview just ended are not the next one's. Emptied when a SESSION
    /// begins. It used to be emptied every time listening started, which in Manual is every press
    /// of Space, so only the latest answer was ever there to go back to (found by testing,
    /// 2026-10-01: three answers, "showing answer 1 of 1").
    private func resetAnswerHistory() {
        answerHistory.removeAll(); historyIndex = nil
        newerAnswerWaiting = false; newerAnswerCount = 0
    }

    func startNewSession() {
        prepareSession()
        // In the Interview step a new session starts the interview clock at once (New Session
        // button). On the Setup page it only prepares the file: nothing listens, nothing counts.
        if appStep == .interview { beginInterviewClock() }
    }

    /// A session file and number, ready for the first answer. Does NOT start listening, the
    /// timer, or anything that watches the screen: on the Setup page none of that may run.
    private func prepareSession() {
        resetAnswerHistory()
        // BUG FIX: refresh the global-hotkey gate now that we're logged in. Session restore
        // is async, so the gate was seeded as "signed out" at launch and Space wasn't being
        // handled globally until the user first interacted with the app (e.g. opened the
        // debug log) — the "Space does nothing / had to press F12 first" bug.
        refreshHotkeyGate()
        resumeLocked = false
        stoppedForIdle = false   // a new session is a deliberate fresh start
        PromptBuilder.shared.clearHistory()
        let dir = engine.appDataFolder
        var num = sessionNumber
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent("interview_\(num).txt").path) { num += 1 }
        sessionNumber = num
        sessionLogPath = dir.appendingPathComponent("interview_\(num).txt")
        cloudTurns = []; cloudSessionId = nil
        isRecording = true
    }

    /// The interview is under way: the clock runs, update checks stand down, and Auto begins
    /// listening rather than waiting for a keypress that Auto exists to remove.
    private func beginInterviewClock() {
        // Don't let a background "Update available" alert pop up over an active interview —
        // see AppUpdater.setInterviewActive for why. Resumed in endSession().
        AppUpdater.shared.setInterviewActive(true)
        sessionSeconds = 0; sessionTimerVisible = true
        if autoModeEnabled { DispatchQueue.main.async { [weak self] in self?.rearmAutoModeIfNeeded() } }
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
        endSession(); transcript = ""; aiAnswer = ""; lastQuestionShown = ""
        answerEpoch += 1   // cancel any in-flight streaming callbacks
        liveHints = ""; saveHints()   // fresh interview → fresh hints
        // Same reason as the launch hint: an automatic mode needs no keypress to begin.
        aiAnswerHint = autoModeEnabled
            ? "New session started. " + idleHintForCurrentMode
            : "New session started. Press SPACE to begin."
        startNewSession()
    }

    private func endSession() {
        // A new session, or signing out, ends the sitting — so the bank is settled here.
        stopListeningMeter()
        flushListeningMeterOnExit()
        disarmScrollWatch()
        isRecording = false; sessionLogPath = nil
        sessionTimerObj?.invalidate(); sessionTimerVisible = false
        PromptBuilder.shared.clearHistory()
        AppUpdater.shared.setInterviewActive(false)
    }

    /// One serial queue for every transcript write: the file work happens off the main thread
    /// (it used to run there once per answer) and entries still land in the order they were
    /// made. Windows moved its writer the same way after it was found decrypting and
    /// re-encrypting the whole file on the UI thread per answer.
    private static let sessionLogQueue = DispatchQueue(label: "replysis.session-log", qos: .utility)

    /// Wait for queued transcript writes to reach the disk. Finish and quit call this, so the
    /// last answer is in the file before anything reads it back or the process ends.
    nonisolated static func drainSessionLog(timeout: TimeInterval = 5) {
        let done = DispatchSemaphore(value: 0)
        sessionLogQueue.async { done.signal() }
        _ = done.wait(timeout: .now() + timeout)
    }

    private func appendToSessionLog(q: String, a: String) {
        syncTurnToCloud(q: q, a: a)
        guard let path = sessionLogPath else { return }
        let entry = "Q: \(q)\nA: \(a)\n\n"
        // Everything the write needs is read HERE, on the main actor; the queue touches none of it.
        let header: String = {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd HH:mm"
            return "SESSION \(sessionNumber) | ai | \(fmt.string(from: Date())) | RESUME: \(ResumeParser.extractName(resumeText))\n\n"
        }()
        Self.sessionLogQueue.async {
            do {
                if !FileManager.default.fileExists(atPath: path.path) {
                    // Lazy creation: write header + first entry atomically so empty
                    // sessions never produce files that clutter Past Sessions view.
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
    }

    // Cloud backup mirror of the local .txt log — same Firestore collection the
    // website's real-interview page writes to. Guests skipped: they have no
    // Firebase account for the endpoint to authenticate against. Fire-and-forget:
    // never blocks or affects the local log above.
    private func syncTurnToCloud(q: String, a: String) {
        guard cloudSyncEnabled else { return }   // "Back up session history", as on Windows
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
            session.creditsKnown = true
            creditsRetryAttempt = 0
            session.plan = result.plan
            session.isUnlimited = result.isUnlimited
            dlog("Credits: \(result.credits), plan=\(result.plan), unlimited=\(result.isUnlimited)", tag: "CREDITS")
            updateCreditsUI(credits: result.credits, plan: result.plan, isUnlimited: result.isUnlimited)
            await fetchListeningTime()
        } else {
            dlog("Credits fetch failed — no result returned", tag: "CREDITS")
            // Say "checking", never "none". And ask again soon: the next scheduled refresh is
            // five minutes away, and the badge and the answers should not wait for it.
            updateCreditsUI(credits: session.credits, plan: session.plan, isUnlimited: session.isUnlimited)
            scheduleCreditsRetry()
        }
    }

    private var creditsRetryAttempt = 0
    private var creditsRetryTask: Task<Void, Never>?

    /// 4, 10, 20, then 40 seconds, then the five-minute refresh takes over.
    private func scheduleCreditsRetry() {
        guard creditsRetryAttempt < 4 else { return }
        let wait = [4.0, 10.0, 20.0, 40.0][creditsRetryAttempt]
        creditsRetryAttempt += 1
        creditsRetryTask?.cancel()
        creditsRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.fetchCredits()
        }
    }

    // ── Answers, as a customer sees them ───────────────────────────────────────
    //
    // Customers never see the word "credits", and never see listening time. The badge
    // used to read "⚡ 1.5k   ⏱ 9h 49m": a credit balance nobody can price against an
    // interview, next to a fair use guard that was never meant to be a meter. It says
    // answers now, rounded DOWN so it never overstates. Words and numbers: PlanFacts.

    /// On the one-time free answers rather than a paid plan. A guest counts.
    var onFreeTrial: Bool {
        !session.isUnlimited &&
        PlanFacts.isFreeTrial(plan: session.plan, signedIn: session.isLoggedIn && !session.isGuestSession)
    }

    /// The hover text on the answers badge.
    var creditsTooltip: String {
        if session.isUnlimited { return "Unlimited answers.\nClick for details." }
        if !session.creditsKnown { return "Checking how many answers you have left.\nClick to try again." }
        return PlanFacts.tooltip(credits: session.credits, freeTrial: onFreeTrial,
                                 listeningLimitReached: audioMinutesRemaining == 0)
    }

    // ── Saying WHY nothing is being heard ─────────────────────────────────────────────
    //
    // Every one of these used to be a small coloured label and nothing else. The words live
    // in ListeningProblems, where a test fails if a problem has none.
    private var problemsShown = Set<ListeningProblems.Kind>()
    private var lastProblemCheckAt = Date.distantPast
    private(set) var currentProblem: ListeningProblems.Kind?
    /// Whether the Mac has a network path at all. Owned by a small class of its own, because
    /// this view model is @Observable and cannot hold a lazily-started monitor.
    private let network = NetworkReachability.shared

    /// How long an engine may take to connect before it counts as stalled (Windows: 25s).
    private static let connectPatience: TimeInterval = 25

    private func tickListeningProblem() {
        let now = Date()
        guard now.timeIntervalSince(lastProblemCheckAt) >= 2 else { return }
        lastProblemCheckAt = now
        guard session.isLoggedIn else { currentProblem = nil; return }

        let stalled = !engine.isReady && engine.isRunning &&
            (engine.startedAt.map { now.timeIntervalSince($0) > Self.connectPatience } ?? false)
        let problem = ListeningProblems.detect(
            engineOnline: engine.isReady,
            speechStatusCode: session.speechKeyLastStatus,
            outOfListeningTime: session.speechOutOfListeningTime,
            outOfAnswers: session.speechOutOfAnswers,
            waitingToRetry: now < session.speechRetryAfter,
            fatalNoMicrophone: micCaptureEnabled && micStatus == "NO MIC" && AVCaptureDevice.authorizationStatus(for: .audio) == .denied,
            connectionStalled: stalled,
            noNetwork: !network.isUp,
            anotherDevice: engine.accountBusy,
            poorConnection: network.isUp && engine.connectionIsPoor)
        currentProblem = problem
        if let problem { showProblemOnce(problem) } else { problemsShown.removeAll() }
    }

    /// Said once per occurrence, in words. A problem that clears and comes back is said again.
    private func showProblemOnce(_ kind: ListeningProblems.Kind) {
        guard problemsShown.insert(kind).inserted else { return }
        let d = ListeningProblems.describe(kind, freeTrial: onFreeTrial)
        dlog("Problem shown to the user: \(kind)", tag: "MODE")
        let action: (label: String, run: () -> Void)?
        switch d.step {
        case .moreAnswers: action = ("Get more answers", { NSWorkspace.shared.open(PlanFacts.addAnswersURL) })
        case .seePlans:    action = ("See plans", { NSWorkspace.shared.open(PlanFacts.pricingURL) })
        case .none:        action = nil
        }
        showAlert(title: d.title, body: d.body, actionLabel: action?.label ?? "", action: action?.run)
    }

    /// Clicking the answers badge asks again at once. Someone who just upgraded or added
    /// answers must not sit behind a refusal the app remembers for five minutes.
    func askAgainNow() {
        guard session.isLoggedIn else { return }
        session.forgetRefusal()
        problemsShown.removeAll()
        dismissAlert()
        Task { [weak self] in
            guard let self else { return }
            await self.fetchCredits()
            if await self.session.fetchSpeechmaticsKeyAsync(forceRefresh: true, userInitiated: true) {
                if !self.engine.isRunning { self.engine.start(smKey: self.session.speechmaticsKey) }
            }
        }
    }

    // ── Unmute must be CONFIRMED ──────────────────────────────────────────────────────
    //
    // Deleting the pause flag is the real "microphone on" operation; the booleans only update
    // the screen. A restart or a late write can put the flag back a moment after the delete,
    // and the result is a split state: the window says LISTENING while every engine heartbeat
    // stays paused, until the person tries Space again a minute later. Windows saw exactly
    // that in a live run (16:42:23). So: look again at 40, 100, 250 and 500 ms, remove a late
    // flag, stop at once if this turn has already ended, and if it never clears, say so.
    private var listenTurnID = UUID()

    private func confirmCaptureResumed(_ turn: UUID) {
        Task { [weak self] in
            for delayMs in [40, 100, 250, 500] {
                try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                guard let self, self.listenTurnID == turn, self.isListening else { return }
                if FileManager.default.fileExists(atPath: self.engine.pauseFlagPath.path) {
                    dlog("MIC: the pause flag came back \(delayMs)ms after unmuting — clearing it", tag: "MIC")
                    self.engine.deletePauseFlag()
                }
            }
            guard let self, self.listenTurnID == turn, self.isListening else { return }
            if FileManager.default.fileExists(atPath: self.engine.pauseFlagPath.path) {
                dlog("MIC: the pause flag would not clear — the engine is still paused", tag: "MIC")
                self.showListeningNotice("MICROPHONE COULD NOT START. PRESS SPACE TO RETRY")
            }
        }
    }

    /// Out of answers: say so in words, and offer the one next step that fixes it.
    /// A free trial reads as the end of a trial (what Pro gives), a paid plan as answers
    /// that renew. The button opens the account page, where answers can be added without
    /// a subscription, and the plans are offered too.
    func showOutOfAnswers() {
        let m = PlanFacts.outOfAnswers(freeTrial: onFreeTrial)
        aiAnswer = "\(m.title)\n\n\(m.body)"
        showAlert(title: m.title, body: m.body, actionLabel: "Get more answers") {
            NSWorkspace.shared.open(PlanFacts.addAnswersURL)
        }
        dlog("Out of answers — told the user (free trial=\(onFreeTrial))", tag: "CREDITS")
    }

    private func updateCreditsUI(credits: Int, plan: String, isUnlimited: Bool) {
        showCreditsBadge = true
        creditsIcon = ""
        // A balance that was never fetched is not a balance of zero. See PlanFacts.mayAsk.
        if !session.creditsKnown && !isUnlimited {
            creditsText = "Checking answers"
            creditsColor = Color(white: 0.62)
            creditsPlanText = "Checking"
            return
        }
        if isUnlimited {
            // A retired unlimited account. Nobody can buy this now; it still has to read right.
            creditsText = "Unlimited"
            creditsColor = Color(red: 167/255, green: 139/255, blue: 250/255)
            creditsPlanText = "Unlimited"
            return
        }
        creditsText = PlanFacts.badgeText(credits)
        let free = PlanFacts.isFreeTrial(plan: plan, signedIn: session.isLoggedIn && !session.isGuestSession)
        creditsPlanText = free ? "Free trial" : "\(plan.capitalized) plan"
        if PlanFacts.isEmpty(credits) {
            creditsColor = Color(red: 239/255, green: 68/255, blue: 68/255)
            creditsPlanText = "Get more answers"
        } else if PlanFacts.isLow(credits) {
            creditsColor = Color(red: 245/255, green: 158/255, blue: 11/255)
        } else {
            creditsColor = Color(red: 74/255, green: 222/255, blue: 128/255)
        }
        // Listening time is deliberately NOT shown: it is a hidden fair use guard, not a
        // meter. Reaching it is explained in words (tooltip, and the listening message).
        if audioMinutesRemaining == 0 {
            creditsColor = Color(red: 245/255, green: 158/255, blue: 11/255)
            creditsPlanText = "Listening limit reached"
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
            // The overlay window is created fresh here on its first-ever show — re-apply
            // Stealth so a freshly-created window picks up the current setting too, not
            // just the main panel (which was already covered at launch).
            applyStealthMode()
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
        saveSettings()
        dlog("Pin-on-top \(isPinnedOnTop ? "ON" : "OFF")", tag: "WINDOW")
    }

    func setScreenKeysEverywhere(_ on: Bool) {
        screenKeysEverywhere = on
        hotkey?.setScreenKeysEverywhere(on)
        saveSettings()
        dlog("Screen keys everywhere: \(on ? "ON" : "OFF — plain F8/F9 go to other apps; ⌃⌥F8/F9 still work")", tag: "HOTKEY")
    }

    /// ⌃⌥R from any app. Raises whichever window is in use — the compact overlay when that is
    /// showing, so it does not pull the hidden main window over it (Windows fbca2c6).
    func bringToFront() {
        dlog("⌃⌥R — bringing Replysis to the front", tag: "WINDOW")
        if showCameraOverlay, let overlay = AnswerOverlayWindow.shared {
            overlay.orderFrontRegardless()
        } else {
            mainPanel?.orderFrontRegardless()
            mainPanel?.makeKey()
        }
    }

    func signOut() {
        PresenceTracker.shared.stop()
        // Stop eye-mode overlay so its NSPanel and timers don't outlive the session.
        if showCameraOverlay { exitCamera() }
        // BUG-16 FIX: stop watch mode before clearing the session — otherwise the 8s
        // timer keeps firing _doScreenCapture() with an expired idToken after sign-out.
        if isWatchMode {
            isWatchMode = false
        }
        engine.stop(); session.clear(); setLoggedOutUI()

        // BUG FIX: signOut() previously left the user in a fully logged-out state with
        // no follow-up — the only way back to the free-trial guest state was quitting and
        // relaunching the app (restoreSession() starts a guest session on boot, but nothing
        // did the equivalent here). Mirror that same boot-time guest-session logic so
        // signing out drops straight back into the guest trial instead of a dead end.
        Task { @MainActor in
            let guestOk = await session.startGuestSession()
            guard guestOk else { return }   // offline, or this device's free trial is used up —
                                             // falls back to the existing "not signed in" state
            refreshHotkeyGate()
            profileName = "Guest"; profilePlan = "Free trial"; avatarInitials = "GU"
            updateCreditsUI(credits: session.credits, plan: session.plan, isUnlimited: session.isUnlimited)
            // Same timer-restart fix as onLoginSuccess() — setLoggedOutUI() just stopped
            // these, and onAppear (the only other place that starts them) runs once per
            // launch, so without this the guest session would render with dead timers.
            startTranscriptTimer(); startThinkingTimer(); startCreditsTimer()
            let smOk = await session.fetchSpeechmaticsKeyAsync()
            startNewSession()
            if smOk && !engine.isRunning {
                engine.start(smKey: session.speechmaticsKey)
            }
        }
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
        // Tighten a file left behind by an older build, the way the debug log does. Fixing
        // this only on write would leave every existing user's work authorization and pay
        // expectations world-readable until they happened to edit their job context again.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        if let data = try? Data(contentsOf: path),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            companyName = obj["company"] ?? ""
            jobDescription = obj["description"] ?? ""
            // Missing keys stay "Not specified" — an older job.json has none of these, and
            // defaulting a work authorization would be exactly the invention this avoids.
            workType     = obj["workType"]     ?? Self.notSpecified
            workAuth     = obj["workAuth"]     ?? Self.notSpecified
            canStart     = obj["canStart"]     ?? Self.notSpecified
            workLocation = obj["workLocation"] ?? Self.notSpecified
            payRate      = obj["payRate"]      ?? ""
        }
    }

    func saveJob() {
        let path = engine.appDataFolder.appendingPathComponent("job.json")
        let obj = ["company": companyName, "description": jobDescription,
                   "workType": workType, "workAuth": workAuth, "canStart": canStart,
                   "workLocation": workLocation, "payRate": payRate]
        try? JSONSerialization.data(withJSONObject: obj).write(to: path)
        // 0600, like the transcripts and the debug log. This file holds work authorization,
        // pay expectations, availability and the job description — and it was landing
        // world-readable (measured -rw-r--r--), so on a shared or managed Mac any other local
        // account could read it. The app already protects everything else it writes; this
        // writer and the settings one were simply missed.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    // MARK: - Settings
    func loadSettings() {
        let path = engine.appDataFolder.appendingPathComponent("settings.json")
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        if let data = try? Data(contentsOf: path),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            mainWindowOpacity = obj["mainOpacity"] as? Double ?? 0.40
            overlayOpacity = obj["overlayOpacity"] as? Double ?? 0.90
            // Short by default. The old Concise brevity mode is gone (Windows has none), so a
            // saved "concise" choice simply becomes Short.
            answerDetailed = (obj["answerLength"] as? String) == "detailed"
            PromptBuilder.shared.detailedAnswers = answerDetailed
            // Default ON: system audio + the user's own voice, so Space captures both out
            // of the box. Users who want to stay fully invisible in a real interview can
            // switch to system-audio-only in Settings.
            // Default for NEW installs is Interview (no microphone). Anyone who has saved a
            // choice keeps it — the key is present in their settings file.
            micCaptureEnabled = obj["micCaptureEnabled"] as? Bool ?? false
            transcriptLanguage = obj["transcriptLanguage"] as? String ?? "en"
            cloudSyncEnabled = obj["cloudSyncEnabled"] as? Bool ?? true
            sarvamApiKey = obj["sarvamApiKey"] as? String ?? ""
            isWatchMode = obj["screenAnswers"] as? Bool ?? true
            listeningMode = ListeningMode.fromStored(obj["listeningMode"] as? String)
                ?? ((obj["autoModeEnabled"] as? Bool ?? false) ? .auto : .manual)
            // Default ON: hidden from screen sharing/recording out of the box. Settings
            // can turn it off for anyone who wants the window visible in a recording.
            stealthModeEnabled = obj["stealthModeEnabled"] as? Bool ?? true
            isPinnedOnTop = obj["keepOnTop"] as? Bool ?? true
            screenKeysEverywhere = obj["screenKeysEverywhere"] as? Bool ?? true
            mainPanel?.level = isPinnedOnTop ? .floating : .normal
            hotkey?.setScreenKeysEverywhere(screenKeysEverywhere)

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
        let obj: [String: Any] = ["mainOpacity": mainWindowOpacity,
                                  "overlayOpacity": overlayOpacity, "answerLength": answerDetailed ? "detailed" : "short",
                                  "micCaptureEnabled": micCaptureEnabled,
                                  "transcriptLanguage": transcriptLanguage,
                                  "cloudSyncEnabled": cloudSyncEnabled,
                                  "sarvamApiKey": sarvamApiKey,
                                  "screenAnswers": isWatchMode,
                                  "listeningMode": listeningMode.rawValue,
                                  "stealthModeEnabled": stealthModeEnabled,
                                  "keepOnTop": isPinnedOnTop,
                                  "screenKeysEverywhere": screenKeysEverywhere,
                                  "opacityDefaultV2Applied": true]
        try? JSONSerialization.data(withJSONObject: obj).write(to: path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    // MARK: - Audio capture mode (Settings toggle)

    /// On (default) = system audio + the user's own voice via the microphone, so Space
    /// captures both the interviewer AND what the user says. macOS shows its orange mic
    /// indicator while actively listening (this cannot be hidden — it's an OS privacy
    /// guarantee no app can bypass), but the mic only records during those moments.
    /// Off = system-audio-only: only the interviewer is transcribed, the mic is NEVER
    /// opened, so there's no orange indicator — fully invisible, for users who want to
    /// stay hidden in a real interview with nothing to reveal if the mic icon is checked.
    var micCaptureEnabled = false

    /// "Back up session history": mirrors questions and answers to the account, so they
    /// appear in Past Sessions on the other signed-in devices. On by default, as on
    /// Windows; off keeps every transcript on this Mac only.
    var cloudSyncEnabled = true

    func setCloudSyncEnabled(_ enabled: Bool) {
        guard cloudSyncEnabled != enabled else { return }
        cloudSyncEnabled = enabled
        saveSettings()
        dlog("Cloud session backup \(enabled ? "on" : "off")", tag: "SETTINGS")
    }

    // ── Interview language ────────────────────────────────────────────────────
    //
    // The engine hears ONLY this language (--language), so it has to match the interview:
    // speech in another language comes back as garbled words in this one. Same list and
    // codes as Windows, so a transcript is the same on both. Telugu and the other Indian
    // languages Speechmatics cannot do are routed by the engine to Sarvam AI, which needs
    // a key in Settings; without one they stay unavailable and the picker says so.
    static let interviewLanguages: [(name: String, code: String)] = [
        ("English", "en"), ("Hindi", "hi"), ("Tamil", "ta"), ("Telugu (Sarvam AI)", "te"),
        ("Bengali", "bn"), ("Marathi", "mr"), ("Urdu", "ur"), ("Spanish", "es"),
        ("French", "fr"), ("German", "de"), ("Portuguese", "pt"), ("Italian", "it"),
        ("Mandarin Chinese", "cmn"), ("Japanese", "ja"), ("Korean", "ko"),
        ("Arabic", "ar"), ("Russian", "ru"),
    ]
    /// Codes the engine routes to Sarvam AI. Keep in sync with SARVAM_LANG_MAP in
    /// speechmatics_engine.py and with Windows _sarvamLangs.
    static let sarvamLanguages: Set<String> = ["te", "kn", "ml", "gu", "pa", "or", "as"]

    var transcriptLanguage = "en"
    var sarvamApiKey = ""

    var interviewLanguageName: String {
        Self.interviewLanguages.first { $0.code == transcriptLanguage }?.name ?? "English"
    }

    func setInterviewLanguage(_ code: String) {
        guard transcriptLanguage != code else { return }
        transcriptLanguage = code
        saveSettings()
        dlog("Interview language → \(code)", tag: "SETTINGS")
        // The language is read when the engine starts, so it has to restart. Never in the
        // middle of a question: the restart takes about a second and would cut it off.
        if isListening || isProcessing {
            languageChangePending = true
            showListeningNotice("LANGUAGE CHANGES AFTER THIS QUESTION")
            return
        }
        restartEngineForSettingChange()
    }

    private var languageChangePending = false

    func setSarvamApiKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sarvamApiKey != trimmed else { return }
        sarvamApiKey = trimmed
        saveSettings()
        dlog("Sarvam API key \(trimmed.isEmpty ? "cleared" : "set")", tag: "SETTINGS")
        if Self.sarvamLanguages.contains(transcriptLanguage), !isListening, !isProcessing {
            restartEngineForSettingChange()
        }
    }

    /// Restart the engine so a setting it reads at startup takes effect now.
    private func restartEngineForSettingChange() {
        guard engine.isRunning else { return }
        engine.stop()
        engine.start(smKey: session.speechmaticsKey)
    }

    // ── Interview / Practice ──────────────────────────────────────────────────
    //
    // The same preference the Settings switch writes, so the two can never disagree.
    // Practice means the microphone is open too. Ported from Windows (2026-09-20).
    var practiceAudioOn: Bool { micCaptureEnabled }
    private var audioSourceChangePending = false
    private var interviewTipShown = false
    private var practiceTipShown = false
    private var lastAudioSourceTipCheck = Date.distantPast
    /// An alert that can carry one action, for the two tips below.
    var alertTitle = ""
    var alertBody = ""
    var alertActionLabel = ""
    private var alertAction: (() -> Void)?

    func showAlert(title: String, body: String, actionLabel: String = "", action: (() -> Void)? = nil) {
        dlog("ALERT: \(title) — \(body)", tag: "ALERT")
        alertTitle = title; alertBody = body
        alertActionLabel = action == nil ? "" : actionLabel
        alertAction = action
    }

    func runAlertAction() {
        let act = alertAction
        dismissAlert()
        act?()
    }

    func dismissAlert() {
        alertTitle = ""; alertBody = ""; alertActionLabel = ""; alertAction = nil
    }

    /// Switches between hearing the meeting only and hearing the meeting plus the
    /// microphone. The engine is told by restarting it, which takes about a second, so it
    /// waits while a question is being listened to rather than cutting it off.
    func selectAudioSource(practice: Bool) {
        guard micCaptureEnabled != practice else { return }
        if isListening || isProcessing {
            micCaptureEnabled = practice          // the toolbar shows the new choice at once
            saveSettings()
            audioSourceChangePending = true
            showListeningNotice(practice ? "PRACTICE STARTS AFTER THIS QUESTION"
                                         : "INTERVIEW STARTS AFTER THIS QUESTION")
            dlog("Audio source → \(practice ? "Practice" : "Interview") — waiting for this question to finish", tag: "AUDIO")
            return
        }
        audioSourceChangePending = false
        setMicCaptureEnabled(practice)
        dlog(practice ? "Practice: hears the meeting and the microphone"
                      : "Interview: hears the meeting only", tag: "AUDIO")
    }

    /// Applies a switch that was asked for mid-question, once it is over.
    private func applyPendingAudioSourceChange() {
        guard audioSourceChangePending, !isListening, !isProcessing else { return }
        audioSourceChangePending = false
        let wanted = micCaptureEnabled
        micCaptureEnabled = !wanted          // so setMicCaptureEnabled sees a real change
        setMicCaptureEnabled(wanted)
        dlog("Audio source applied now the question is over → \(wanted ? "Practice" : "Interview")", tag: "AUDIO")
    }

    /// Says something only when the setting is about to cost the user an interview: the
    /// microphone is open with a meeting app running, or the app has been listening to
    /// silence for minutes with no meeting anywhere. Each tip at most once per launch.
    private func checkAudioSourceTip() {
        let now = Date()
        guard now.timeIntervalSince(lastAudioSourceTipCheck) >= 20 else { return }
        lastAudioSourceTipCheck = now
        applyPendingAudioSourceChange()
        if languageChangePending, !isListening, !isProcessing {
            languageChangePending = false
            restartEngineForSettingChange()
            dlog("Interview language applied now the question is over", tag: "SETTINGS")
        }
        guard session.isLoggedIn, alertTitle.isEmpty else { return }

        let practice = practiceAudioOn
        let meeting = AudioSourceRules.meetingAppRunning()

        if AudioSourceRules.shouldSuggestInterview(practiceOn: practice, meetingAppRunning: meeting,
                                                   alreadySuggested: interviewTipShown) {
            interviewTipShown = true
            showAlert(title: "In a real interview?",
                      body: "Replysis can hear your microphone, so your own answers can be taken as new questions. Interview hears the meeting only.",
                      actionLabel: "Switch to Interview") { [weak self] in
                self?.selectAudioSource(practice: false)
            }
            return
        }

        let quiet = heardAnythingThisSession ? now.timeIntervalSince(lastSpeechHeardAt) : 0
        // "Listening" here has to include the standby the quiet itself causes. Measured:
        // the mic stops after 3 minutes of silence (stopForIdle) at the same moment this
        // rule's 3 minutes elapse, so a strict isListening meant the tip could never fire.
        // Standby after a quiet stretch is the same evidence — the app is armed and
        // nothing is being said to it.
        let armed = isListening || (stoppedForIdle && autoModeEnabled)
        if AudioSourceRules.shouldSuggestPractice(interviewOn: !practice, listening: armed,
                                                  meetingAppRunning: meeting, quietFor: quiet,
                                                  alreadySuggested: practiceTipShown) {
            practiceTipShown = true
            showAlert(title: "Practising on your own?",
                      body: "Interview hears the meeting only, so nothing you say is picked up. Practice hears your microphone too.",
                      actionLabel: "Switch to Practice") { [weak self] in
                self?.selectAudioSource(practice: true)
            }
        }
    }

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
        } else if enabled && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            // BUG FIX: re-warm the mic hardware the moment the user switches BACK to
            // "+ my voice". MicPrimer.stop() (below, other branch) tears down the AVAudioEngine
            // that keeps the mic hardware warm — without a counterpart here, switching back on
            // left the engine restart below to open the mic cold, paying the ~18-20s one-time
            // OS hardware wake-up cost itself (see MicPrimer.swift) with nothing transcribed
            // from the mic in the meantime. Looked exactly like "the mic is broken" until it
            // silently recovered on its own a bit later.
            primeMicIfPermitted()
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

    // MARK: - Auto Mode

    /// Turn Auto Mode on or off. When switched on mid-session it starts listening straight
    /// away, so the very next thing the interviewer says is already being heard — waiting
    /// for the user to also press Space would defeat the entire point.
    /// Switch how questions start. Applies immediately: Interview Auto and Practice Auto
    /// begin listening straight away, because waiting for the user to ALSO press Space
    /// would defeat the entire point of an automatic mode.
    func setListeningMode(_ mode: ListeningMode) {
        guard listeningMode != mode else { return }
        let previous = listeningMode
        listeningMode = mode
        saveSettings()
        dlog("Listening mode: \(previous.rawValue) -> \(mode.rawValue)", tag: "AUTO")
        // The one case Auto cannot handle is the candidate's own answer, spoken as a
        // sentence, heard through an open microphone. In a real call the interviewer comes
        // through computer sound, so turning the mic off removes it entirely — but people only
        // do that if they are told. Once per launch, and only with the mic on.
        if mode == .auto, micCaptureEnabled, !micOffHintShown {
            micOffHintShown = true
            showMicOffHint = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.showMicOffHint = false }
        }
        // Clear what the PREVIOUS mode produced. Leaving the old answer on screen made a
        // mode that had correctly stayed silent look like it had answered wrongly — the
        // user reads a stale reply and blames the new mode for it. Also drops any
        // half-heard transcript, which belongs to the old capture source.
        answerEpoch += 1
        isProcessing = false
        showThinking = false
        aiAnswer = ""
        transcript = ""
        resetAutoTurnState()
        // Picking a mode IS the deliberate "start listening" action, so it clears the idle
        // stop. Without this the latch survived the mode change and blocked the re-arm: the
        // pill lit up, the microphone stayed shut, and nothing on screen said why. Only a
        // Space press could clear it — in the one mode built so Space never has to be
        // pressed.
        stoppedForIdle = false
        listeningNoticeTimer?.invalidate(); listeningNotice = ""
        aiAnswerHint = idleHintForCurrentMode
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.engine.clearLatestTxt()
            self?.engine.writeResetFlag()
        }

        // Auto and Manual no longer restart the engine. The flip used to change which audio
        // was open, so it had to; it cannot any more, and the restart was a visible stall on
        // every change.

        guard mode.isAutomatic else {
            // Back to manual: stop listening rather than leaving the mic silently open.
            if isListening {
                isListening = false; isMuted = true
                engine.writePauseFlag()
                updateMicUI()
            }
            return
        }

        // Starting an automatic mode has to actually START it, including what Space would
        // have done on the user's behalf. Failing silently here is what made the pill light
        // up while the mic stayed exactly as it was.
        guard session.isLoggedIn else {
            dlog("AUTO: not signed in — prompting sign-in", tag: "AUTO")
            NotificationCenter.default.post(name: .showLogin, object: nil)
            return
        }
        if !engine.isRunning {
            let key = session.speechmaticsKey
            guard !key.isEmpty else {
                micStatus = "NO MIC"; micColor = Color(white: 0.42)
                aiAnswer = "⚠ Automatic listening needs the speech service, which isn't available right now.\n\nRetrying automatically — or click the NO MIC badge."
                engine.startRetryTimer()
                return
            }
            engine.start(smKey: key)
        }
        aiAnswerHint = idleHintForCurrentMode
        rearmAutoModeIfNeeded()
    }

    /// Nothing may be captured: the system tap could not start and the microphone is switched off.
    private func handleCaptureUnavailable() {
        isListening = false; isMuted = true
        micStatus = "NO AUDIO"; micColor = Color(white: 0.42)
        showThinking = false; isProcessing = false
        let why = "Your microphone is switched off in Settings, and macOS is not allowing system audio capture right now, most often because Screen Recording is turned off for this app.\n\nEnable Screen Recording in System Settings > Privacy & Security, then click NO AUDIO to retry. Or turn on Use my microphone in Settings."
        aiAnswer = "⚠ " + why
        dlog("AUTO: capture unavailable with the microphone switched off", tag: "AUTO")
        updateMicUI()
    }

    // MARK: - Stealth Mode (Settings toggle)

    /// Default ON: hides the window from ALL screen capture — Zoom/Meet/Teams screen
    /// sharing, screen recording, QuickTime — so the interviewer never sees it even while
    /// you share your screen. The user still sees it normally; this only affects what a
    /// *capture* of the screen contains, not your own display.
    var stealthModeEnabled = true

    /// Push the current Stealth Mode setting to the actual windows. Safe to call anytime —
    /// no-ops on any window that doesn't exist yet (e.g. Eye Mode never opened this run).
    /// Called on launch (so the default-ON state takes effect immediately) and whenever a
    /// window is freshly created or the Settings toggle changes.
    private func applyStealthMode() {
        // TWO WINDOWS IS THE WHOLE LIST, and sheets are covered by the first of them.
        //
        // Settings, Past Sessions, Login, the permission setup and the DEBUG LOG — which
        // shows live transcripts — are all .sheet on the main panel. A sheet is its own
        // NSWindow and sharingType is per-window, so whether they inherit stealth is a real
        // question rather than an obvious yes. Measured with CGWindowListCopyWindowInfo
        // against the running app: every window this process owns reports sharing=0,
        // including a 480x560 sheet while the 1326x740 panel was open. They inherit.
        //
        // Worth keeping measured rather than assumed. A debug window showing transcripts
        // while visible in a screen share defeats the feature the product is bought for,
        // and it is invisible to the person it exposes. Windows had exactly that leak.
        let type: NSWindow.SharingType = stealthModeEnabled ? .none : .readOnly
        mainPanel?.sharingType = type
        AnswerOverlayWindow.shared?.sharingType = type
    }

    /// Called from Settings when the user switches Stealth Mode. Applies immediately —
    /// no relaunch needed.
    func setStealthModeEnabled(_ enabled: Bool) {
        guard stealthModeEnabled != enabled else { return }
        stealthModeEnabled = enabled
        saveSettings()
        dlog("Stealth mode changed → stealthModeEnabled=\(enabled)", tag: "SETTINGS")
        applyStealthMode()
    }

    // MARK: - Helpers
    func clearAnswer() {
        resumeLocked = false
        answerEpoch += 1   // invalidate any in-flight stream so it can't re-populate
        transcript = ""; aiAnswer = ""; lastQuestionShown = ""; answerIsBehavioral = false
        aiAnswerHint = idleHintForCurrentMode
        PromptBuilder.shared.clearHistory()
        disarmScrollWatch()
        resetAutoTurnState()
        engine.clearLatestTxt()
        stopThinkingUI()
    }

    /// Both states mean "no audio is reaching the app, tap to try again". NO AUDIO was
    /// initially invisible to the header, so the one control that recovers from it did
    /// nothing when clicked.
    /// Is the microphone in play right now? Only the Settings switch decides it since the
    /// modes merged. Anything that prompts for, warms, or complains about the mic asks this.
    var micCaptureActive: Bool { micCaptureEnabled }

    private func primeMicIfPermitted() {
        guard micCaptureActive,
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            dlog("MicPrimer suppressed — micCaptureEnabled=\(micCaptureEnabled) mode=\(listeningMode.rawValue)", tag: "AUTO")
            return
        }
        MicPrimer.shared.start()
    }

    var micNeedsRetry: Bool { micStatus == "NO MIC" || micStatus == "NO AUDIO" }

    func retryMic() {
        // Manual retry from the NO MIC / NO AUDIO badge. Always re-fetch + restart (even if a
        // key exists) — the existing key may be the rejected one we're trying to replace.
        guard session.isLoggedIn else { return }
        // A capture refusal is not a key problem: the user has just granted Screen Recording
        // and wants another attempt at the tap. Clear the message so a stale refusal doesn't
        // sit on screen after a successful retry.
        if micStatus == "NO AUDIO" {
            aiAnswer = ""; aiAnswerHint = idleHintForCurrentMode
            engine.allowSystemAudioRetry()   // the user may have just granted Screen Recording
        }
        micStatus = "…"; micColor = Color(white: 0.42)
        Task {
            // The user is retrying BECAUSE something was refused, so bypass the cache. This
            // is the one path that should spend a fresh token from the hourly allowance.
            let ok = await session.fetchSpeechmaticsKeyAsync(forceRefresh: true, userInitiated: true)
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
        // Remembered so the recovery can put things back as they were, rather than leaving a
        // muted app showing a warning about a service that has already come back.
        wasListeningBeforeKeyError = isListening || (autoModeEnabled && !stoppedForIdle)
        keyErrorNoticeShowing = true
        isListening = false; isMuted = true
        micStatus = "NO MIC"; micColor = Color(white: 0.42)
        // Two different failures arrive down this path and they are not the user's to
        // confuse. A rejected key is ours to fix and they can only wait; an exhausted
        // balance is an account that needs topping up, and saying "server-side key issue"
        // there sends them to wait for something nobody is coming to fix.
        if engine.balanceExhausted {
            aiAnswer = """
            ⚠ Live transcription is paused

            The speech account has run out of credit, so Speechmatics is refusing new \
            connections. Retrying cannot fix this — the balance has to be topped up.

            Everything else still works:

            • Type your question in the Ask bar below to get an instant answer
            • Press F9 to analyze whatever is on your screen

            Transcription resumes by itself, within about ten minutes, once billing is restored.
            """
            return
        }
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
        Self.questionText(from: text)
    }

    /// What the model is actually asked, from whatever has been heard.
    ///
    /// Every path that answers goes through here, because they disagreed. The turn was decided
    /// on cleaned text while the request was built from the raw transcript read 150ms later, so
    /// the decision said "Tell me about a time you handled a production outage." and the model
    /// was asked "... So in my last" — the candidate's first words, already starting to answer.
    ///
    /// In order: the doubled hearing collapses (speakers into the microphone), the greeting
    /// goes, then a stall or the candidate's own words on the end. Capped, because a transcript
    /// that has grown for a whole session must never be posted as one question.
    static func questionText(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.lowercased().hasPrefix("[screen") { return trimmed }
        let cleaned = AutoTurnDetector.withoutCandidateTail(
            AutoTurnDetector.stripTrailingStalls(
                AutoTurnDetector.stripLeadingPleasantries(
                    AutoTurnDetector.collapseRepeats(trimmed))))
        let words = cleaned.split(separator: " ")
        return words.count > 150 ? words.suffix(150).joined(separator: " ") : cleaned
    }

    /// Marker that separates the spoken answer from the glanceable depth notes (RULE 14).
    static let moreToSayMarker = "MORE TO SAY"

    private func cleanAIOutput(_ text: String) -> String {
        // Split at the depth marker FIRST. The two halves need opposite treatment: the
        // spoken half must have no list punctuation at all, while the depth half is a list
        // and must keep its bullets. Running one pass over both destroyed the bullets.
        // U+2011 non-breaking hyphen, U+2012 figure dash and U+2212 minus, to a plain hyphen.
        // The dash rewrite below only knew em and en dashes, and this model writes compound
        // adjectives with U+2011 constantly: "statically‑typed", "key‑value", "real‑time". It
        // renders as a hyphen that refuses to wrap, which throws the whole compound onto its
        // own line in the narrow overlay. Windows a191a81.
        let text = text.replacingOccurrences(of: "\u{2011}", with: "-")
                       .replacingOccurrences(of: "\u{2012}", with: "-")
                       .replacingOccurrences(of: "\u{2212}", with: "-")
        let parts = text.components(separatedBy: Self.moreToSayMarker)
        let spoken = cleanSpoken(parts[0])
        guard parts.count > 1 else { return spoken }
        let depth = cleanDepth(parts.dropFirst().joined(separator: Self.moreToSayMarker))
        guard !depth.isEmpty else { return spoken }
        return spoken + "\n\n" + Self.moreToSayMarker + "\n" + depth
    }

    /// The half that is read aloud: strip markdown, and normalise dashes to commas so the
    /// candidate never has to voice an em-dash mid-sentence.
    private func cleanSpoken(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "```[a-zA-Z]*\n?", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "```", with: "")
        // Was `\*{1,3}([^*\n]+)\*{1,3}` — any paired asterisk, which shredded every line
        // of code that reached this path. See stripMarkdownPreservingCode.
        s = PromptBuilder.stripMarkdownPreservingCode(s)
        s = s.replacingOccurrences(of: " — ", with: ", ").replacingOccurrences(of: " – ", with: ", ")
             .replacingOccurrences(of: "—", with: ", ").replacingOccurrences(of: "–", with: ", ")
        for f in ["Certainly! ","Absolutely! ","Of course! ","Great question! ","Sure! ",
                  "I'd be happy to ","I'm happy to ","Good question! "] {
            s = s.replacingOccurrences(of: f, with: "")
        }
        while s.contains("\n\n\n") { s = s.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The half that is only glanced at. Asked for "•" the model often emits "-" or "*"
    /// anyway, which reads as a dash rather than a list — so convert leading markers to a
    /// real bullet here regardless of what it produced. Dashes are NOT touched: nothing in
    /// this section is spoken, and a hyphen mid-line is usually a range or a compound word.
    private func cleanDepth(_ text: String) -> String {
        var out: [String] = []
        for raw in text.components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            line = PromptBuilder.stripMarkdownPreservingCode(line)
            if line.isEmpty { continue }
            for marker in ["- ", "* ", "• ", "•", "- ", "– "] where line.hasPrefix(marker) {
                line = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
                break
            }
            if line.isEmpty { continue }
            out.append("• " + line)
        }
        return out.joined(separator: "\n")
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
