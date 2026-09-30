import AppKit
import CoreGraphics

/// Whether macOS itself reports the Replysis window as hidden from screen sharing.
///
/// Read from the window server's own sharing state for THIS app's window (0 = not shared),
/// not assumed from a setting. It is what the system says, which is the honest thing to
/// show; whether a given meeting app honours it varies, so the Setup card keeps Windows'
/// wording: "Support varies, so check it in your meeting app first."
enum CaptureProtection {
    enum State { case hidden, visible, unknown }

    static func current() -> State {
        let pid = ProcessInfo.processInfo.processIdentifier
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return .unknown }
        var sawWindow = false
        for w in info {
            guard (w[kCGWindowOwnerPID as String] as? Int32) == pid,
                  let b = w[kCGWindowBounds as String] as? [String: Double], (b["Width"] ?? 0) > 300 else { continue }
            sawWindow = true
            // 0 = not shared, 1 = read only, 2 = read and write
            if (w[kCGWindowSharingState as String] as? Int ?? 2) != 0 { return .visible }
        }
        return sawWindow ? .hidden : .unknown
    }

    static func summary(_ s: State) -> String {
        switch s {
        case .hidden:  return "This Mac reports the window as hidden from screen sharing."
        case .visible: return "This Mac reports the window as visible to screen sharing. Turn Stealth mode on in Settings."
        case .unknown: return "Open the interview window to check."
        }
    }
}
