import Foundation

@MainActor
class DebugLog {
    static let shared = DebugLog()
    private init() {}

    private(set) var entries: [String] = []
    private let maxEntries = 500

    /// Hard ceiling on the file, enforced WHILE the app runs.
    ///
    /// The cap used to be checked only when the handle was first opened, so a single long
    /// interview could grow the file without limit — the one session most worth capping.
    private static let maxFileBytes = 2_000_000
    private var bytesWritten = 0

    /// In release, quoted spans are replaced by their length.
    ///
    /// Everything the app logs about speech puts the words inside single quotes, so this
    /// removes verbatim interview content at every call site at once while keeping the
    /// decision around it — which is the part that is actually useful when supporting a
    /// user. A support log should say a turn was rejected as unfinished, not what was said.
    #if DEBUG
    private static let redactContent = false
    #else
    private static let redactContent = true
    #endif

    static func redact(_ message: String) -> String {
        guard redactContent, message.contains("'") else { return message }
        var out = "", inQuote = false, count = 0
        for ch in message {
            if ch == "'" {
                if inQuote { out += "⟨\(count) chars⟩'"; inQuote = false; count = 0 }
                else { out += "'"; inQuote = true }
            } else if inQuote { count += 1 } else { out.append(ch) }
        }
        if inQuote { out += "⟨\(count) chars⟩" }   // unterminated quote
        return out
    }

    // Serial queue for disk I/O — keeps file writes off the main actor so token
    // streaming (which calls dlog() on every chunk) never blocks the UI.
    private let ioQueue = DispatchQueue(label: "com.interviewcopilot.debuglog.io", qos: .utility)

    // Created ONCE — DateFormatter is very expensive to allocate, and log() is hot.
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    // Persistent log file at ~/Library/Logs/InterviewCopilot-debug.log so problems
    // (hotkey registration, mic/engine, permissions) can be diagnosed after the fact
    // without Xcode — the single most useful thing for supporting real users.
    static let logFileURL: URL = {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs")
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("InterviewCopilot-debug.log")
    }()

    private lazy var fileHandle: FileHandle? = {
        let url = Self.logFileURL
        // BUG FIX: this used to truncate the file to empty on EVERY launch. That's fine
        // for the normal single-instance case, but when two processes are alive at once
        // (exactly the scenario this log is most needed to diagnose — e.g. a relaunch
        // whose old instance failed to quit), the SECOND process's launch wiped out the
        // FIRST process's already-written lines the instant it opened the file, making
        // the bug that caused two processes invisible in the very log meant to catch it.
        // Now: append with a clear per-launch marker, only truncating if the file has
        // grown large (stale logs from many past sessions), not on every single launch.
        let existingSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        if let size = existingSize, size > Self.maxFileBytes {
            try? "".write(to: url, atomically: true, encoding: .utf8)   // reset only when it's gotten big
        } else if !FileManager.default.fileExists(atPath: url.path) {
            // 0600 AT CREATION. The default umask left this world-readable, and the file
            // carries what was said in an interview — the session transcripts beside it are
            // already 0600, so this was the one place the same content was not protected.
            FileManager.default.createFile(atPath: url.path, contents: nil,
                                           attributes: [.posixPermissions: 0o600])
        }
        // Tighten any file left behind by an older build, which created it world-readable.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        bytesWritten = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int).flatMap { $0 } ?? 0
        let handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
        let marker = "\n──── NEW LAUNCH pid=\(ProcessInfo.processInfo.processIdentifier) ────\n"
        handle?.write(marker.data(using: .utf8) ?? Data())
        return handle
    }()

    func log(_ message: String, tag: String = "INFO") {
        let ts = Self.formatter.string(from: Date())
        let line = "[\(ts)] [\(tag)] \(Self.redact(message))"
        entries.append(line)
        if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
        // print() also copies every line into unified logging, where it is readable by
        // other tooling and captured in a sysdiagnose. The file is the supported channel.
        #if DEBUG
        print(line)
        #endif
        // Write to disk off the main actor — file I/O during token streaming was
        // blocking the UI thread and causing janky answer rendering.
        guard let data = (line + "\n").data(using: .utf8), let handle = fileHandle else { return }
        bytesWritten += data.count
        let mustRotate = bytesWritten > Self.maxFileBytes
        if mustRotate { bytesWritten = data.count }
        ioQueue.async {
            if mustRotate {
                try? handle.truncate(atOffset: 0)
                try? handle.seek(toOffset: 0)
            }
            handle.write(data)
        }
    }

    func clear() { entries.removeAll() }

    /// Wipe the log entirely. Signing out should not leave the previous account's interview
    /// content on the machine for the next person who signs in.
    func purge() {
        entries.removeAll()
        bytesWritten = 0
        let handle = fileHandle
        ioQueue.async {
            try? handle?.truncate(atOffset: 0)
            try? handle?.seek(toOffset: 0)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: Self.logFileURL.path)
    }

    var text: String { entries.joined(separator: "\n") }
}

// Convenience global — skips Task allocation when already on the main actor
// (the common case for UI-level callers). Falls back to Task for background callers.
func dlog(_ msg: String, tag: String = "INFO") {
    if Thread.isMainThread {
        MainActor.assumeIsolated { DebugLog.shared.log(msg, tag: tag) }
    } else {
        Task { @MainActor in DebugLog.shared.log(msg, tag: tag) }
    }
}
