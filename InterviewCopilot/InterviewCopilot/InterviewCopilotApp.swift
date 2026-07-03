import SwiftUI
import AppKit

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

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: FloatingPanel?
    let vm = MainViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        // Startup diagnostics — first lines in the debug log for supporting real users.
        dlog("=== LAUNCH === v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") | path=\(Bundle.main.bundlePath)", tag: "BOOT")
        dlog("AXIsProcessTrusted=\(AXIsProcessTrusted())", tag: "BOOT")

        // If we're running from a DMG or an App-Translocation path (random
        // read-only /private/var/folders/…), macOS keys Accessibility/Mic grants
        // to that throwaway path so they never persist. Show password-free guidance
        // to move the app to /Applications. IMPORTANT: we do NOT copy the app
        // ourselves — writing into /Applications programmatically triggers an admin
        // PASSWORD prompt. Dragging in Finder never does. So we just guide.
        if runningFromUnstableLocation() {
            guideToApplicationsFolder()
            return   // don't build the panel — the user needs to relaunch from /Applications
        }

        // Permission requests are handled by the in-app setup screen (PermissionSetupView).
        buildPanel()
    }

    // MARK: - Move-to-Applications guidance (prevents translocation permission loss)

    /// True only when the app is running from a location where macOS genuinely
    /// won't persist permissions: an App-Translocation sandbox, or the DMG itself.
    /// A normal install in /Applications (or ~/Applications) returns false, and so
    /// does Desktop/Downloads — those keep a stable path, so permissions DO stick
    /// there and we must not nag or, worse, try to move the app.
    private func runningFromUnstableLocation() -> Bool {
        let path = Bundle.main.bundlePath
        if path.contains("/AppTranslocation/") { return true }   // Gatekeeper randomized path
        if path.hasPrefix("/private/var/folders/") { return true }
        if path.hasPrefix("/Volumes/") { return true }            // still on the mounted DMG
        return false
    }

    private func guideToApplicationsFolder() {
        let alert = NSAlert()
        alert.messageText = "Move Interview Copilot to your Applications folder"
        alert.informativeText = """
        Interview Copilot is opening from a temporary location, so macOS won't \
        remember your microphone and keyboard permissions.

        To fix it permanently — no password needed:
        1. Drag Interview Copilot into the Applications folder.
        2. Open it from Applications (or Launchpad).
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Applications Folder")
        alert.addButton(withTitle: "Quit")

        if alert.runModal() == .alertFirstButtonReturn {
            // Just reveal /Applications in Finder — a plain Finder drag needs no password.
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
        }
        NSApp.terminate(nil)
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
