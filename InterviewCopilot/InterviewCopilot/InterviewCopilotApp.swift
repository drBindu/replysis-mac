import SwiftUI
import AppKit
import AVFoundation

@main
struct InterviewCopilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No WindowGroup — we create our own borderless window in AppDelegate.
        Settings { EmptyView() }
    }
}

// Borderless window that behaves like a NORMAL app window:
//   • canBecomeKey/Main = true → clicking it brings it forward and lets you type;
//     clicking ANOTHER app brings that app forward (no domination).
//   • Default level is .normal so it never sits on top of the app you switch to.
//     The "Pin on top" button raises it to .floating for an actual interview.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool  { true }
    override var canBecomeMain: Bool { true }
}

extension NSView {
    func clearLayerBackgrounds() {
        wantsLayer = true
        layer?.backgroundColor = CGColor.clear
        subviews.forEach { $0.clearLayerBackgrounds() }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: FloatingPanel?
    let vm = MainViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let opts: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(opts)

        // Request Microphone permission up front. The speechmatics_engine runs as a
        // CHILD process; macOS attributes its mic use to THIS app, so the app must hold
        // the TCC grant — otherwise the engine opens the mic but only receives silence
        // (the cause of empty transcripts). This also registers the app in
        // System Settings → Privacy & Security → Microphone.
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in dlog("Microphone permission granted=\(granted)", tag: "PERM") }
        }

        // Regular app: normal window management — clicking other apps brings them
        // forward, IC goes behind. It does NOT dominate other apps.
        NSApp.setActivationPolicy(.regular)
        buildPanel()
    }

    private func buildPanel() {
        let w: CGFloat = 1120, h: CGFloat = 740
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: screen.midX - w / 2, y: screen.midY - h / 2)

        // Borderless → no native traffic-light buttons (custom ✕ lives in the header).
        let panel = FloatingPanel(
            contentRect: NSRect(origin: origin, size: CGSize(width: w, height: h)),
            styleMask: [.borderless, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )

        // Transparency comes from the SwiftUI content opacity, not the window.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        // NORMAL level by default — does not sit on top of other apps. The pin
        // button (MainViewModel.togglePin) raises it to .floating when wanted.
        panel.level = .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false

        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        // Plain NSHostingView — DO NOT override hitTest, it breaks SwiftUI event routing.
        let hosting = NSHostingView(rootView: MainView().environment(vm))
        panel.contentView = hosting
        panel.contentView?.clearLayerBackgrounds()

        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    // Keep the app alive when sheets/popovers close (the borderless panel isn't
    // counted as a "real" window by AppKit). Quit only via ✕ or Ctrl+Shift+F4.
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel?.makeKeyAndOrderFront(nil)
        return false
    }

    // Stop the Speechmatics child process on EVERY quit path (✕, Ctrl+Shift+F4, Cmd+Q,
    // dock-quit, logout). It's a CHILD process — terminating the app does NOT kill it,
    // so without this it orphans, keeps holding the mic, and keeps streaming audio to
    // Speechmatics (burning API quota) until the next launch. Runs synchronously here,
    // before the app exits, so the SIGTERM is actually delivered.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            SpeechmaticsEngine.shared.stop()
        }
    }
}
