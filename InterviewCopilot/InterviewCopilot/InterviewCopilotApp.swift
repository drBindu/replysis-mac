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
        // SINGLE-INSTANCE GUARD: if another copy of this app is already running, activate
        // that one and quit THIS launch immediately — before creating a window, spawning
        // the engine, or touching hotkeys/permissions. Without this, a user double-clicking
        // the icon again (easy to do for an accessory app with no normal Dock presence)
        // produces a confusing second window alongside the first.
        //
        // SKIPPED when this launch is itself an intentional relaunch (see
        // MainViewModel.relaunchApp, fired after Accessibility/Screen Recording is newly
        // granted) — that flow deliberately keeps the OLD instance alive for ~0.4s while
        // the NEW one starts up, so the new instance must NOT see the old one and mistake
        // it for a duplicate. The env var set on that specific launch tells us which case
        // this is.
        let isIntentionalRelaunch = ProcessInfo.processInfo.environment[MainViewModel.relaunchEnvKey] == "1"
        if !isIntentionalRelaunch, let bundleID = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if let existing = others.first {
                dlog("Another instance is already running (pid=\(existing.processIdentifier)) — activating it and quitting this launch", tag: "BOOT")
                existing.activate(options: [.activateAllWindows])
                NSApp.terminate(nil)
                return
            }
        }

        // LSUIElement=YES in Info.plist makes the process start as .accessory from birth
        // (no menu bar entry, no Dock icon). The runtime call below is belt-and-suspenders
        // in case something re-sets the policy, and also clears any SwiftUI default menus.
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = nil

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

        // Start the Sparkle updater now — it checks SUFeedURL in the background once a day
        // and lets Settings trigger a manual check. See AppUpdater.swift for why this exists.
        _ = AppUpdater.shared

        // Permission requests are handled by the in-app setup screen (PermissionSetupView).
        buildPanel()

        // Changing activation policy can invalidate CGEventTaps created earlier.
        // Re-create the tap now that the final policy (.accessory) is in effect.
        vm.reinstateHotkeys()
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
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Desired size, clamped so it always fits the display — never taller than the
        // screen, which also prevents the "window is too long" overshoot on smaller Macs.
        let w = min(1120, screen.width  - 40)
        let h = min(740,  screen.height - 40)
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

        // Bound the window so nothing (a tall SwiftUI layout or a sheet appearing) can blow
        // it up or shrink it away — keeps a sane, fixed-feel size.
        panel.contentMinSize = CGSize(width: 820, height: 560)
        panel.contentMaxSize = CGSize(width: screen.width, height: screen.height)

        // Plain NSHostingView — DO NOT override hitTest, it breaks SwiftUI event routing.
        let hosting = NSHostingView(rootView: MainView().environment(vm))
        // CRITICAL fix for the "window keeps getting longer/bigger" bug: stop the hosting
        // view from driving the window size. By default NSHostingView reports SwiftUI's
        // fitting size and AppKit grows the borderless window to match — and this layout
        // uses maxHeight:.infinity everywhere, so that size can balloon (especially when a
        // sheet appears). Empty options = SwiftUI fits INTO the window, never the reverse.
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.contentView?.clearLayerBackgrounds()

        panel.makeKeyAndOrderFront(nil)
        // Activate the app so its panel is the KEY window immediately. Without this, an
        // .accessory app can show a visible panel that is NOT the active window, so the
        // in-app (local) Space/F8/F9 monitor receives nothing until the user clicks the
        // panel — the "I have to click the app before Space works" bug. Activating here
        // makes Space work the moment the window appears. (Background/other-app use still
        // relies on the global Accessibility tap.)
        NSApp.activate(ignoringOtherApps: true)
        self.panel = panel
        vm.mainPanel = panel   // give ViewModel a direct reference (needed with .accessory policy)
    }

    // Keep the app alive when sheets/popovers close (the borderless panel isn't
    // counted as a "real" window by AppKit). Quit only via ✕ or Ctrl+Shift+F4.
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
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
