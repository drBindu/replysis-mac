import Foundation
import AVFoundation      // AVCaptureDevice — log the app's mic authorization for diagnostics
import Darwin            // posix_spawn, pipe, kill, waitpid, dlsym

@MainActor
class SpeechmaticsEngine {
    static let shared = SpeechmaticsEngine()

    var isRunning = false
    var statusText = "READY"

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

    let appDataFolder: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("InterviewCopilot")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

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
        authErrorHandled = false   // fresh start → allow a new auth error to be reported
        nukePreviousProcesses()
        killAndDispose()

        let baseDir = Bundle.main.bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Resources")

        let binaryPath = baseDir.appendingPathComponent("speechmatics_engine")
        let hasBinary = FileManager.default.fileExists(atPath: binaryPath.path)

        let execDir = URL(fileURLWithPath: Bundle.main.executablePath ?? "")
            .deletingLastPathComponent()
        let devBinary = execDir.appendingPathComponent("speechmatics_engine")
        let hasDevBinary = FileManager.default.fileExists(atPath: devBinary.path)

        let syscaptureDir = hasBinary ? baseDir : execDir
        let syscapturePath = syscaptureDir.appendingPathComponent("SystemAudioCapture")
        let hasSysCapture = FileManager.default.fileExists(atPath: syscapturePath.path)

        dlog("SM binary search:", tag: "SM")
        dlog("  Resources path: \(binaryPath.path) → exists=\(hasBinary)", tag: "SM")
        dlog("  Exec dir path:  \(devBinary.path) → exists=\(hasDevBinary)", tag: "SM")
        dlog("  SystemCapture:  \(syscapturePath.path) → exists=\(hasSysCapture)", tag: "SM")
        dlog("  AppDataFolder:  \(appDataFolder.path)", tag: "SM")

        guard let engineURL = hasBinary ? binaryPath : (hasDevBinary ? devBinary : nil) else {
            statusText = "NO ENGINE"
            dlog("SM FATAL: speechmatics_engine binary NOT FOUND in any location", tag: "SM")
            return
        }

        dlog("SM using binary: \(engineURL.path)", tag: "SM")

        // Args match .NET order: device (optional), mode, syscapture (optional), delay.
        var args: [String] = []
        if selectedDeviceId >= 0 { args += ["-device", "\(selectedDeviceId)"] }
        // SYSTEM-audio-only mode: capture just the interviewer through the Core Audio
        // tap (SystemAudioCapture). The mic is NOT opened, so macOS shows no orange
        // microphone indicator — the app stays fully invisible in the menu bar.
        // If the tap can't start, the engine self-falls-back to mic-only (orange dot
        // returns, but transcription keeps working). If it crashed hard before, skip
        // straight to mic so we don't loop.
        let useSysAudio = hasSysCapture && !sysAudioCrashed
        args += ["-mode", useSysAudio ? "system" : "mic"]
        if useSysAudio { args += ["-syscapture", syscapturePath.path] }
        dlog("  Audio mode: \(useSysAudio ? "SYSTEM only (tap, no mic)" : "mic only") — bundled=\(hasSysCapture)", tag: "SM")
        args += ["-max-delay", "0.7"]   // Speechmatics enforces a HARD minimum of 0.7 — lower is rejected

        // Key ONLY via env var (matches the working .NET app); APP_DATA_DIR points the
        // engine at the same folder the UI polls.
        var env = ProcessInfo.processInfo.environment
        env["SPEECHMATICS_API_KEY"] = smKey
        env["APP_DATA_DIR"] = appDataFolder.path

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
            if Self.isAuthFailure(line) {
                Task { @MainActor [weak self] in self?.handleAuthError() }
            }
        }
        outHandle?.readabilityHandler = { onData($0, "stdout") }
        errHandle?.readabilityHandler = { onData($0, "stderr") }
    }

    /// A GENUINE auth/key failure. Phrases are specific so transient noise can't
    /// false-positive and wrongly kill transcription mid-interview.
    nonisolated static func isAuthFailure(_ line: String) -> Bool {
        let low = line.lowercased()
        return low.contains("invalid api key")   || low.contains("invalid_api_key")
            || low.contains("authentication failed")
            || low.contains("unauthorized")       || low.contains("unauthorised")
            || low.contains("not_authorised")     || low.contains("not_authorized")
            || low.contains("not authorised")     || low.contains("not authorized")
            || low.contains("invalid token")      || low.contains("403 forbidden")
    }

    /// Speechmatics rejected the key. Stop the futile fast-retry loop, tell the UI, and
    /// switch to a slow 60s re-fetch so we auto-recover the moment the server key is fixed.
    private func handleAuthError() {
        guard !authErrorHandled else { return }   // report once per engine start
        authErrorHandled = true
        dlog("SM KEY ERROR — Speechmatics rejected the speech key. Pausing fast retries; will re-fetch every 60s.", tag: "SM")
        statusText = "KEY ERROR"
        engineCancelled = true
        monitorTimer?.invalidate(); monitorTimer = nil
        killAndDispose()
        onKeyError?()
        startRetryTimer()
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
        }
    }

    // MARK: - Stop

    func stop() {
        engineCancelled = true
        sysAudioCrashed = false   // reset for next session — will try sys audio again
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

    func writePauseFlag()  { try? "1".write(to: pauseFlagPath,  atomically: true, encoding: .utf8) }
    func deletePauseFlag() { try? FileManager.default.removeItem(at: pauseFlagPath) }
    func writeResetFlag()  { try? "1".write(to: resetFlagPath,  atomically: true, encoding: .utf8) }
    func clearLatestTxt()  { try? "".write(to:  latestTxtPath,  atomically: true, encoding: .utf8) }

    func readLatestTxt() -> String {
        (try? String(contentsOf: latestTxtPath, encoding: .utf8)) ?? ""
    }

    // MARK: - Retry

    func startRetryTimer() {
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // BUG-7/21 FIX: if the engine is already running (restarted by other path)
                // or the user explicitly stopped it, cancel the timer and do nothing.
                guard !self.isRunning, !self.engineCancelled else {
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
