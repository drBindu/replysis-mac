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
        // Fresh file each launch (keeps it small; the previous run is what matters).
        try? "".write(to: url, atomically: true, encoding: .utf8)
        return try? FileHandle(forWritingTo: url)
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
