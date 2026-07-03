import Foundation
import CoreGraphics   // CGPreflightScreenCaptureAccess — gate system-audio on permission

@MainActor
class SpeechmaticsEngine {
    static let shared = SpeechmaticsEngine()

    var isRunning = false
    var statusText = "READY"

    /// Fired when Speechmatics rejects the key (not_authorised / invalid key). Lets the
    /// UI show an honest "speech unavailable" message instead of silently doing nothing.
    var onKeyError: (() -> Void)?

    private var process: Process?
    private var monitorTimer: Timer?
    private var retryTimer: Timer?
    private var engineCancelled = false
    private var authErrorHandled = false
    private var selectedDeviceId = -1

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
            dlog("Copy the speechmatics_engine binary into the app Resources folder", tag: "SM")
            return
        }

        dlog("SM using binary: \(engineURL.path)", tag: "SM")

        let proc = Process()
        proc.executableURL = engineURL

        // Key is passed ONLY via the SPEECHMATICS_API_KEY env var (set below) — the
        // working .NET app never passes -key on the command line, and the extra arg can
        // confuse the binary's parser. Arg order matches .NET: device, mode, syscapture, delay.
        var args: [String] = []
        if selectedDeviceId >= 0 { args += ["-device", "\(selectedDeviceId)"] }
        // Use system-audio capture (hear the interviewer DIRECTLY — far more accurate
        // than picking them up through the mic) ONLY when the binary is bundled AND
        // Screen Recording is granted. Gating on the permission = no regression: until
        // the user grants it we stay mic-only and always work; once granted, the
        // interviewer's questions are transcribed cleanly.
        let useSysAudio = hasSysCapture && CGPreflightScreenCaptureAccess()
        args += ["-mode", useSysAudio ? "both" : "mic"]
        if useSysAudio { args += ["-syscapture", syscapturePath.path] }
        dlog("  Audio mode: \(useSysAudio ? "BOTH (system+mic)" : "mic only") — bundled=\(hasSysCapture) screenOK=\(CGPreflightScreenCaptureAccess())", tag: "SM")
        args += ["-max-delay", "0.7"]

        proc.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["SPEECHMATICS_API_KEY"] = smKey
        env["APP_DATA_DIR"] = appDataFolder.path
        proc.environment = env

        proc.standardOutput = Pipe()
        proc.standardError = Pipe()

        dlog("SM launching with args: \(args.joined(separator: " "))", tag: "SM")
        dlog("SM API key length: \(smKey.count) chars", tag: "SM")

        do {
            try proc.run()
            process = proc
            isRunning = true
            statusText = "READY"
            dlog("SM engine started successfully (pid=\(proc.processIdentifier))", tag: "SM")
            monitorStderr(proc: proc)
            startMonitorTimer()
        } catch {
            statusText = "ENGINE ERR"
            dlog("SM launch failed: \(error.localizedDescription)", tag: "SM")
        }
    }

    private func monitorStderr(proc: Process) {
        // One handler for BOTH streams. The Speechmatics auth rejection ("not_authorised")
        // arrives on STDOUT, not stderr — the previous code only inspected stderr, so a
        // dead key was never detected and the engine silently retried forever with an
        // empty transcript. Now either stream can surface the failure.
        let onData: @Sendable (FileHandle, String) -> Void = { fh, source in
            let data = fh.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                Task { @MainActor in dlog("SM \(source): \(trimmed)", tag: "SM") }
            }
            if Self.isAuthFailure(line) {
                Task { @MainActor in self.handleAuthError() }
            }
        }
        (proc.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = { onData($0, "stderr") }
        (proc.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = { onData($0, "stdout") }
    }

    /// A GENUINE auth/key failure. Phrases are specific so transient noise
    /// ("Invalid audio frame", a timestamp containing 401) can't false-positive and
    /// wrongly kill transcription mid-interview.
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
        startRetryTimer()   // re-fetch a fresh key periodically; auto-recovers if the server key is renewed
    }

    private func startMonitorTimer() {
        monitorTimer?.invalidate()
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkEngine() }
        }
    }

    private func checkEngine() {
        guard !engineCancelled else { return }
        if process == nil || process?.isRunning == false {
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
        monitorTimer?.invalidate()
        monitorTimer = nil
        retryTimer?.invalidate()
        retryTimer = nil
        killAndDispose()
    }

    private func killAndDispose() {
        // Clear the pipe readers BEFORE terminating — a dangling readabilityHandler
        // keeps the file handle alive and can keep firing after the process dies.
        if let proc = process {
            (proc.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            (proc.standardError  as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            proc.terminate()
        }
        process = nil
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
                // Kill ONLY true orphans — processes reparented to launchd (ppid == 1)
                // because a PREVIOUS app instance crashed without cleaning up. Our live
                // engine (ppid == this app) AND the worker it forks (ppid == the engine)
                // both have ppid != 1, so this can never kill our own running tree. The
                // earlier "skip our direct child" rule missed the engine's worker child
                // and would kill it in the spawn race, breaking live transcription.
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
                guard let self = self else { return }
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
