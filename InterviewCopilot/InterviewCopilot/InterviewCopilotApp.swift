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

        // CRITICAL for reliable permissions: if we're running from a DMG or an
        // App-Translocation path (random read-only /private/var/folders/…),
        // macOS keys Accessibility/Mic grants to that throwaway path — so the
        // grant NEVER persists and the user is asked every single launch. The
        // only fix is to run from /Applications. Detect it and offer to move.
        if let reason = runningFromUnstableLocation() {
            offerMoveToApplications(reason: reason)
            return   // don't build the panel — we're either moving or quitting
        }

        // Permission requests are handled by the in-app setup screen (PermissionSetupView).
        buildPanel()
    }

    // MARK: - Move-to-Applications gate (prevents translocation permission loss)

    /// Returns a human-readable reason if the app is running from a location
    /// where macOS won't persist permissions, or nil if the location is fine.
    private func runningFromUnstableLocation() -> String? {
        let path = Bundle.main.bundlePath

        // Already installed correctly.
        if path.hasPrefix("/Applications/") { return nil }
        if path.hasPrefix(NSHomeDirectory() + "/Applications/") { return nil }

        // App Translocation: Gatekeeper runs quarantined apps from a random
        // read-only path so grants can't stick.
        if path.contains("/AppTranslocation/") || path.hasPrefix("/private/var/folders/") {
            return "translocation"
        }
        // Running straight from the mounted DMG.
        if path.hasPrefix("/Volumes/") { return "dmg" }

        // Running from Downloads/Desktop — still not a stable install location.
        if path.contains("/Downloads/") || path.hasPrefix(NSHomeDirectory() + "/Desktop/") {
            return "downloads"
        }
        return nil
    }

    private func offerMoveToApplications(reason: String) {
        let alert = NSAlert()
        alert.messageText = "Move Interview Copilot to Applications"
        alert.informativeText = """
        To keep your microphone and keyboard permissions saved, Interview Copilot \
        needs to run from your Applications folder.

        Right now it's running from a temporary location, so macOS forgets your \
        permissions every time you open it. Click below to fix this permanently.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Applications & Relaunch")
        alert.addButton(withTitle: "Quit")

        if alert.runModal() == .alertFirstButtonReturn {
            moveToApplicationsAndRelaunch()
        } else {
            NSApp.terminate(nil)
        }
    }

    private func moveToApplicationsAndRelaunch() {
        let fm = FileManager.default
        let src = Bundle.main.bundleURL
        let dest = URL(fileURLWithPath: "/Applications/InterviewCopilot.app")

        // Replace any existing (possibly stale) copy so we always land clean.
        try? fm.removeItem(at: dest)
        do {
            try fm.copyItem(at: src, to: dest)
        } catch {
            // Couldn't auto-move (permissions) — fall back to manual instructions.
            let a = NSAlert()
            a.messageText = "Please move the app manually"
            a.informativeText = "Drag Interview Copilot into your Applications folder, then open it from there."
            a.addButton(withTitle: "OK")
            a.runModal()
            NSApp.terminate(nil)
            return
        }

        // Strip quarantine on the installed copy so it never gets translocated.
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-dr", "com.apple.quarantine", dest.path]
        try? xattr.run(); xattr.waitUntilExit()

        // Launch the freshly installed copy, then quit this (temporary) instance.
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: dest, configuration: config) { _, _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
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
