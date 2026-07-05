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
            // dead in the background. We pass every event straight through unmodified
            // (return passUnretained below), so an active tap never delays or drops the
            // user's real keystrokes. Accessibility must be granted BEFORE this process
            // launches for the tap to attach, which the relaunch-after-grant flow ensures.
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                // Pass-through tap: return the event UNRETAINED. passRetained would add a
                // +1 the system never releases — a leak on every keystroke.
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
                hk.handleEvent(event)
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

    private func handleEvent(_ event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags   = event.flags

        // Ctrl+Shift+F4 → kill app
        if keyCode == kVK_F4 && flags.contains(.maskControl) && flags.contains(.maskShift) {
            DispatchQueue.main.async { [weak self] in self?.onKillPressed?() }
            return
        }

        switch keyCode {
        case kVK_Space:
            let now = Date()
            guard now.timeIntervalSince(lastSpaceTime) >= spaceDebounceSecs else { return }
            lastSpaceTime = now
            DispatchQueue.main.async { [weak self] in self?.onSpacePressed?() }

        case kVK_F8:
            DispatchQueue.main.async { [weak self] in self?.onF8Pressed?() }

        case kVK_F9:
            DispatchQueue.main.async { [weak self] in self?.onF9Pressed?() }

        case kVK_F12:
            DispatchQueue.main.async { [weak self] in
                NotificationCenter.default.post(name: .showDebugLog, object: nil)
                self?.onF12Pressed?()
            }

        default:
            break
        }
    }

    deinit {
        if let tap = eventTap   { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
    }
}
