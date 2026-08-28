import Foundation
import AVFoundation      // AVCaptureDevice — log the app's mic authorization for diagnostics
import AppKit            // NSAlert / NSWorkspace for the permission guidance dialog
import Darwin            // posix_spawn, pipe, kill, waitpid, dlsym

@MainActor
class SpeechmaticsEngine {
    static let shared = SpeechmaticsEngine()

    var isRunning = false
    var statusText = "READY"

    /// True once the Python engine has finished its (slow, ~10s) cold start and is actually
    /// connected and capturing — i.e. speaking now will really be transcribed. isRunning
    /// goes true the instant we spawn the process; isReady waits for it to be usable, so the
    /// UI can show "Starting…" instead of a green mic that silently drops the first words.
    var isReady = false

    /// Fired when the recogniser reports, from the AUDIO, that the speaker has stopped.
    /// This is the real end-of-turn signal; everything text-based is a guess at it.
    var onUtteranceEnd: (() -> Void)?

    // ── Is the engine DEAF? ───────────────────────────────────────────────────
    //
    // Three serious bugs have lived in the FIFO reader, and every one of them presented
    // identically from the app's side: engine running, connected, every status line
    // healthy, and not one word transcribed. Nothing in the app noticed, so it was found
    // by whoever happened to be watching.
    //
    // Two signals the engine already prints, neither useful alone. Audio arriving says
    // nothing — silence is normal. Words not arriving says nothing — a lull is normal. The
    // PAIR is decisive: audio going in and nothing coming out is the engine being deaf.
    /// What the engine says it was built from — commit, source hash and build time.
    ///
    /// The Mac shipped a 1,074-line fork of the shared engine for months while every build
    /// succeeded. The commit alone would not have caught it: a commit id says which
    /// revision was checked out, and the SOURCE HASH says whether what was compiled is
    /// actually that revision. The fork lived in exactly that gap. Recorded here so a
    /// support log can answer "which engine is this user running?" instead of guessing.
    private(set) var engineBuildId = "unknown"

    private(set) var lastAudioActivityAt = Date.distantPast
    private(set) var lastWordsAt = Date.distantPast

    /// Audio in the last 3s, and no words for 12s.
    ///
    /// Twelve because Speechmatics runs about 0.7s behind live speech, so anything under a
    /// few seconds is ordinary and warning on it would train the user to ignore the warning.
    /// Audio in the last 3s and no words for this long. The THRESHOLD is the contract with
    /// the Windows client; the caller's poll interval decides the observed latency, which is
    /// therefore a range: between this and this plus one poll. See listeningMeterInterval.
    static let deafWordSilence: TimeInterval = 12
    static let deafAudioRecency: TimeInterval = 3

    var looksDeaf: Bool {
        let now = Date()
        return now.timeIntervalSince(lastAudioActivityAt) < Self.deafAudioRecency
            && now.timeIntervalSince(lastWordsAt) > Self.deafWordSilence
    }

