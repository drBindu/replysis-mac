import Cocoa
import Carbon

class GlobalHotkey {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    var onSpacePressed: (() -> Void)?
    var onF8Pressed:    (() -> Void)?
    var onF9Pressed:    (() -> Void)?
    var onF12Pressed:   (() -> Void)?
    var onKillPressed:  (() -> Void)?

    // The app mirrors two pieces of state here so the CGEvent tap thread can decide
    // whether to CONSUME a key WITHOUT touching @MainActor state (which would be a data
    // race). Plain Bool reads/writes are atomic on all supported archs, so a lock is
    // unnecessary. Updated on the main thread via updateGate(); read on the tap thread.
    nonisolated(unsafe) private var gateLoggedIn = false
    nonisolated(unsafe) private var gateEditing  = false

    /// Called on the main thread whenever sign-in state or text-field focus changes.
    func updateGate(loggedIn: Bool, editing: Bool) {
        gateLoggedIn = loggedIn
        gateEditing  = editing
    }

    private var lastSpaceTime: Date = .distantPast
    private let spaceDebounceSecs: Double = 0.4

    static weak var instance: GlobalHotkey?

    // macOS virtual key codes (from Carbon/Events.h)
    // F1=122 F2=120 F3=99 F4=118 F5=96 F6=97 F7=98 F8=100 F9=101 F10=109 F11=103 F12=111
    private let kVK_Space:  Int64 = 0x31
    private let kVK_F8:     Int64 = 100
    private let kVK_F9:     Int64 = 101
    private let kVK_F11:    Int64 = 103
    private let kVK_F12:    Int64 = 111   // ← correct F12 keycode
    private let kVK_F4:     Int64 = 118   // used for Ctrl+Shift+F4 kill

    init(onSpacePressed: @escaping () -> Void,
         onF8Pressed:    @escaping () -> Void,
         onF9Pressed:    @escaping () -> Void,
         onF12Pressed:   @escaping () -> Void,
         onKillPressed:  @escaping () -> Void) {
        self.onSpacePressed = onSpacePressed
        self.onF8Pressed    = onF8Pressed
        self.onF9Pressed    = onF9Pressed
        self.onF12Pressed   = onF12Pressed
        self.onKillPressed  = onKillPressed
        GlobalHotkey.instance = self
        setupEventTap()
    }

    private func setupEventTap() {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            // Use .defaultTap (an ACTIVE tap) — this is authorized by the ACCESSIBILITY
            // permission, which this app can reliably register for and the user can grant
            // (confirmed on-device: the app appears in and is granted Accessibility).
            // .listenOnly would instead require INPUT MONITORING, which this app never
            // manages to register in that list on the user's Mac — so the Space bar stayed
            // dead in the background. Accessibility must be granted BEFORE this process
            // launches for the tap to attach, which the relaunch-after-grant flow ensures.
            //
            // An ACTIVE tap lets us also CONSUME the push-to-talk keys (Space / F8 / F9)
            // so they never leak to the app in front. Passing Space through was what made
            // pressing it pop Finder's Quick Look / scroll a page / trigger another app.
            // handleEvent() returns true when we handled the key and it should be swallowed.
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let ref = refcon else { return Unmanaged.passUnretained(event) }
                let hk = Unmanaged<GlobalHotkey>.fromOpaque(ref).takeUnretainedValue()
                // macOS DISABLES the tap if our callback ever runs long, or on certain
                // user input. If we don't re-enable it, every hotkey (Space/F8/F9)
                // silently dies for the rest of the session — fatal mid-interview.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = hk.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                    Task { @MainActor in dlog("GlobalHotkey: tap was disabled (\(type.rawValue)) — re-enabled", tag: "HOTKEY") }
                    return Unmanaged.passUnretained(event)
                }
                // Swallow the event when we act on it; otherwise pass it through UNRETAINED
                // (passRetained would leak a +1 the system never releases).
                if hk.handleEvent(event) { return nil }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        guard let tap = eventTap else {
            // tapCreate returns nil when Accessibility trust isn't fully wired up for
            // this process YET — very common in the first moment after launch, even
            // when the permission is granted. Without a retry the hotkey stays dead
            // until the next relaunch (the "Space bar does nothing on the main screen"
            // bug). Retry on a short timer until it succeeds.
            tapRetryCount += 1
            if tapRetryCount <= maxTapRetries {
                Task { @MainActor in dlog("GlobalHotkey: tap not ready, retry \(self.tapRetryCount)/\(self.maxTapRetries) in 1s", tag: "HOTKEY") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.setupEventTap()
                }
            } else {
                Task { @MainActor in dlog("GlobalHotkey: CGEvent tap creation FAILED after \(self.maxTapRetries) retries — Accessibility not trusted", tag: "HOTKEY") }
            }
            return
        }
        tapRetryCount = 0
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let src = runLoopSource { CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes) }
        CGEvent.tapEnable(tap: tap, enable: true)
        Task { @MainActor in dlog("GlobalHotkey: event tap started OK", tag: "HOTKEY") }
    }

    // Retry state for the launch-time race where Accessibility trust isn't ready yet.
    private var tapRetryCount = 0
    private let maxTapRetries = 20

    /// Returns TRUE when we handled the key and it should be CONSUMED (not passed to the
    /// front app). Space is consumed only while logged in and not typing in our own text
    /// box — so it's a clean, dedicated push-to-talk that never disturbs Zoom/Finder/etc,
    /// yet still types normally in the Ask box and on the sign-in screen.
    private func handleEvent(_ event: CGEvent) -> Bool {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags   = event.flags

        // Ctrl+Shift+F4 → kill app (always consumed so it can't leak to the front app).
        if keyCode == kVK_F4 && flags.contains(.maskControl) && flags.contains(.maskShift) {
            DispatchQueue.main.async { [weak self] in self?.onKillPressed?() }
            return true
        }

        switch keyCode {
        case kVK_Space:
            // Signed out, or typing in our Ask box / a sign-in field → let Space behave
            // normally (type a space, scroll the front app). Don't toggle, don't consume.
            if !gateLoggedIn || gateEditing {
                // Diagnostic: this is why a background Space press can appear to "do
                // nothing" — the global tap DID see it but passed it through. If this logs
                // while the user expects a toggle, the gate mirror is the culprit.
                Task { @MainActor in dlog("GLOBAL Space passed through (gateLoggedIn=\(self.gateLoggedIn) gateEditing=\(self.gateEditing))", tag: "HOTKEY") }
                return false
            }
            let now = Date()
            // Swallow duplicates too, so a fast double-tap can never leak one Space out.
            guard now.timeIntervalSince(lastSpaceTime) >= spaceDebounceSecs else { return true }
            lastSpaceTime = now
            DispatchQueue.main.async { [weak self] in self?.onSpacePressed?() }
            return true   // consume — Space belongs to Copilot

        case kVK_F8:
            guard gateLoggedIn else { return false }
            DispatchQueue.main.async { [weak self] in self?.onF8Pressed?() }
            return true

        case kVK_F9:
            guard gateLoggedIn else { return false }
            DispatchQueue.main.async { [weak self] in self?.onF9Pressed?() }
            return true

        case kVK_F12:
            DispatchQueue.main.async { [weak self] in
                NotificationCenter.default.post(name: .showDebugLog, object: nil)
                self?.onF12Pressed?()
            }
            return false   // debug toggle — harmless to let through

        default:
            return false
        }
    }

    deinit {
        if let tap = eventTap   { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
    }
}
