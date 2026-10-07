import Foundation
import AppKit

/// Puts text on the clipboard, waiting out another program that has it for a moment.
///
/// A clipboard manager or a remote desktop client often holds the pasteboard for an instant, and the first write
/// then fails. The Copy code button used to ignore that and say nothing, so the candidate pasted old text into
/// the editor. It retries for about a second now and says so if it still could not (Windows 1.0.30, item 20).
enum Clipboard {
    /// - Parameter write: one attempt; true when the text is on the clipboard. Injected so a test can fail it.
    /// - Returns: true when the text was copied.
    static func copy(_ text: String, attempts: Int = 10, pause: TimeInterval = 0.1,
                     write: (String) -> Bool = systemWrite) async -> Bool {
        for attempt in 0..<max(1, attempts) {
            if write(text) { return true }
            if attempt < attempts - 1 { try? await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000)) }
        }
        return false
    }

    static func systemWrite(_ text: String) -> Bool {
        let board = NSPasteboard.general
        board.clearContents()
        return board.setString(text, forType: .string)
    }
}