    /// The number out of ">>> FINAL received (N chars)" — or nil if this is not that line.
    ///
    /// Reads the value rather than the sentence around it. Only "received (" and the digits
    /// are load-bearing; the words either side may change without breaking this.
    nonisolated static func charCount(in line: String) -> Int? {
        guard let r = line.range(of: "received (") else { return nil }
        let digits = line[r.upperBound...].prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    /// Called when a listening turn begins, so a fresh session never starts already accused.
    func resetDeafDetection() {
        lastWordsAt = Date()
        lastAudioActivityAt = .distantPast
    }

    /// The MODE's veto on the microphone, separate from the user's saved Settings choice.
    ///
    /// Interview Auto does not merely PREFER meeting audio — it promises the candidate's mic
    /// stays shut. That promise is a runtime rule, so it lives here rather than being written
    /// into the user's preferences: a mode must never rewrite a setting the user chose.
    var micCaptureAllowed = true

    /// Fired when NO audio source is permitted — the system tap could not start and the
    /// microphone is forbidden. The app must say so; it must never quietly capture instead.
    var onCaptureUnavailable: (() -> Void)?

    /// Fired when Speechmatics rejects the key (not_authorised / invalid key). Lets the
    /// UI show an honest "speech unavailable" message instead of silently doing nothing.
    var onKeyError: (() -> Void)?

    // The engine is launched with posix_spawn (NOT Process/NSTask) so we can DISCLAIM its
    // TCC responsibility — see spawnEngineDisclaimed(). We therefore track a raw pid and
    // the two pipe read-handles ourselves instead of a Process object.
    private var enginePid: pid_t = 0
    private var outHandle: FileHandle?
    private var errHandle: FileHandle?
    private var exitSource: DispatchSourceProcess?

    private var monitorTimer: Timer?
    private var retryTimer: Timer?
    private var engineCancelled = false
    private var authErrorHandled = false
    private var selectedDeviceId = -1
    private var isStarting = false   // prevents concurrent start() calls from checkEngine
    // When SystemAudioCapture crashes (typically permission denied on first run), fall back
    // to mic-only for the rest of the session so we don't loop permission dialogs every 3s.
    private var sysAudioCrashed = false
    // True only when stop() was called deliberately (sign-out, mode switch, quit). The
    // retry timer checks THIS — not engineCancelled — to decide whether to keep retrying.
    // engineCancelled is also set by handleAuthError(), and using it in the retry guard
    // made the 60s auth-recovery loop cancel itself on its very first tick, so the
    // promised "resumes automatically when the service is restored" never happened.
    private var stoppedByUser = false
    // Consecutive times checkEngine() tried to restart and the process didn't even spawn
    // (missing/corrupt binary, spawn failure). Bounded so a permanently broken install
    // shows an honest error instead of retrying every 3 seconds forever.
    private var consecutiveSpawnFailures = 0

    let appDataFolder: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("InterviewCopilot")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// True when system audio can be captured by the in-app Core Audio tap (macOS 14.2+).
    /// The engine then runs system-audio-only and the microphone is never used, so the UI
    /// must NOT gate the app on, or prompt for, the mic. The tap prompts for its own
    /// "record system audio" permission when the engine starts.
    var systemAudioAvailable: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    var latestTxtPath: URL { appDataFolder.appendingPathComponent("latest.txt") }
    var pauseFlagPath: URL { appDataFolder.appendingPathComponent("pause.flag") }
    var resetFlagPath: URL { appDataFolder.appendingPathComponent("reset.flag") }
    var shutdownFlagPath: URL { appDataFolder.appendingPathComponent("shutdown.flag") }

    private init() {}

    func setDevice(_ id: Int) { selectedDeviceId = id }

    // MARK: - Start Engine

    func start(smKey: String) {
        guard !smKey.isEmpty else {
            statusText = "NO MIC"
            dlog("SM start: smKey is empty — cannot start", tag: "SM")
            return
        }
        guard !isStarting else {
            dlog("SM start: already starting, skipping duplicate call", tag: "SM")
            return
        }
        isStarting = true
        // BUG-7 FIX: cancel any pending retry timer — a manual/auto start supersedes it.
        retryTimer?.invalidate(); retryTimer = nil

        engineCancelled = false
        stoppedByUser = false      // a fresh start supersedes any earlier deliberate stop
        authErrorHandled = false   // fresh start → allow a new auth error to be reported
        isReady = false            // becomes true when the engine reports it's online
        nukePreviousProcesses()
        killAndDispose()

        let baseDir = Bundle.main.bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Resources")

        // PyInstaller ONEDIR build (current): a FOLDER named speechmatics_engine containing
        // the executable of the same name plus its dependencies, extracted once at BUILD
        // time. This replaces the old onefile build, which re-extracted its entire bundled
        // Python + numpy + pyaudio + speechmatics payload into a fresh /var/folders temp dir
        // on EVERY launch — that self-extraction was the multi-second delay between process
        // spawn and the engine's first printed line (confirmed in the debug log: the
        // "Script folder" was a fresh _MEIxxxxx dir every time). Onedir removes that entirely.
        let onedirPath = baseDir.appendingPathComponent("speechmatics_engine").appendingPathComponent("speechmatics_engine")
        let hasOnedir = FileManager.default.fileExists(atPath: onedirPath.path)

        // Legacy flat-file (onefile) layout — kept as a fallback only, so an older build
        // artifact still runs during a transition instead of hard-failing with NO ENGINE.
        let flatPath = baseDir.appendingPathComponent("speechmatics_engine")
        let hasFlat = !hasOnedir && FileManager.default.fileExists(atPath: flatPath.path)
        let hasBinary = hasOnedir || hasFlat
        let binaryPath = hasOnedir ? onedirPath : flatPath

        let execDir = URL(fileURLWithPath: Bundle.main.executablePath ?? "")
            .deletingLastPathComponent()
        let devBinary = execDir.appendingPathComponent("speechmatics_engine")
        let hasDevBinary = FileManager.default.fileExists(atPath: devBinary.path)

        let syscaptureDir = hasBinary ? baseDir : execDir
        let syscapturePath = syscaptureDir.appendingPathComponent("SystemAudioCapture")
        let hasSysCapture = FileManager.default.fileExists(atPath: syscapturePath.path)

        dlog("SM binary search:", tag: "SM")
        dlog("  Resources path: \(binaryPath.path) → exists=\(hasBinary) (onedir=\(hasOnedir))", tag: "SM")
        dlog("  Exec dir path:  \(devBinary.path) → exists=\(hasDevBinary)", tag: "SM")
        dlog("  SystemCapture:  \(syscapturePath.path) → exists=\(hasSysCapture)", tag: "SM")
        dlog("  AppDataFolder:  \(appDataFolder.path)", tag: "SM")

        guard let engineURL = hasBinary ? binaryPath : (hasDevBinary ? devBinary : nil) else {
            // Must clear isStarting on this early exit — leaving it true made every later
            // start() call (the NO MIC retry button, a Space-press restart, the monitor
            // loop) silently no-op as a "duplicate" for the rest of the session.
            isStarting = false
            statusText = "NO ENGINE"
            dlog("SM FATAL: speechmatics_engine binary NOT FOUND in any location", tag: "SM")
            return
        }

        dlog("SM using binary: \(engineURL.path)", tag: "SM")

        // Args match .NET order: device (optional), mode, syscapture (optional), delay.
        var args: [String] = []
        if selectedDeviceId >= 0 { args += ["-device", "\(selectedDeviceId)"] }
        // BOTH the interviewer (system audio via the in-app Core Audio tap) AND the user's
        // own voice (microphone) are transcribed. The tap alone never triggers the macOS
        // orange mic indicator; the mic does — but the mic is opened idle (start=False) and
        // only records WHILE LISTENING (see SmartAudioStream / set_mic_active in the Python
        // engine), so the dot appears only during the seconds the user is actually speaking.
        // In a real video interview the meeting app (Zoom/Meet/Teams) is already using the
        // mic the whole call, so that dot is present regardless and reveals nothing new.
        //
        // The tap runs IN THE APP PROCESS (SystemAudioTapper), not a helper — a helper
        // process is fed silence by macOS because it doesn't inherit the app's audio
        // permission (confirmed: peak=0.000 from the old helper). In-app, the permission
        // the user granted applies, so it captures real audio. The app streams that PCM
        // to a FIFO the engine reads via -sysfifo.
        //
        // Mic permission is requested lazily on the first Space press. Until it's granted
        // the engine runs system-only; once granted it restarts in BOTH mode.
        // Read the Settings toggle (System audio only vs. + my voice) directly from disk so
        // every start() call site picks it up without threading state through MainViewModel.
        // Default OFF (system-audio-only) — a fresh install stays fully invisible until the
        // user explicitly opts in to their own voice being transcribed too.
        let settingsPath = appDataFolder.appendingPathComponent("settings.json")
        let micCaptureEnabled: Bool = {
            guard let data = try? Data(contentsOf: settingsPath),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return true }
            return obj["micCaptureEnabled"] as? Bool ?? true
        }()
        // The saved preference AND the active mode must both permit the mic.
        let micAllowed = micCaptureEnabled && micCaptureAllowed
        let micGranted = micAllowed && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        var startedSysTap = false
        if !sysAudioCrashed, #available(macOS 14.2, *) {
            let fifo = appDataFolder.appendingPathComponent("sysaudio.pcm").path
            if SystemAudioTapper.shared.start(fifoPath: fifo) {
                args += ["-mode", micGranted ? "both" : "system", "-sysfifo", fifo]
                dlog("  Audio mode: \(micGranted ? "BOTH (mic + system tap; mic records only while listening)" : "SYSTEM only (mic not granted yet)")", tag: "SM")
                startedSysTap = true
            } else {
                dlog("  in-app tap failed to start → mic-only fallback", tag: "SM")
            }
        }
        if !startedSysTap {
            // NEVER fall back to the microphone when the mic is forbidden.
            //
            // This is the worst failure the app can have. The tap fails on a denied audio
            // permission, on macOS < 14.2, and again after a mid-session crash (sysAudioCrashed).
            // Falling back to "-mode mic" then opened the CANDIDATE'S microphone in Interview
            // Auto: the orange macOS indicator lights up mid-interview, and their own spoken
            // answer is transcribed and answered back as though the interviewer had asked it —
            // the exact thing the mode exists to prevent, happening silently at the worst
            // possible moment. Refuse, and say why.
            guard micAllowed else {
                isStarting = false
                statusText = "NO AUDIO"
                monitorTimer?.invalidate(); monitorTimer = nil
                dlog("SM: system-audio tap unavailable and the microphone is not permitted in this mode — refusing to capture rather than opening the mic", tag: "SM")
                onCaptureUnavailable?()
                return
            }
            args += ["-mode", "mic"]
            dlog("  Audio mode: mic only (system-audio tap unavailable)", tag: "SM")
        }
        // LOWERED 0.8->0.7 (2026-07-16) — this is Speechmatics' documented HARD FLOOR, the
        // fastest this parameter is allowed to go. "fixed" mode (see below) means every word
        // waits this full duration before being committed as FINAL, so this is now the
        // fastest finalization Speechmatics permits. There is no further safe room on this
        // specific lever — 0.7 is the enforced minimum, not just a suggestion.
        args += ["-max-delay", "0.7"]

