import SwiftUI
import AppKit
import Observation
import AVFoundation
import IOKit.hid

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
    var needsPermissionSetup = false
    var permInputMonitoring = false    // REQUIRED for the global Space/F8/F9 hotkey (CGEventTap)
    var permAccessibility   = false
    var permMicrophone      = false
    var permScreenRecording = false
    private var permTimer: Timer?
    private var permPollCount = 0

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
    func requestAccessibilityPrompt() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
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
        Task {
            var restored = session.tryLoadFromDisk()
            if !restored && !session.refreshToken.isEmpty {
                restored = await session.tryRefreshAsync()
            }
            if restored {
                showProfile = true
                profileName = session.firstName
                profilePlan = "\(session.plan) plan"
                avatarInitials = session.initials
                showCreditsBadge = true
                await fetchCredits()
                let smOk = await session.fetchSpeechmaticsKeyAsync()
                startNewSession()
                if smOk {
                    engine.start(smKey: session.speechmaticsKey)
                } else {
                    micStatus = "NO MIC"
                    micColor = Color(white: 0.42)
                    aiAnswer = "Ready — speech service temporarily unavailable. Retrying automatically.\n\nClick NO MIC badge to retry, or use F9 to analyze screen."
                    engine.startRetryTimer()
                }
            }
        }
    }

    // MARK: - Permission Setup

    private func checkAndRequestPermissions() {
        permInputMonitoring = MainViewModel.inputMonitoringGranted()
        permAccessibility   = AXIsProcessTrusted()
        permMicrophone      = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        permScreenRecording = CGPreflightScreenCaptureAccess()

        // The global Space/F8/F9 hotkey (a keyboard CGEventTap) needs Input Monitoring;
        // AXIsProcessTrusted alone is NOT enough on modern macOS. Require both before we
        // even try to register the tap — otherwise it fails and the Space bar is dead.
        if permInputMonitoring && permAccessibility {
            setupHotkeys()
            if !permMicrophone {
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    Task { @MainActor in self.permMicrophone = granted }
                }
            }
            return
        }

        // Something required is missing — show the setup screen. Proactively fire BOTH
        // prompts so the app is REGISTERED in each Settings pane (otherwise the user opens
        // the list and the app isn't there to toggle — the #1 onboarding blocker). Each
        // system prompt also has its own "Open System Settings" button.
        if !permAccessibility   { requestAccessibilityPrompt() }
        if !permInputMonitoring { IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }
        needsPermissionSetup = true
        startPermissionPolling()
    }

    func requestMicrophonePermission() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in self.permMicrophone = granted }
        }
    }

    private func startPermissionPolling() {
        permTimer?.invalidate()
        permPollCount = 0
        permTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let hotkeyWasReady = self.permInputMonitoring && self.permAccessibility
                let imNow  = MainViewModel.inputMonitoringGranted()
                let axNow  = AXIsProcessTrusted()
                let micNow = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                let scrNow = CGPreflightScreenCaptureAccess()
                self.permInputMonitoring = imNow
                self.permAccessibility   = axNow
                self.permMicrophone      = micNow
                self.permScreenRecording = scrNow
                self.permPollCount += 1

                // Both hotkey permissions (Input Monitoring + Accessibility) just became
                // granted while we were running. Critical macOS fact: a global CGEventTap
                // CANNOT be created by a process that launched before it was authorized —
                // the grant flips true but tapCreate() keeps returning nil forever
                // (confirmed in the debug log). The ONLY reliable fix is to relaunch so the
                // fresh process is authorized from birth. Auto-relaunch: the app blinks
                // once and comes back with a working Space bar.
                let hotkeyReadyNow = imNow && axNow
                if hotkeyReadyNow && !hotkeyWasReady {
                    self.permTimer?.invalidate(); self.permTimer = nil
                    dlog("Hotkey permissions granted while running → relaunching to activate", tag: "PERM")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        MainViewModel.relaunchApp()
                    }
                }
            }
        }
    }

    /// Called when the user taps "Get Started" on the setup screen. The hotkey permissions
    /// were granted AFTER launch, so the event tap can't be created in this process —
    /// relaunch so the fresh process is authorized from birth and Space works.
    func permissionGrantedContinue() {
        permTimer?.invalidate(); permTimer = nil
        if MainViewModel.inputMonitoringGranted() && AXIsProcessTrusted() {
            MainViewModel.relaunchApp()
        } else {
            // Required permissions not fully granted yet — just proceed without hotkeys.
            needsPermissionSetup = false
        }
    }

    /// Relaunch the app cleanly: open a fresh instance, then quit this one. Used after
    /// Accessibility is granted so the global hotkey (CGEventTap) can register — it only
    /// works in a process that was already trusted at launch.
    static func relaunchApp() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApp.terminate(nil)
        }
    }

    // MARK: - Hotkeys
    private func setupHotkeys() {
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
        // If the user is typing in a text field, Space must type a space, NOT toggle the
        // mic. The global key tap fires for every keystroke, so guard it here.
        if isEditingText { return }

        dlog("SPACE pressed from \(source) | loggedIn=\(session.isLoggedIn) | engineRunning=\(engine.isRunning) | isMuted=\(isMuted) | isProcessing=\(isProcessing)", tag: "SPACE")

        guard !isProcessing else {
            dlog("SPACE ignored — AI is processing", tag: "SPACE"); return
        }
        let now = Date()
        guard now.timeIntervalSince(lastSpaceTime) >= spaceDebounceMs else {
            dlog("SPACE debounced", tag: "SPACE"); return
        }
        lastSpaceTime = now

        if !session.isLoggedIn {
            dlog("SPACE: user NOT logged in — spacebar works but no speechmatics (sign in first)", tag: "SPACE")
        }

        if session.isLoggedIn && !engine.isRunning && isMuted {
            let key = session.speechmaticsKey
            dlog("SPACE: engine not running, smKey length=\(key.count)", tag: "SPACE")
            if key.isEmpty {
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
            startAI()
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
        guard session.isLoggedIn else { aiAnswer = "⚠ Please sign in to use Screen Analysis."; return }

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
        guard isListening else { return }
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
        try? header.write(to: sessionLogPath!, atomically: true, encoding: .utf8)
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
        _ = await session.tryRefreshAsync()
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
        showProfile = true; profileName = session.firstName
        profilePlan = "\(session.plan) plan"; avatarInitials = session.initials
        showCreditsBadge = true
        Task {
            await fetchCredits()
            let smOk = await session.fetchSpeechmaticsKeyAsync()
            startNewSession()
            if smOk { engine.start(smKey: session.speechmaticsKey) }
            else { micStatus = "NO MIC"; micColor = Color(white: 0.42); engine.startRetryTimer() }
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

    func signOut() { engine.stop(); session.clear(); setLoggedOutUI() }

    private func setLoggedOutUI() {
        showProfile = false; showCreditsBadge = false; creditsText = "—"; endSession()
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
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("InterviewCopilot")
        let path = dir.appendingPathComponent("settings.json")
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
