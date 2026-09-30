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

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock(); self.up = (path.status == .satisfied); self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "replysis.network-path"))
    }
}