        // Key ONLY via env var (matches the working .NET app); APP_DATA_DIR points the
        // engine at the same folder the UI polls.
        var env = ProcessInfo.processInfo.environment
        env["SPEECHMATICS_API_KEY"] = smKey
        env["APP_DATA_DIR"] = appDataFolder.path
        // Point OpenSSL at the CA bundle we SHIP, instead of whatever path happened to be
        // compiled into the Python that froze the engine.
        //
        // This shipped broken in 1.0.245. The engine never mentions certifi or SSL_CERT_FILE,
        // so it relied entirely on OpenSSL's built-in default cert path. Built locally with
        // Apple's Python 3.9 that path is /private/etc/ssl/cert.pem, which exists on every
        // Mac, so it worked by luck for years. CI builds with python 3.12 from
        // actions/setup-python, whose default path exists on the RUNNER and nowhere else —
        // so every connection failed with CERTIFICATE_VERIFY_FAILED and transcription was
        // dead on arrival. Nothing in the build changed; only which machine ran it.
        // certifi is already inside the bundle, it simply was never pointed at.
        if let cacert = Bundle.main.url(forResource: "speechmatics_engine", withExtension: nil)?
            .appendingPathComponent("_internal/certifi/cacert.pem"),
           FileManager.default.fileExists(atPath: cacert.path) {
            env["SSL_CERT_FILE"] = cacert.path
            env["REQUESTS_CA_BUNDLE"] = cacert.path
            dlog("SSL: engine will verify against bundled CA store", tag: "SM")
        } else {
            // Never fail silently here: without this the app connects to nothing at all,
            // and the symptom ("Connecting…" forever) looks like a network problem.
            dlog("SSL: bundled CA store MISSING — connections will fail cert verification",
                 tag: "SM")
        }

