import Foundation

// The pure half of StealthSelfTest, kept apart so the regression harness can compile it alone.
enum ScreenShareState: Equatable {
    case checking, hidden, visible, off, notChecked

    var label: String {
        switch self {
        case .checking:   return "Checking"
        case .hidden:     return "Hidden"
        case .visible:    return "Visible"
        case .off:        return "Off"
        case .notChecked: return "Not checked"
        }
    }

    var detail: String {
        switch self {
        case .checking:   return "Testing whether a screen share can see Replysis."
        case .hidden:     return "Tested on this Mac: a screen share cannot see Replysis."
        case .visible:    return "A screen share can see Replysis on this Mac. Share one window or a browser tab, not the whole screen."
        case .off:        return "Stealth is off in Settings, so a screen share shows Replysis."
        case .notChecked: return "Allow Screen Recording for Replysis (it is also what Read screen uses) to test it here."
        }
    }
}

enum StealthProbe {
    /// Whether the captured pixel is the probe's magenta (the probe is 255, 0, 255; colour management moves it a little).
    static func looksLikeProbe(red: Int, green: Int, blue: Int) -> Bool {
        red > 200 && blue > 200 && green < 90
    }
}
