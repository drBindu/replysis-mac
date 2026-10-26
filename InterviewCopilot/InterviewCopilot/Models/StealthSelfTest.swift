import AppKit
import ScreenCaptureKit

// ══════════════════════════════════════════════════════════════════════════
// Proven, not trusted (Windows StealthSelfTest, 2026-10-22). A few seconds after start a 16 pt magenta square is shown with the same
// hiding every Replysis window gets (sharingType .none), the screen is captured the way a screen share captures it (ScreenCaptureKit,
// what Zoom, Meet and Teams use on macOS), and the square's pixels are looked at: magenta means a share would see Replysis.
//
// The answer goes into the setup page's "Screen share" row (owner, 2026-10-23: "no need to warn, show in the setup whether it is
// visible or stealth"), never a popup, and a Visible result is reported to admin. Without the Screen Recording permission nothing can
// be captured, so the row says it was not checked rather than claiming Hidden; the person is never asked for the permission here.
// ══════════════════════════════════════════════════════════════════════════
enum StealthSelfTest {
    /// The probe on screen right now, if any.
    @MainActor private static weak var currentProbe: NSWindow?
    @MainActor static func isProbe(_ window: NSWindow) -> Bool { currentProbe === window }

    /// Shows the probe, captures it like a screen share, removes it. Main actor: it makes a window.
    @MainActor
    static func run() async -> ScreenShareState {
        guard CGPreflightScreenCaptureAccess() else { return .notChecked }
        guard let screen = NSScreen.main else { return .notChecked }
        let size: CGFloat = 16
        // Top left, under the menu bar, away from notifications (Windows moved its square there for the same reason).
        let frame = NSRect(x: screen.visibleFrame.minX + 6, y: screen.visibleFrame.maxY - size - 6, width: size, height: size)
        let probe = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        probe.backgroundColor = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
        probe.isOpaque = true
        probe.hasShadow = false
        probe.ignoresMouseEvents = true
        probe.level = .statusBar
        probe.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        probe.sharingType = .none
        #if DEBUG
        // The test's control: a probe without hiding must be reported Visible, which proves the check can see a window at all.
        if ProcessInfo.processInfo.environment["REPLYSIS_SELFTEST_UNHIDDEN"] == "1" {
            StealthWindows.exempt.insert(ObjectIdentifier(probe))
            probe.sharingType = .readOnly
        }
        #endif
        currentProbe = probe
        probe.orderFrontRegardless()
        defer { probe.orderOut(nil); StealthWindows.exempt.remove(ObjectIdentifier(probe)) }
        try? await Task.sleep(nanoseconds: 400_000_000)   // let the window server draw it

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let screenNumber = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            guard let display = content.displays.first(where: { $0.displayID == screenNumber }) ?? content.displays.first else { return .notChecked }
            let config = SCStreamConfiguration()
            // The probe in display points, top-left origin, as ScreenCaptureKit wants it.
            let topLeftY = screen.frame.maxY - frame.maxY
            config.sourceRect = CGRect(x: frame.minX - screen.frame.minX, y: topLeftY, width: size, height: size)
            config.width = Int(size) * 2
            config.height = Int(size) * 2
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: []),
                                                                   configuration: config)
            guard let rgb = centerPixel(image) else { return .notChecked }
            dlog("STEALTH: self-test pixel \(rgb.0),\(rgb.1),\(rgb.2) from a \(image.width)x\(image.height) capture at \(Int(config.sourceRect.minX)),\(Int(config.sourceRect.minY))", tag: "STEALTH")
            return StealthProbe.looksLikeProbe(red: rgb.0, green: rgb.1, blue: rgb.2) ? .visible : .hidden
        } catch {
            dlog("STEALTH: self-test could not capture the screen: \(error.localizedDescription)", tag: "STEALTH")
            return .notChecked
        }
    }

    private static func centerPixel(_ image: CGImage) -> (Int, Int, Int)? {
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        // Draw the image so that its centre pixel lands on the one-pixel context.
        ctx.draw(image, in: CGRect(x: -w / 2 + 0.5, y: -h / 2 + 0.5, width: w, height: h))
        return (Int(px[0]), Int(px[1]), Int(px[2]))
    }
}
