import Foundation
import CoreGraphics

/// One window as the screen reader sees it. A plain value so the choice below can be tested without a screen.
struct CaptureWindow: Equatable {
    var id: UInt32
    var pid: Int32
    var frame: CGRect
    /// 0 for an ordinary window, 8 for an app modal panel such as an alert.
    var layer: Int
    var title: String
}

/// What to read, and what sits in front of it.
struct CaptureChoice: Equatable {
    var window: CaptureWindow
    /// A dialog or sheet in front of `window`, captured with it so the model sees both.
    var dialogs: [CaptureWindow]
}

/// Chooses the window a screen question is about.
///
/// The window in front is the right thing to read, except when it is a dialog: "Save changes?", an error box
/// or a sheet belongs to the window behind it, and that window is what the question is about. Reading only the
/// dialog sent the model a picture of a message box and nothing of the problem under it (Windows 1.0.30,
/// item 19). The window the dialog belongs to is read instead, with the dialog drawn on top of it.
enum CaptureTarget {
    private static let minimumDialogSize = CGSize(width: 100, height: 60)

    /// - Parameter windows: every window on screen, FRONT TO BACK.
    static func choose(windows: [CaptureWindow], ownPID: Int32) -> CaptureChoice? {
        for (i, w) in windows.enumerated() {
            guard w.pid != ownPID, w.layer == 0 || w.layer == 8,
                  w.frame.width >= minimumDialogSize.width, w.frame.height >= minimumDialogSize.height else { continue }
            if let parent = parent(of: w, behind: windows[(i + 1)...]) {
                return CaptureChoice(window: parent, dialogs: [w])
            }
            // An ordinary window big enough to hold a question. A small panel with no parent is skipped:
            // the user almost certainly means what is behind it.
            if w.layer == 0, w.frame.width > 200, w.frame.height > 200 {
                return CaptureChoice(window: w, dialogs: [])
            }
        }
        return nil
    }

    /// The window a dialog belongs to: another window of the same app, ordinary, clearly larger, and either the
    /// dialog is an app modal panel or it is an untitled window sitting inside it (a sheet, a popover).
    static func parent(of dialog: CaptureWindow, behind: ArraySlice<CaptureWindow>) -> CaptureWindow? {
        let dialogArea = dialog.frame.width * dialog.frame.height
        for p in behind {
            guard p.pid == dialog.pid, p.id != dialog.id, p.layer == 0,
                  p.frame.width > 200, p.frame.height > 200,
                  p.frame.width * p.frame.height >= 2 * dialogArea else { continue }
            if dialog.layer == 8 { return p }
            if dialog.title.trimmingCharacters(in: .whitespaces).isEmpty,
               insideFraction(dialog.frame, of: p.frame) >= 0.9 { return p }
        }
        return nil
    }

    private static func insideFraction(_ inner: CGRect, of outer: CGRect) -> Double {
        let area = inner.width * inner.height
        guard area > 0 else { return 0 }
        let overlap = inner.intersection(outer)
        guard !overlap.isNull else { return 0 }
        return Double(overlap.width * overlap.height / area)
    }
}
