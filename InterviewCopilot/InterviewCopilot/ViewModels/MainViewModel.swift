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
    var mainWindowOpacity: Double = 1.0
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

    // Register the app in "Screen & System Audio Recording" (the full section).
    // On macOS Tahoe (16), CGDisplayCreateImage lands in "System Audio Recording Only"
    // instead — the correct API is ScreenCaptureKit's SCShareableContent which triggers
    // the proper full-screen-capture permission entry.
    func registerScreenRecording() {
        // SCShareableContent.getExcludingDesktopWindows registers the app in
        // "Screen & System Audio Recording" on macOS 12.3+ (including Tahoe).
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.permScreenRecording = CGPreflightScreenCaptureAccess()
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
    private let suppressTickCount = 7
    private var lastSpaceTime: Date = .distantPast
    private let spaceDebounceMs: Double = 0.4
    private var sessionNumber = 1
    private var sessionLogPath: URL?
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
            guard restored && !showProfile else { isRestoringSession = false; return }
            showProfile = true   // claim the mutex before any await below
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
        permScreenRecording = CGPreflightScreenCaptureAccess()
        let micStatus       = AVCaptureDevice.authorizationStatus(for: .audio)
        permMicrophone      = micStatus == .authorized
        micDenied           = micStatus == .denied

        if micStatus == .notDetermined {
            // Mic popup fires FIRST — before the permission sheet opens — so the
            // system dialog is clearly visible with nothing behind it. The gate
            // appears only after the user responds to the popup.
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    self.permMicrophone = granted
                    self.micDenied      = !granted
                    self.openGateIfNeeded()
                }
            }
            if permAccessibility { setupHotkeys(); hotkeyActive = true }
            return
        }

        openGateIfNeeded()

        if permAccessibility {
            setupHotkeys()
            hotkeyActive = true
        } else {
            hotkeyActive = false
        }
    }

    private func openGateIfNeeded() {
        if !permMicrophone || !permAccessibility || !permScreenRecording {
            if !permAccessibility { requestAccessibilityPrompt() }
            needsPermissionSetup = true
            startPermissionPolling()
        }
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
        needsPermissionSetup = true      // shows the (optional) setup sheet
        showHotkeyBanner = false
        startPermissionPolling()
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
        needsPermissionSetup = true
        showHotkeyBanner = false
        startPermissionPolling()
    }

    func requestMicrophonePermission() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.permMicrophone = granted
                self.micDenied = !granted   // BUG-12 FIX: was missing — UI showed wrong denied state
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
                self.permAccessibility   = AXIsProcessTrusted()
                let micStatus            = AVCaptureDevice.authorizationStatus(for: .audio)
                self.permMicrophone      = micStatus == .authorized
                self.micDenied           = micStatus == .denied
                self.permScreenRecording = CGPreflightScreenCaptureAccess()
                // Stop after 5 min from the first activation, even across multiple reopens.
                if let start = self.permPollingStarted, Date().timeIntervalSince(start) > 300 {
                    self.permTimer?.invalidate(); self.permTimer = nil
                    self.permPollingStarted = nil
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

    /// Relaunch the app cleanly: open a fresh instance, then quit this one. Used after
    /// Accessibility is granted so the global hotkey (CGEventTap) can register — it only
    /// works in a process that was already trusted at launch.
    static func relaunchApp() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        // BUG-10 FIX: check the error before quitting — if the new instance fails to open
        // (corrupt bundle, read-only volume) the old instance must NOT terminate, otherwise
        // the user is left with zero app instances and has to relaunch manually.
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            guard error == nil else {
                dlog("relaunchApp: failed to open new instance — \(error!.localizedDescription)", tag: "APP")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                NSApp.terminate(nil)
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
                // Only act when the MAIN window is key — never a sheet or the camera overlay.
                guard event.window is FloatingPanel else { return event }
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
        guard hotkey == nil else { return }
        hotkey = GlobalHotkey(
            onSpacePressed: { [weak self] in self?.handleSpacePress(source: "GLOBAL") },
            onF8Pressed:    { [weak self] in self?.runScreenAnalysis() },
            onF9Pressed:    { [weak self] in self?.runScreenAnalysis() },
            onF12Pressed:   { },
            onKillPressed:  { NSApplication.shared.terminate(nil) }
        )
    }

    // MARK: - Space Logic
    func handleSpacePress(source: String = "KEYBOARD") {
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

        // Permission gate — mic + accessibility required before first session.
        // Triggered on the user's first Space/mic press so the app is immediately
        // usable after install, but permissions are only requested when actually needed.
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
                    if granted && AXIsProcessTrusted() {
                        self.handleSpacePress(source: source)
                    } else {
                        self.openPermissionSetup()
                    }
                }
            }
            return
        }
        if micAuth != .authorized {
            openPermissionSetup()
            return
        }
        // BUG-19 FIX: mic is authorized — proceed even if Accessibility isn't granted.
        // The local key monitor works without Accessibility; the global Space tap is OPTIONAL.
        // Previously this gated on !AXIsProcessTrusted() too, blocking the whole app whenever
        // Accessibility was missing even though mic was authorized and the local monitor worked.

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
        }

        if isMuted {
            dlog("SPACE: unmuting → LISTENING", tag: "SPACE")
            isMuted = false; isListening = true
            justStartedListening = true; listenStartTicks = 0
            transcript = ""; aiAnswer = ""
            engine.clearLatestTxt()
            engine.writeResetFlag()
            engine.deletePauseFlag()
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
                self?.startAI()
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
        guard !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { updateMicUI(); return }
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
            finishAI(question: q, answer: builder.getOffTopicResponse()); return
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
                Task { await self.fetchCredits() }
            },
            onError: { [weak self] err in
                guard let self = self, self.answerEpoch == epoch else { return }
                if err == "NO_CREDITS"       { self.aiAnswer = "⚠ Not enough credits. Visit coopilotxai.com/pricing." }
                else if err == "SESSION_EXPIRED" { self.session.clear(); self.setLoggedOutUI() }
                else                         { self.aiAnswer = "⚠ Something went wrong. Please try again." }
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

        // Check Screen Recording permission BEFORE capturing — a capture without it only
        // shows the desktop wallpaper, wasting a vision call/credit (matches .NET).
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            aiAnswer = "⚠ Screen Recording permission needed.\n\n1. System Settings → Privacy & Security → Screen Recording\n2. Enable Interview Copilot\n3. Quit and reopen the app, then try again"
            return
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
        // Hide only the windows that are CURRENTLY visible, then restore exactly
        // those — so camera mode (main hidden, overlay shown) is preserved.
        let toHide = NSApplication.shared.windows.filter { $0.isVisible }
        for window in toHide { window.orderOut(nil) }
        try? await Task.sleep(nanoseconds: 350_000_000)
        let imageData = await captureScreen()
        for window in toHide { window.orderFrontRegardless() }

        guard let imageData = imageData, !imageData.isEmpty else {
            aiAnswer = "⚠ Screen capture failed.\n\nGrant Screen Recording permission:\nSystem Settings → Privacy & Security → Screen Recording"
            dlog("Screen capture returned empty data", tag: "SCREEN")
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
                if !self.isWatchMode {
                    self.aiAnswer = "⚠ Screen analysis error: \(err)"
                }
                self.stopThinkingUI()
            }
        )
    }

    private func captureScreen() async -> Data? {
        await withCheckedContinuation { continuation in
            // Run the blocking screencapture + sips OFF the main thread, or the whole UI
            // freezes for the duration of every F9 capture.
            DispatchQueue.global(qos: .userInitiated).async {
                let tmp = NSTemporaryDirectory() + "ic_screen_\(UUID().uuidString).png"
                let cap = Process()
                cap.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                cap.arguments = ["-x", "-t", "png", tmp]
                do { try cap.run() } catch { continuation.resume(returning: nil); return }
                cap.waitUntilExit()
                guard FileManager.default.fileExists(atPath: tmp) else {
                    continuation.resume(returning: nil); return
                }

                // Resize to max 1280px wide via sips (built into macOS) — a Retina PNG is
                // 5-8 MB; this keeps the vision payload small and fast (matches .NET).
                let resized = tmp + "_r.png"
                let sips = Process()
                sips.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
                sips.arguments = ["--resampleWidth", "1280", tmp, "--out", resized]
                try? sips.run(); sips.waitUntilExit()

                let readPath = FileManager.default.fileExists(atPath: resized) ? resized : tmp
                let data = try? Data(contentsOf: URL(fileURLWithPath: readPath))
                try? FileManager.default.removeItem(atPath: tmp)
                try? FileManager.default.removeItem(atPath: resized)
                continuation.resume(returning: data)
            }
        }
    }

    // MARK: - Transcript Polling
    private func startTranscriptTimer() {
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
        if isProcessing      { micStatus = "THINKING";  micColor = .orange }
        else if isListening  { micStatus = "LISTENING"; micColor = .green }
        else if isMuted      { micStatus = "MUTED";     micColor = Color(red: 239/255, green: 68/255, blue: 68/255) }
        else                 { micStatus = isRecording ? "RECORDING" : "READY"
                               micColor = Color(red: 239/255, green: 68/255, blue: 68/255) }
    }

    // MARK: - Session
    func startNewSession() {
        resumeLocked = false
        PromptBuilder.shared.clearHistory()
        let dir = engine.appDataFolder
        var num = sessionNumber
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent("interview_\(num).txt").path) { num += 1 }
        sessionNumber = num
        sessionLogPath = dir.appendingPathComponent("interview_\(num).txt")
        let resumeName = ResumeParser.extractName(resumeText)
        let header = "SESSION \(num) | \(useGroq ? "groq" : "openai") | \(Date()) | RESUME: \(resumeName)\n\n"
        if let path = sessionLogPath { try? header.write(to: path, atomically: true, encoding: .utf8) }
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
        liveHints = ""; saveHints()   // fresh interview → fresh hints
        aiAnswerHint = "New session started. Press SPACE to begin."
        startNewSession()
    }

    private func endSession() {
        isRecording = false; sessionLogPath = nil
        sessionTimerObj?.invalidate(); sessionTimerVisible = false
        PromptBuilder.shared.clearHistory()
    }

    private func appendToSessionLog(q: String, a: String) {
        guard let path = sessionLogPath else { return }
        let entry = "Q: \(q)\nA: \(a)\n\n"
        if let data = entry.data(using: .utf8),
           let handle = try? FileHandle(forWritingTo: path) {
            handle.seekToEndOfFile(); handle.write(data); handle.closeFile()
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
        creditsTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.fetchCredits() }
        }
    }

    // MARK: - Login / Logout
    func onLoginSuccess() {
        // BUG-4 FIX: guard with showProfile mutex before the Task — closes the TOCTOU
        // window where restoreSession() and continueAsSaved() both reach startNewSession().
        guard !showProfile else {
            dlog("onLoginSuccess: session already active — skipping duplicate start", tag: "AUTH")
            return
        }
        showProfile = true; profileName = session.firstName
        profilePlan = "\(session.plan) plan"; avatarInitials = session.initials
        showCreditsBadge = true
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

    // The main app window (the borderless FloatingPanel created in AppDelegate)
    private var mainPanel: NSWindow? {
        NSApplication.shared.windows.first { $0 is FloatingPanel }
    }

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

    // Camera mode OFF: hide the overlay and bring the main window back
    func exitCamera() {
        showCameraOverlay = false
        AnswerOverlayWindow.hide()
        mainPanel?.orderFrontRegardless()
    }

    // Pin on top: when ON the window floats above other apps (for the interview);
    // when OFF it's a normal window that goes behind apps you switch to.
    func togglePin() {
        isPinnedOnTop.toggle()
        mainPanel?.level = isPinnedOnTop ? .floating : .normal
        dlog("Pin-on-top \(isPinnedOnTop ? "ON" : "OFF")", tag: "WINDOW")
    }

    func signOut() {
        // BUG-16 FIX: stop watch mode before clearing the session — otherwise the 8s
        // timer keeps firing _doScreenCapture() with an expired idToken after sign-out.
        if isWatchMode {
            isWatchMode = false
            watchModeTimer?.invalidate(); watchModeTimer = nil
        }
        engine.stop(); session.clear(); setLoggedOutUI()
    }

    private func setLoggedOutUI() {
        showCreditsBadge = false; creditsText = "—"; endSession()
        showProfile = false
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
        try? resumeText.write(to: path, atomically: true, encoding: .utf8)
    }

    func saveHints() {
        let path = engine.appDataFolder.appendingPathComponent("hints.txt")
        try? liveHints.write(to: path, atomically: true, encoding: .utf8)
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
        try? resumeText.write(to: url, atomically: true, encoding: .utf8)
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
            mainWindowOpacity = obj["mainOpacity"] as? Double ?? 1.0
            overlayOpacity = obj["overlayOpacity"] as? Double ?? 0.90
            conciseAnswers = obj["concise"] as? Bool ?? false
        }
    }

    func saveSettings() {
        let path = engine.appDataFolder.appendingPathComponent("settings.json")
        let obj: [String: Any] = ["useGroq": useGroq, "mainOpacity": mainWindowOpacity,
                                  "overlayOpacity": overlayOpacity, "concise": conciseAnswers]
        try? JSONSerialization.data(withJSONObject: obj).write(to: path)
    }

    // MARK: - Helpers
    func clearAnswer() {
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