        dlog("SM launching with args: \(args.joined(separator: " "))", tag: "SM")
        dlog("SM API key length: \(smKey.count) chars", tag: "SM")
        dlog("SM app mic authorizationStatus=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) (0=undetermined,2=denied,3=authorized)", tag: "SM")

        // Launch DISCLAIMED so the engine (and the worker it forks) inherit OUR mic/screen
        // TCC grant instead of needing their own. Root fix for "engine opens the mic but
        // gets only silence" (macOS feeds zeros to a helper without its own permission).
        guard let pid = spawnEngineDisclaimed(path: engineURL.path, args: args, env: env) else {
            isStarting = false
            statusText = "ENGINE ERR"
            dlog("SM launch FAILED (posix_spawn returned error)", tag: "SM")
            return
        }
        enginePid = pid
        isRunning = true
        statusText = "READY"
        dlog("SM engine started successfully (pid=\(pid)) [TCC-disclaimed → inherits app mic]", tag: "SM")
        monitorPipes()
        watchForExit(pid: pid)
        startMonitorTimer()
        // BUG-13 FIX: clear isStarting after all setup is complete, not before startMonitorTimer
        isStarting = false
    }

    // MARK: - posix_spawn with TCC responsibility disclaim

    /// Spawn the engine so it DISCLAIMS its own TCC responsibility → the main app becomes
    /// the responsible process and the engine uses the app's Microphone / Screen Recording
    /// grant. This is why there's no second "InterviewCopilot" permission row and why the
    /// engine finally receives real audio. Returns the child pid, or nil on spawn failure.
    private func spawnEngineDisclaimed(path: String, args: [String], env: [String: String]) -> pid_t? {
        var outP: [Int32] = [0, 0]
        var errP: [Int32] = [0, 0]
        guard pipe(&outP) == 0 else { return nil }
        guard pipe(&errP) == 0 else { close(outP[0]); close(outP[1]); return nil }

        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        posix_spawn_file_actions_adddup2(&fa, outP[1], 1)   // child stdout → outP write end
        posix_spawn_file_actions_adddup2(&fa, errP[1], 2)   // child stderr → errP write end
        posix_spawn_file_actions_addclose(&fa, outP[0])
        posix_spawn_file_actions_addclose(&fa, errP[0])

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        // disclaim removed: engine is now signed --identifier "com.bindualekhya.InterviewCopilot"
        // so it shares the main app's TCC identity. No disclaim = engine inherits parent's mic
        // grant directly, and only ONE "InterviewCopilot" entry appears in System Settings.

        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &fa, &attr, argv, envp)

        // Parent no longer needs the write ends; close so EOF propagates when the child exits.
        close(outP[1]); close(errP[1])
        posix_spawn_file_actions_destroy(&fa)
        posix_spawnattr_destroy(&attr)
        for p in argv where p != nil { free(p) }
        for p in envp where p != nil { free(p) }

        guard rc == 0 else {
            close(outP[0]); close(errP[0])
            return nil
        }
        outHandle = FileHandle(fileDescriptor: outP[0], closeOnDealloc: true)
        errHandle = FileHandle(fileDescriptor: errP[0], closeOnDealloc: true)
        return pid
    }

    /// Look up the private `responsibility_spawnattrs_setdisclaim` at runtime (via dlsym so
    /// a missing symbol can never crash us) and set disclaim=1 on the spawn attributes.
    private func setSpawnDisclaim(_ attr: UnsafeMutablePointer<posix_spawnattr_t?>) {
        typealias DisclaimFn = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>?, Int32) -> Int32
        // RTLD_DEFAULT
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else {
            dlog("SM: responsibility_spawnattrs_setdisclaim not found — engine may need its own mic grant", tag: "SM")
            return
        }
        let fn = unsafeBitCast(sym, to: DisclaimFn.self)
        _ = fn(attr, 1)
    }

    private func watchForExit(pid: pid_t) {
        let src = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        src.setEventHandler { [weak self] in
            var st: Int32 = 0
            waitpid(pid, &st, WNOHANG)   // reap zombie so kill(pid,0) returns ESRCH
            src.cancel()
            // BUG-6 FIX: call checkEngine() immediately rather than waiting up to 3s
            // for the monitor timer — eliminates the dead-transcription window after a crash.
            Task { @MainActor [weak self] in
                self?.isRunning = false
                // The process is gone, so nothing is transcribing regardless of what the
                // last STATUS line said. Without this the flag stayed true through every
                // branch of the restart handler, including the ones that give up entirely.
                self?.isReady = false
                self?.checkEngine()
            }
        }
        src.resume()
        exitSource = src
    }

    // MARK: - Pipe monitoring (auth-error detection on BOTH streams)

    private func monitorPipes() {
        // The Speechmatics auth rejection ("not_authorised") arrives on STDOUT, not stderr,
        // so we watch both. Either stream can surface the failure.
        // [weak self] prevents the pipe handler from keeping the engine alive after disposal.
        let onData: @Sendable (FileHandle, String) -> Void = { [weak self] fh, source in
            let data = fh.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                Task { @MainActor in dlog("SM \(source): \(trimmed)", tag: "SM") }
            }
            if Self.isConcurrencyLimit(line) {
                Task { @MainActor [weak self] in self?.handleConcurrencyLimit() }
            } else if Self.isAuthFailure(line) {
                let exhausted = Self.isBalanceExhausted(line)
                Task { @MainActor [weak self] in self?.handleAuthError(balanceExhausted: exhausted) }
            }
            // The engine prints "STATUS: ONLINE" once the websocket is connected and it's
            // pulling audio — the moment speaking will really be transcribed.
            if let r = line.range(of: "ENGINE BUILD: ") {
                let id = line[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                Task { @MainActor [weak self] in
                    self?.engineBuildId = id
                    dlog("Engine build: \(id)", tag: "SM")
                }
            }
            // Audio is reaching the engine (any non-zero amplitude).
            // CONTRACT:RUNTIME — see ENGINE_CONTRACT.md and verify_engine_contract.py
            if line.contains("AUDIO live") {
                Task { @MainActor [weak self] in self?.lastAudioActivityAt = Date() }
            }
            // Words are coming back out. An EMPTY result does not count — that is precisely
            // what a deaf engine emits.
            //
            // The count is PARSED, not matched as the literal "(0 chars)". That string
            // appears nowhere in the engine: it is produced by
            // print(f">>> FINAL received ({len(display)} chars)"), so matching it coupled
            // this detector to the phrasing of a sentence. Reword the log line and the
            // detector silently stops telling an empty result from a real one — which
            // disables half of it without changing a single line here.
            // CONTRACT:RUNTIME("received (") — declared inline because the dependency lives
            // in charCount(), which reads the NUMBER out of the line rather than matching
            // the sentence, so there is no literal at this call site to extract.
            if let n = Self.charCount(in: line), n > 0 {
                Task { @MainActor [weak self] in self?.lastWordsAt = Date() }
            }
            // CONTRACT:RUNTIME — see ENGINE_CONTRACT.md and verify_engine_contract.py
            if line.contains("STATUS: ONLINE") || line.contains("ENGINE: READY") {
                Task { @MainActor [weak self] in self?.isReady = true }
            }
            // A dropped session is NOT the same event as a crashed process, and handling
            // only one leaves the app believing transcription still works. This is the
            // drop; watchForExit() below is the crash.
            // CONTRACT:RUNTIME — see ENGINE_CONTRACT.md and verify_engine_contract.py
            if line.contains("UTTERANCE END") {
                Task { @MainActor [weak self] in self?.onUtteranceEnd?() }
            }
            // CONTRACT:ONFAIL — see ENGINE_CONTRACT.md and verify_engine_contract.py
            //
            // "EndOfTranscript" used to be matched here too and never once fired. The
            // engine registers an EndOfTranscript event handler, but what that handler
            // PRINTS is ">>> STATUS: OFFLINE" — the literal string was never on stdout, on
            // either engine. A second condition that can never be true reads as redundancy
            // and is really a dependency on something that does not exist; the contract
            // test found it by asking the engine for a line no engine ever emitted.
            if line.contains("STATUS: OFFLINE") {
                Task { @MainActor [weak self] in
                    self?.isReady = false
                    dlog("SM: session dropped — transcription is no longer live", tag: "SM")
                }
            }
        }
        outHandle?.readabilityHandler = { onData($0, "stdout") }
        errHandle?.readabilityHandler = { onData($0, "stderr") }
    }

    /// A GENUINE auth/key failure. Phrases are specific so transient noise can't
    /// false-positive and wrongly kill transcription mid-interview.
    /// Specifically: the account is out of money, rather than the key being wrong. Same
    /// handling, different thing to tell the user — one is ours to fix, the other is theirs.
    nonisolated static func isBalanceExhausted(_ line: String) -> Bool {
        let low = line.lowercased()
        return low.contains("contract blocked") || low.contains("credit balance exhausted")
    }

    /// Speechmatics refusing because the ACCOUNT already has its allowed number of live
    /// sessions. Distinct from an auth failure: the key is fine and it clears by itself once
    /// the other sessions end. It is kept apart from the ordinary transient errors because
    /// retrying fast makes it strictly worse — every attempt opens another session, so the
    /// loop sustains the exact condition it is retrying against, while the UI sits on
    /// "connecting" with nothing to explain why. Seen live: a session killed with SIGKILL
    /// never closes its socket, so the server holds the slot until it times out, and the
    /// next launch is refused by a ghost of the previous one.
    nonisolated static func isConcurrencyLimit(_ line: String) -> Bool {
        let low = line.lowercased()
        return low.contains("quota_exceeded") || low.contains("concurrent quota")
            || low.contains("limit of sessions")
    }

    nonisolated static func isAuthFailure(_ line: String) -> Bool {
        let low = line.lowercased()
        // A blocked contract is an AUTH failure, not a transient one. Speechmatics answers
        // {'type': 'not_allowed', 'reason': 'Contract blocked: Credit Balance Exhausted'}
        // when the balance runs out. On Windows that matched nothing here, so the engine
        // retried on a doubling backoff forever while the UI said "connecting" — a state it
        // could never leave, because no amount of retrying adds credit to the account.
        if low.contains("contract blocked") || low.contains("credit balance exhausted")
            || low.contains("not_allowed") || low.contains("not allowed") { return true }
        return low.contains("invalid api key")   || low.contains("invalid_api_key")
            || low.contains("authentication failed")
            || low.contains("unauthorized")       || low.contains("unauthorised")
            || low.contains("not_authorised")     || low.contains("not_authorized")
            || low.contains("not authorised")     || low.contains("not authorized")
            || low.contains("invalid token")      || low.contains("403 forbidden")
    }

    /// Speechmatics rejected the key. Stop the futile fast-retry loop, tell the UI, and
    /// switch to a slow 60s re-fetch so we auto-recover the moment the server key is fixed.
    private(set) var balanceExhausted = false

    var onConcurrencyLimit: (() -> Void)?
    private var concurrencyHandled = false

    /// Stop hammering, and say what is actually wrong.
    private func handleConcurrencyLimit() {
        guard !concurrencyHandled else { return }
        concurrencyHandled = true
        dlog("SM: account is at its concurrent-session limit — pausing retries for 60s", tag: "SM")
        statusText = "SESSION IN USE"
        engineCancelled = true
        monitorTimer?.invalidate(); monitorTimer = nil
        killAndDispose()
        onConcurrencyLimit?()
        // 60s, not the usual fast backoff. The slot is held by another session and clears on
        // its own; retrying sooner only opens more attempts against a full account.
        startRetryTimer(interval: 60)
    }

    private func handleAuthError(balanceExhausted: Bool = false) {
        guard !authErrorHandled else { return }   // report once per engine start
        authErrorHandled = true
        self.balanceExhausted = balanceExhausted
        dlog("SM KEY ERROR — Speechmatics rejected the speech key. Pausing fast retries; will re-fetch every 60s.", tag: "SM")
        // The token on disk is the one that was just refused. Leaving it there means every
        // retry presents the same dead credential for its full hour, and the retry loop
        // looks broken for a reason nothing on screen can explain.
        UserSession.shared.discardCachedSpeechKey()
        statusText = "KEY ERROR"
        engineCancelled = true
        monitorTimer?.invalidate(); monitorTimer = nil
        killAndDispose()
        onKeyError?()
        // Slower than the ordinary 60s retry ON PURPOSE. Every attempt after an auth failure
        // mints a fresh token, and the allowance is twelve an hour — a one-minute loop would
        // exhaust it inside ten minutes and lock the account out of both apps while trying to
        // recover from a problem retrying cannot fix. Ten minutes still recovers on its own,
        // promptly enough, once billing is restored.
        startRetryTimer(interval: 600)
    }

    private func startMonitorTimer() {
        monitorTimer?.invalidate()
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkEngine() }
        }
    }

    private func checkEngine() {
        guard !engineCancelled else { return }
        // kill(pid, 0) == 0 → process still alive; non-zero (ESRCH) → it died, restart it.
        if enginePid <= 0 || kill(enginePid, 0) != 0 {
            // Assume sys audio crashed (e.g. Screen Recording permission denied) and fall
            // back to mic-only — prevents a permission-dialog loop every 3 seconds.
            sysAudioCrashed = true
            let key = UserSession.shared.speechmaticsKey
            guard !key.isEmpty else {
                statusText = "NO MIC"
                monitorTimer?.invalidate()
                return
            }
            start(smKey: key)
            // start() sets isRunning the moment the process spawns. If it's STILL false
            // here, the engine couldn't even launch (binary missing from the bundle,
            // spawn failure) — a permanent condition retrying every 3s will never fix.
            // Give it a few chances (transient failures do happen), then stop the loop
            // and leave an honest status instead of spamming the log forever while the
            // UI pretends everything is fine.
            if isRunning {
                consecutiveSpawnFailures = 0
            } else {
                consecutiveSpawnFailures += 1
                if consecutiveSpawnFailures >= 5 {
                    monitorTimer?.invalidate(); monitorTimer = nil
                    statusText = "ENGINE ERR"
                    dlog("checkEngine: engine failed to launch \(consecutiveSpawnFailures) times in a row — giving up. The app bundle is likely damaged; reinstalling should fix it.", tag: "SM")
                }
            }
        }
    }

    // MARK: - Stop

    // NOTE: the old "6 s of silence → modal permission alert" is GONE on purpose.
    // Silence from the tap usually just means nothing is playing (the output device
    // idles, so the IO proc doesn't fire) — the log proved permission was granted and
    // audio flowed the moment something played. That modal was the "popup keeps
    // appearing even though I granted everything" bug. A REAL permission failure makes
    // AudioHardwareCreateProcessTap fail, which falls back to mic-only above.

    func stop() {
        engineCancelled = true
        stoppedByUser = true      // deliberate stop — retry loops must not resurrect it
        isReady = false
        sysAudioCrashed = false   // reset for next session — will try sys audio again
        if #available(macOS 14.2, *) { SystemAudioTapper.shared.stop() }   // stop the in-app tap
        monitorTimer?.invalidate(); monitorTimer = nil
        retryTimer?.invalidate();   retryTimer = nil
        killAndDispose()
    }

    private func killAndDispose() {
        // Clear the pipe readers BEFORE terminating so a dangling handler can't keep firing.
        outHandle?.readabilityHandler = nil
        errHandle?.readabilityHandler = nil
        outHandle = nil
        errHandle = nil
        exitSource?.cancel(); exitSource = nil
        if enginePid > 0 {
            let pid = enginePid
            kill(pid, SIGTERM)
            // Reap off main. WNOHANG loop with a SIGKILL fallback after 2s so a hung
            // engine never blocks this GCD thread indefinitely.
            DispatchQueue.global(qos: .utility).async {
                var st: Int32 = 0
                for _ in 0..<20 {
                    if waitpid(pid, &st, WNOHANG) != 0 { return }
                    Thread.sleep(forTimeInterval: 0.1)
                }
                kill(pid, SIGKILL)
                waitpid(pid, &st, 0)
            }
        }
        enginePid = 0
        isRunning = false
    }

    private func nukePreviousProcesses() {
        DispatchQueue.global(qos: .utility).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/ps")
            task.arguments = ["ax", "-o", "pid,ppid,command"]
            let pipe = Pipe()
            task.standardOutput = pipe
            try? task.run()
            task.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            for line in output.components(separatedBy: "\n") {
                guard line.contains("speechmatics_engine") || line.contains("SystemAudioCapture") else { continue }
                let parts = line.trimmingCharacters(in: .whitespaces)
                    .split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                guard parts.count >= 2, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else { continue }
                // Kill ONLY true orphans (ppid == 1, reparented to launchd after a crash) —
                // never our live engine tree.
                guard ppid == 1 else { continue }
                kill(pid, SIGTERM)
            }
        }
    }

    // MARK: - Flags

    /// Let the system-audio tap be tried again.
    ///
    /// A tap failure latches sysAudioCrashed for the rest of the session so a denied
    /// permission cannot loop a dialog every 3 seconds. But it also made the retry control
    /// useless: the user grants Screen Recording, clicks retry, and the tap is skipped
    /// anyway. An EXPLICIT retry is exactly the signal that the cause may be fixed.
    func allowSystemAudioRetry() { sysAudioCrashed = false }

    func writePauseFlag()  { try? "1".write(to: pauseFlagPath,  atomically: true, encoding: .utf8) }
    func deletePauseFlag() { try? FileManager.default.removeItem(at: pauseFlagPath) }
    func writeResetFlag()  { try? "1".write(to: resetFlagPath,  atomically: true, encoding: .utf8) }
    func clearLatestTxt()  { try? "".write(to:  latestTxtPath,  atomically: true, encoding: .utf8) }
    /// Remove it entirely, rather than blanking it. On quit there is nothing to keep.
    func deleteLatestTxt() { try? FileManager.default.removeItem(at: latestTxtPath) }

    func readLatestTxt() -> String {
        (try? String(contentsOf: latestTxtPath, encoding: .utf8)) ?? ""
    }

    // MARK: - Retry

    func startRetryTimer(interval: TimeInterval = 60.0) {
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // BUG-7/21 FIX: if the engine is already running (restarted by other path)
                // or the user explicitly stopped it, cancel the timer and do nothing.
                // Checks stoppedByUser — NOT engineCancelled — because handleAuthError()
                // sets engineCancelled too, and checking that here made this timer cancel
                // itself on its first tick after every auth error, killing auto-recovery.
                guard !self.isRunning, !self.stoppedByUser else {
                    self.retryTimer?.invalidate()
                    self.retryTimer = nil
                    return
                }
                let ok = await UserSession.shared.fetchSpeechmaticsKeyAsync()
                if ok {
                    self.retryTimer?.invalidate()
                    self.retryTimer = nil
                    self.start(smKey: UserSession.shared.speechmaticsKey)
                }
            }
        }
    }
}
