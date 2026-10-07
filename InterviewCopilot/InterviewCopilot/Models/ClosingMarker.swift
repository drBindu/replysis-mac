import Foundation

/// A copy of the app that is closing says so, so a copy started right after it waits instead of giving up.
///
/// Closing and reopening straight away (a restart to fix something) hit the single-copy guard held by the copy
/// still saving, and the new copy took it for a duplicate, handed over to it and quit; then the old copy finished
/// quitting and nothing was left running (Windows 1.0.30, item 5, where the new copy now waits up to 8 s). A
/// genuine second copy, with nothing closing, is still handed over to at once.
enum ClosingMarker {
    private static func file(_ dir: URL) -> URL { dir.appendingPathComponent("closing.marker") }

    static func markClosing(in dir: URL, pid: Int32, now: Date = Date()) {
        try? "\(pid) \(Int(now.timeIntervalSince1970))".write(to: file(dir), atomically: true, encoding: .utf8)
    }

    /// True when `pid` wrote the marker recently: it is on its way out.
    static func isClosing(pid: Int32, in dir: URL, now: Date = Date(), maxAge: TimeInterval = 30) -> Bool {
        guard let text = try? String(contentsOf: file(dir), encoding: .utf8) else { return false }
        let parts = text.split(separator: " ")
        guard parts.count == 2, Int32(parts[0]) == pid, let at = TimeInterval(parts[1]) else { return false }
        let age = now.timeIntervalSince1970 - at
        return age >= -1 && age <= maxAge
    }

    static func clear(in dir: URL) { try? FileManager.default.removeItem(at: file(dir)) }

    /// Waits for the process to be gone. True when it is, false when it is still there after `timeout`.
    static func waitForExit(pid: Int32, timeout: TimeInterval = 8, poll: TimeInterval = 0.1,
                            isAlive: (Int32) -> Bool = { kill($0, 0) == 0 }) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while isAlive(pid) {
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: poll)
        }
        return true
    }
}
