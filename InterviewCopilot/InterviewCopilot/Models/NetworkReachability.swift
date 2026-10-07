import Foundation
import Network

/// Whether the Mac has a network path at all. Used only to tell "no internet" apart from
/// "the speech service is unreachable", which need different words (ListeningProblems).
final class NetworkReachability: @unchecked Sendable {
    static let shared = NetworkReachability()
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var up = true

    var isUp: Bool { lock.lock(); defer { lock.unlock() }; return up }

    /// Called on the main queue when the network the Mac is on changes (another Wi-Fi, a hotspot, a cable, or
    /// coming back after being offline). What the app learned about the old line no longer holds.
    var onChange: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return changeHandler }
        set { lock.lock(); changeHandler = newValue; lock.unlock() }
    }
    private var changeHandler: (@Sendable () -> Void)?
    private var lastShape: String?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            // Which interfaces carry the path, not just whether there is one: moving from Wi-Fi to a phone
            // hotspot keeps the path satisfied and still changes everything about the line.
            let shape = "\(path.status)|" + path.availableInterfaces.map { "\($0.type)\($0.name)" }.sorted().joined(separator: ",")
            self.lock.lock()
            self.up = (path.status == .satisfied)
            let changed = self.lastShape != nil && self.lastShape != shape
            self.lastShape = shape
            let handler = self.changeHandler
            self.lock.unlock()
            if changed, let handler { DispatchQueue.main.async { handler() } }
        }
        monitor.start(queue: DispatchQueue(label: "replysis.network-path"))
    }
}
