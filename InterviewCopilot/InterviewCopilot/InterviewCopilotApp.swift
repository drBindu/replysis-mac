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
        // Never touch the frosted material or anything inside it. This walks every subview
        // forcing wantsLayer and a clear backing colour, which is right for SwiftUI's hosting
        // views and fatal for an NSVisualEffectView: the blur IS that view's backing, so
        // clearing it leaves a pane of nothing where the glass should be. It currently runs
        // before SwiftUI builds the effect view, so the damage is latent rather than visible
        // — the kind that surfaces later after an unrelated change and looks inexplicable.
        if self is NSVisualEffectView { return }
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
        // Do not let a closed pipe kill the app. This is the first thing that happens,
        // before anything can open one.
        //
        // The app writes captured system audio into a FIFO the engine reads. When the engine
        // dies — quota refusal, crash, being killed, any reason at all — the reader is gone,
        // and the very next write raises SIGPIPE, whose default action is to terminate the
        // process. The app vanished in about a second with no crash report, because a signal
        // death is not a crash. Exit code 141 is 128 + 13, and that number was the only
        // evidence there was.
        //
        // The write loop in SystemAudioTapper ALREADY handles this: `if w <= 0 { break }`
        // then reopens the FIFO. That recovery was correct and permanently unreachable,
        // because the process was killed before write() could return -1. Ignoring the signal
        // is what turns an unreachable branch into the one that runs.
        signal(SIGPIPE, SIG_IGN)

        // Start crash reporting FIRST — before any other launch work — so if something
        // below crashes on a user's Mac, the report still gets captured. No-op in debug.
        CrashReporter.start()

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
            let marked = SpeechmaticsEngine.shared.appDataFolder
            var stillThere = others.first
            // A copy that is still closing (saving, ending its speech session) is not a duplicate: a restart
            // done in a hurry would otherwise hand over to it and quit, and leave nothing running. Wait for it,
            // up to eight seconds. A real second copy, with nothing closing, is handed over to at once.
            if let closing = stillThere, ClosingMarker.isClosing(pid: closing.processIdentifier, in: marked) {
                dlog("The previous copy (pid=\(closing.processIdentifier)) is still closing — waiting up to 8 s for it instead of taking it for a duplicate", tag: "BOOT")
                if ClosingMarker.waitForExit(pid: closing.processIdentifier) {
                    dlog("The previous copy has closed — starting normally", tag: "BOOT")
                    stillThere = nil
                }
            }
            if let existing = stillThere {
                dlog("Another instance is already running (pid=\(existing.processIdentifier)) — activating it and quitting this launch", tag: "BOOT")
                existing.activate(options: [.activateAllWindows])
                NSApp.terminate(nil)
                return
            }
            ClosingMarker.clear(in: marked)
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
        // .controller is `lazy` (needs `self` fully initialized first as the Sparkle
        // delegate) — touch it explicitly so the daily background check actually starts
        // now, not only whenever Settings happens to be opened.
        _ = AppUpdater.shared.controller

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
        alert.messageText = "Move Replysis to your Applications folder"
        alert.informativeText = """
        Replysis is opening from a temporary location, so macOS won't \
        remember your microphone and keyboard permissions.

        To fix it permanently — no password needed:
        1. Drag Replysis into the Applications folder.
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

    /// Where the size the person chose is kept: its own small file in the app's folder.
    private static var sizeFile: URL { SpeechmaticsEngine.shared.appDataFolder.appendingPathComponent("window.json") }

    /// The size the person last dragged the window to, kept inside this screen and above the minimum.
    private static func savedPanelSize(fitting screen: NSRect) -> CGSize? {
        guard let data = try? Data(contentsOf: sizeFile),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Double],
              let w = d["w"], let h = d["h"] else { return nil }
        let width = min(max(CGFloat(w), 860), screen.width)
        let height = min(max(CGFloat(h), 540), screen.height)
        dlog("PANEL: using the size the person chose: \(Int(width))x\(Int(height))", tag: "BOOT")
        return CGSize(width: width, height: height)
    }

    private func buildPanel() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Sized as a FRACTION of the display, then capped — not a fixed 1120x740 clamped
        // only by the screen. On a 1440x900 laptop that fixed size covered 78% of the
        // width and 82% of the height: 64% of the whole screen, for a tool whose job is
        // to sit beside a video call rather than bury it. Measured, after the owner said
        // the window was too large.
        // WIDE ENOUGH FOR THE HEADER, which Windows learned the hard way: its controls
        // needed ~1,180px inside a 980px window and "Read screen" was drawn over
        // "Practice" (MAC_CATCHUP, 2026-09-20). Measured on this toolbar: AUTO|MANUAL 152,
        // Interview|Practice 167, Read screen 123, Compact 89, plus the pin, the separator,
        // the status pill, the timer and the account — about 1,100pt in all. A window that
        // fits only on a big display is the same bug, so the window opens to fit the row.
        // A well proportioned window rather than a wide strip: about 920 by 600 on a 13" display
        // (1.5 to 1), where it was 1200 by 472 (2.5 to 1). The header's second row is what made
        // the narrower width possible. Owner, 2026-10-02: "too rectangular big, not a good fit".
        // 920 by 600 was then called "too small", so the default sits between the two: about
        // 1040 by 660 on a 13" display (1.6 to 1). And a size the person drags the window to is
        // remembered (below), so the right size is theirs to choose once.
        var w = min(1040, round(screen.width  * 0.72))
        var h = min(660, round(screen.height * 0.82))
        if let saved = Self.savedPanelSize(fitting: screen) { w = saved.width; h = saved.height }
        let origin = NSPoint(x: screen.midX - w / 2, y: screen.midY - h / 2)

        // Borderless → no native traffic-light buttons (custom ✕ lives in the header).
        let panel = FloatingPanel(
            contentRect: NSRect(origin: origin, size: CGSize(width: w, height: h)),
            styleMask: [.borderless, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )

        // NO frame autosave, deliberately.
        //
        // It remembered the wrong thing. SwiftUI's content minimum grows this window after
        // layout — measured 864x474 at creation, 1097x587 two seconds later — and the frame
        // that got saved was the GROWN one. Next launch restored 1097, content grew that,
        // and it saved larger still: 864, 1097, 1323, 1525. The autosave was not remembering
        // a size the user chose, it was remembering one the content chose, and compounding it
        // every launch. That is the "why is it big again" the owner reported four times.
        //
        // Without it the window opens at the computed size every time and settles wherever
        // the content needs — the same place each launch, which is the actual requirement.
        // Restoring a user-chosen size is worth having, but not at the cost of a window that
        // grows without bound, and not before the content stops driving the size at all.

        // Report the frame actually adopted. The default was changed once already without
        // any way to tell from outside whether it took effect, an autosaved frame overrode
        // it, or a content minimum was holding it open.
        // Remember a size the person chose by dragging an edge. Only the end of a drag counts: a
        // size the content or the app set must never be saved back as if it were a choice (that
        // is how the window grew at every launch when the frame was autosaved).
        NotificationCenter.default.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: panel, queue: .main) { note in
            guard let win = note.object as? NSWindow else { return }
            if let data = try? JSONSerialization.data(withJSONObject: ["w": Double(win.frame.width), "h": Double(win.frame.height)]) {
                try? data.write(to: AppDelegate.sizeFile)
            }
            dlog("PANEL: size chosen by the person: \(Int(win.frame.width))x\(Int(win.frame.height))", tag: "BOOT")
        }
        dlog("PANEL: opened \(Int(panel.frame.width))x\(Int(panel.frame.height)) on a "
             + "\(Int(screen.width))x\(Int(screen.height)) screen", tag: "BOOT")

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
        // 820x560 was a floor no user could get under, so "make the window smaller" had a
        // hard limit well above what was being asked for. Lowered so the default can shrink
        // and so someone on a small display can shrink it further still.
        panel.contentMinSize = CGSize(width: 860, height: 540)
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


        // Measure again AFTER SwiftUI has attached and laid out. The line above records the
        // frame we asked for; if the content's minimum width is larger, AppKit grows the
        // window to fit and THAT size is what gets autosaved — so every launch restores a
        // window bigger than the default, and the default looks like it is being ignored.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak panel] in
            guard let p = panel else { return }
            dlog("PANEL: after layout \(Int(p.frame.width))x\(Int(p.frame.height))", tag: "BOOT")
        }

        // Activate the app so its panel is the KEY window immediately. Without this, an
        // .accessory app can show a visible panel that is NOT the active window, so the
        // in-app (local) Space/F8/F9 monitor receives nothing until the user clicks the
        // panel — the "I have to click the app before Space works" bug. Activating here
        // makes Space work the moment the window appears. (Background/other-app use still
        // relies on the global Accessibility tap.)
        NSApp.activate(ignoringOtherApps: true)
        self.panel = panel
        vm.mainPanel = panel   // give ViewModel a direct reference (needed with .accessory policy)
        panel.level = vm.isPinnedOnTop ? .floating : .normal   // pinned by default, remembered
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
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // ASK BEFORE ENDING AN INTERVIEW. ✕ was one line calling terminate: a mis-click
        // mid-interview ended the session, with nothing on screen and nothing in the log to
        // explain it. Windows had the identical bug and fixed it the same way (5ad20ba).
        // An idle window still closes instantly, and the kill chord is never prompted.
        let busy = MainActor.assumeIsolated { vm.isListening || vm.isProcessing || vm.isScreenAnalyzing }
        if busy, !MainViewModel.quitWithoutAsking {
            let alert = NSAlert()
            alert.messageText = "Quit Replysis?"
            alert.informativeText = "An interview is still running. Quitting stops listening and closes the answers."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Keep running")
            alert.addButton(withTitle: "Quit")
            // AN ACCESSORY APP DOES NOT GET FOCUS FOR FREE. Without this the alert can come
            // up behind the meeting window, so the app looks frozen and the keystroke that
            // would answer it goes somewhere else entirely — measured here, the dialog was
            // unreachable and the quit never resolved. Raise it deliberately, above
            // full-screen windows, and make it key.
            NSApp.activate(ignoringOtherApps: true)
            alert.window.level = .modalPanel
            alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            alert.window.makeKeyAndOrderFront(nil)
            let quit = alert.runModal() == .alertSecondButtonReturn
            dlog("Quit requested while busy — \(quit ? "confirmed by the user" : "cancelled, the app keeps running")", tag: "LIFECYCLE")
            if !quit { return .terminateCancel }
            ClosingMarker.markClosing(in: SpeechmaticsEngine.shared.appDataFolder, pid: ProcessInfo.processInfo.processIdentifier)
            return .terminateNow
        }

        // WHO ASKED. The app was found closed twice during testing with nothing in the log
        // to say why, which from the outside is indistinguishable from "it stopped
        // answering". Recording the moment and the cause turns that into something
        // diagnosable: a quit from the menu or ⌘Q, a kill chord, a logout, or macOS.
        dlog("Quit requested — the app is terminating (frontmost=\(NSApp.isActive))", tag: "LIFECYCLE")
        ClosingMarker.markClosing(in: SpeechmaticsEngine.shared.appDataFolder, pid: ProcessInfo.processInfo.processIdentifier)
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        dlog("Terminating now", tag: "LIFECYCLE")
        MainActor.assumeIsolated {
            // The sitting ends here, so the banked listening remainder is billed here —
            // this is the only place it ever is. Blocking, because a Task started during
            // termination dies with the process.
            vm.flushListeningMeterOnExit(synchronously: true)
            // And wait: the engine's graceful shutdown now runs off the main thread, and this process must not
            // exit before it has told the speech service the session is over.
            SpeechmaticsEngine.shared.stopAndWait()
            // The live transcript is the ONE thing this app leaves on disk unencrypted —
            // the engine writes it directly and cannot decrypt what everything else is
            // protected with. It is a scratch file for the turn in progress and has no
            // value once the app closes, but it held the last thing an interviewer said
            // until the next launch happened to overwrite it.
            SpeechmaticsEngine.shared.deleteLatestTxt()
        }
    }
}
