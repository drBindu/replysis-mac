import Foundation

@MainActor
class DebugLog {
    static let shared = DebugLog()
    private init() {}

    private(set) var entries: [String] = []
    private let maxEntries = 500

    // Created ONCE — DateFormatter is very expensive to allocate, and log() is hot.
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func log(_ message: String, tag: String = "INFO") {
        let ts = Self.formatter.string(from: Date())
        let line = "[\(ts)] [\(tag)] \(message)"
        entries.append(line)
        if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
        print(line) // also prints to Xcode console
    }

    func clear() { entries.removeAll() }

    var text: String { entries.joined(separator: "\n") }
}

// Convenience global
func dlog(_ msg: String, tag: String = "INFO") {
    Task { @MainActor in DebugLog.shared.log(msg, tag: tag) }
}
