import AppKit

// ══════════════════════════════════════════════════════════════════════════
// Stealth Mode for EVERY window the app owns.
//
// Past Sessions, Settings, sign-in and the debug log are sheets; the profile menu, the credits box and the
// resume list are popovers; a quit question is an alert. Each one is its own NSWindow, and sharingType belongs to
// the window and starts as .readOnly (a screen share can capture it). They do NOT take the main window's setting.
// The note that used to sit in applyStealthMode said they did, from CGWindowListCopyWindowInfo, whose sharing field
// read 0 for them; the windows' own sharingType said 1 (measured inside the app, 2026-10-16). So with Stealth Mode
// ON, opening Past Sessions or the profile menu during a screen share showed them to the other side.
//
// The rule is applied to all of NSApp.windows, at every moment a window can first appear or change:
//   - just before any window is put on screen (orderWindow), which is before its first frame,
//   - on every window update, on becoming key or main, and as a sheet begins,
//   - and four times a second, for anything the above does not announce (popovers, alerts).
// ══════════════════════════════════════════════════════════════════════════
@MainActor
enum StealthWindows {
    private(set) static var enabled = true
    private static var installed = false

    /// Turn Stealth Mode on or off for every window, now and for any window that opens later.
    static func setEnabled(_ on: Bool) {
        enabled = on
        install()
        applyToAll()
    }

    static var wanted: NSWindow.SharingType { enabled ? .none : .readOnly }

    /// Windows the guard leaves alone. Only the self-test's control probe (developer builds) is ever in it.
    static var exempt = Set<ObjectIdentifier>()

    static func apply(to window: NSWindow) {
        guard !exempt.contains(ObjectIdentifier(window)) else { return }
        if window.sharingType != wanted { window.sharingType = wanted }
    }

    static func applyToAll() {
        for window in NSApp.windows { apply(to: window) }
    }

    private static func install() {
        guard !installed else { return }
        installed = true
        swizzleOrderWindow()
        let center = NotificationCenter.default
        let names: [Notification.Name] = [NSWindow.didUpdateNotification, NSWindow.didBecomeKeyNotification,
                                          NSWindow.didBecomeMainNotification, NSWindow.willBeginSheetNotification,
                                          NSWindow.didExposeNotification, NSWindow.didChangeScreenNotification]
        for name in names {
            center.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated {
                    guard let window = note.object as? NSWindow else { return }
                    apply(to: window)
                    if let sheet = window.attachedSheet { apply(to: sheet) }
                }
            }
        }
        let timer = Timer(timeInterval: 0.25, repeats: true) { _ in MainActor.assumeIsolated { applyToAll() } }
        RunLoop.main.add(timer, forMode: .common)
    }

    private static func swizzleOrderWindow() {
        let original = #selector(NSWindow.order(_:relativeTo:))
        let replacement = #selector(NSWindow.stealth_orderWindow(_:relativeTo:))
        guard let a = class_getInstanceMethod(NSWindow.self, original),
              let b = class_getInstanceMethod(NSWindow.self, replacement) else { return }
        method_exchangeImplementations(a, b)
    }
}

extension NSWindow {
    /// After the swap this IS orderWindow(_:relativeTo:): the setting goes on first, then the window is ordered by the original code
    /// (the call below reaches it because the two implementations were exchanged; orderWindow:relativeTo: is order(_:relativeTo:) in Swift).
    @objc fileprivate func stealth_orderWindow(_ place: NSWindow.OrderingMode, relativeTo other: Int) {
        if place != .out {
            MainActor.assumeIsolated { StealthWindows.apply(to: self) }
        }
        stealth_orderWindow(place, relativeTo: other)
    }
}
