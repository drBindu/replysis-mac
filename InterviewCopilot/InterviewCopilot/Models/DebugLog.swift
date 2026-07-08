import Foundation

@MainActor
class DebugLog {
    static let shared = DebugLog()
    private init() {}

    private(set) var entries: [String] = []
    private let maxEntries = 500

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
        if let size = existingSize, size > 2_000_000 {
            try? "".write(to: url, atomically: true, encoding: .utf8)   // reset only when it's gotten big
        } else if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
        let marker = "\n──── NEW LAUNCH pid=\(ProcessInfo.processInfo.processIdentifier) ────\n"
        handle?.write(marker.data(using: .utf8) ?? Data())
        return handle
    }()

    func log(_ message: String, tag: String = "INFO") {
        let ts = Self.formatter.string(from: Date())
        let line = "[\(ts)] [\(tag)] \(message)"
        entries.append(line)
        if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
        print(line)
        // Write to disk off the main actor — file I/O during token streaming was
        // blocking the UI thread and causing janky answer rendering.
        if let data = (line + "\n").data(using: .utf8), let handle = fileHandle {
            ioQueue.async { handle.write(data) }
        }
    }

    func clear() { entries.removeAll() }

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
