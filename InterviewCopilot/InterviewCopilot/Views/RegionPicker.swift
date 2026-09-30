import AppKit

// ══════════════════════════════════════════════════════════════════════════
// Drag a box around one part of the screen, and read only that.
//
// Windows has had this on F7 since before the Mac existed (RegionCaptureWindow.xaml).
// It is the control that matters when the interviewer's screen holds a whole IDE and the
// question is about eight lines of it: the full-screen capture spends its pixel budget on
// everything else, and small text is exactly what a vision model reads worst.
//
// The picker is a borderless window per display, above everything, with the app's own
// windows excluded from the capture that follows — so nothing of Replysis is ever in the
// pixels, picker included (it is gone before the capture runs).
// ══════════════════════════════════════════════════════════════════════════
@MainActor
final class RegionPicker {
    static let shared = RegionPicker()

    private var windows: [NSWindow] = []
    private var completion: ((CGRect?) -> Void)?
    private var picking = false
    private var escMonitors: [Any] = []
    private var safetyTimer: Timer?

    /// Shows the picker on every display. The rectangle comes back in CoreGraphics screen
    /// coordinates (origin top-left, as CGDisplayBounds and ScreenCaptureKit use), or nil
    /// when the user pressed Escape or clicked without dragging.
    func pick(_ completion: @escaping (CGRect?) -> Void) {
        guard !picking else { return }       // a second F7 must not open a second picker
        picking = true
        self.completion = completion

        for screen in NSScreen.screens {
            let view = RegionSelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.onFinish = { [weak self] rect in self?.finish(rect, on: screen) }
            view.onCancel = { [weak self] in self?.finish(nil, on: screen) }

            // A plain borderless NSWindow can never become key, so keyDown is never
            // delivered and Escape does nothing — measured: the picker opened and could
            // only be closed by quitting the app. canBecomeKey is the whole fix.
            let window = RegionPickerWindow(contentRect: screen.frame, styleMask: [.borderless],
                                            backing: .buffered, defer: false, screen: screen)
            window.contentView = view
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.level = .screenSaver          // above full-screen meeting windows
            window.ignoresMouseEvents = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            // Never recorded by anything, the same as the main window.
            window.sharingType = .none
            window.orderFrontRegardless()
            windows.append(window)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
        }
        NSApp.activate(ignoringOtherApps: true)

        // Escape, whoever has focus. An accessory app does not reliably take key focus
        // from the meeting window, so keyDown on the view alone is not enough — measured:
        // the picker opened and Escape did nothing, leaving a dimmed screen with no way
        // out but quitting. Two monitors: one for keys that do reach this app, one for
        // keys that go elsewhere.
        let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.cancelFromMonitor()
            return nil
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            self?.cancelFromMonitor()
        }
        escMonitors = [local as Any, global as Any]

        // And a backstop, because a full-screen overlay that cannot be dismissed is the
        // worst thing this feature could do in the middle of an interview.
        safetyTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.cancelFromMonitor() }
        }
    }

    private func cancelFromMonitor() {
        guard picking, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        finish(nil, on: screen)
    }

    private func finish(_ rectInScreen: CGRect?, on screen: NSScreen) {
        guard picking else { return }
        picking = false
        let done = completion
        completion = nil
        safetyTimer?.invalidate(); safetyTimer = nil
        for m in escMonitors { NSEvent.removeMonitor(m) }
        escMonitors.removeAll()
        for w in windows { w.orderOut(nil) }
        windows.removeAll()

        guard let r = rectInScreen, r.width > 8, r.height > 8 else { done?(nil); return }

        // AppKit's origin is the bottom-left of the main display; capture wants top-left.
        let frame = screen.frame
        let globalX = frame.origin.x + r.origin.x
        let globalYBottom = frame.origin.y + r.origin.y
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? frame.maxY
        let flippedY = primaryTop - (globalYBottom + r.height)
        done?(CGRect(x: globalX, y: flippedY, width: r.width, height: r.height))
    }
}

/// Borderless windows refuse key status by default; this one needs it for Escape.
final class RegionPickerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The dimmed sheet with a clear rectangle where the selection is.
final class RegionSelectionView: NSView {
    var onFinish: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private var start: NSPoint?
    private var current: NSPoint?

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    private var selection: NSRect? {
        guard let s = start, let c = current else { return nil }
        return NSRect(x: min(s.x, c.x), y: min(s.y, c.y),
                      width: abs(c.x - s.x), height: abs(c.y - s.y))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()

        guard let sel = selection else {
            let hint = "Drag a box around the part to read   ·   Esc to cancel"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.85),
            ]
            let size = hint.size(withAttributes: attrs)
            hint.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
                      withAttributes: attrs)
            return
        }

        // Clear the selection so what is being chosen is visible while choosing it.
        NSGraphicsContext.current?.cgContext.clear(sel)
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let path = NSBezierPath(rect: sel)
        path.lineWidth = 1
        path.stroke()

        let label = "\(Int(sel.width)) × \(Int(sel.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        label.draw(at: NSPoint(x: sel.minX, y: sel.maxY + 4), withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        if let sel = selection, sel.width > 8, sel.height > 8 { onFinish?(sel) } else { onCancel?() }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }      // Esc
    }

    // Belt and braces: Escape also arrives here when something else holds first responder,
    // and a right-click is the other thing people try when they want out.
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func rightMouseDown(with event: NSEvent) { onCancel?() }
}
