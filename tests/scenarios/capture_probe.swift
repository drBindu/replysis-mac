// What a screen share really sees of an app's windows, the way Zoom, Meet and Teams capture on macOS 12.3+ (ScreenCaptureKit).
//   capture_probe <pid>
// For each display holding a window of <pid>: capture the whole display twice, once as a share would (nothing excluded) and once with
// that app's windows explicitly cut out. If the windows are hidden from capture, the two pictures are the same inside the windows'
// frames; if a share can see them, they differ there. Also tries sharing one window on its own ("share this window").
// Prints one line per window: "WINDOW <id> <title> frame=... shared-screen=HIDDEN|VISIBLE diff=<fraction> window-share=..."
import Foundation
import ScreenCaptureKit
import CoreGraphics

let pid = pid_t(CommandLine.arguments[1])!
// capture_probe <pid> snap <file>: save what a share of the main display sees, to compare later.
// capture_probe <pid> since <file>: fraction of the screen that changed since that snap (anything this app shows that a share can see).
let mode = CommandLine.arguments.count > 3 ? CommandLine.arguments[2] : ""
let snapFile = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : ""

func pixels(_ img: CGImage) -> (Data, Int, Int) {
    let w = img.width, h = img.height
    var data = Data(count: w * h * 4)
    data.withUnsafeMutableBytes { buf in
        let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return (data, w, h)
}

func run() async throws {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    if !mode.isEmpty {
        let display = content.displays[0]
        let cfg = SCStreamConfiguration(); cfg.width = Int(display.frame.width); cfg.height = Int(display.frame.height); cfg.showsCursor = false
        let img = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg)
        let (now, _, _) = pixels(img)
        if mode == "snap" { try now.write(to: URL(fileURLWithPath: snapFile)); print("SNAP saved"); return }
        let before = try Data(contentsOf: URL(fileURLWithPath: snapFile))
        var differ = 0, total = 0
        now.withUnsafeBytes { pa in before.withUnsafeBytes { pb in
            let A = pa.bindMemory(to: UInt8.self), B = pb.bindMemory(to: UInt8.self); var i = 0
            while i + 2 < min(A.count, B.count) { if abs(Int(A[i]) - Int(B[i])) + abs(Int(A[i+1]) - Int(B[i+1])) + abs(Int(A[i+2]) - Int(B[i+2])) > 24 { differ += 1 }; total += 1; i += 32 }
        } }
        print("CHANGED \(String(format: "%.4f", Double(differ) / Double(max(total, 1))))")
        let all = content.windows.filter { $0.owningApplication?.processID == pid }
        print("LISTED \(all.map { "\($0.windowID):\(Int($0.frame.width))x\(Int($0.frame.height))" }.joined(separator: " "))")
        return
    }
    let mine = content.windows.filter { $0.owningApplication?.processID == pid && $0.frame.width > 20 && $0.frame.height > 20 }
    if mine.isEmpty { print("NO WINDOWS on screen for pid \(pid)"); return }
    for display in content.displays {
        let onThis = mine.filter { display.frame.intersects($0.frame) }
        if onThis.isEmpty { continue }
        let cfg = SCStreamConfiguration()
        cfg.width = Int(display.frame.width); cfg.height = Int(display.frame.height); cfg.showsCursor = false
        let shared = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg)
        let cut = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: onThis), configuration: cfg)
        let (a, w, h) = pixels(shared), (b, _, _) = pixels(cut)
        let sx = Double(w) / display.frame.width, sy = Double(h) / display.frame.height
        for win in onThis {
            let f = win.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            let x0 = max(0, Int(f.minX * sx)), x1 = min(w, Int(f.maxX * sx)), y0 = max(0, Int(f.minY * sy)), y1 = min(h, Int(f.maxY * sy))
            var differ = 0, total = 0
            a.withUnsafeBytes { pa in b.withUnsafeBytes { pb in
                let A = pa.bindMemory(to: UInt8.self), B = pb.bindMemory(to: UInt8.self)
                var y = y0; while y < y1 { var x = x0; while x < x1 {
                    let i = (y * w + x) * 4
                    if abs(Int(A[i]) - Int(B[i])) + abs(Int(A[i+1]) - Int(B[i+1])) + abs(Int(A[i+2]) - Int(B[i+2])) > 24 { differ += 1 }
                    total += 1; x += 2 }; y += 2 }
            } }
            let frac = total > 0 ? Double(differ) / Double(total) : 0
            var single = "?"
            do {
                let wc = SCStreamConfiguration(); wc.width = max(2, Int(win.frame.width)); wc.height = max(2, Int(win.frame.height))
                let img = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: win), configuration: wc)
                let (p, _, _) = pixels(img); var lit = 0
                p.withUnsafeBytes { q in let Q = q.bindMemory(to: UInt8.self); var i = 0; while i < Q.count { if Q[i+3] > 0 && (Q[i] > 8 || Q[i+1] > 8 || Q[i+2] > 8) { lit += 1 }; i += 16 } }
                single = lit > (p.count / 16) / 50 ? "VISIBLE" : "BLANK"
            } catch { single = "REFUSED" }
            print("WINDOW \(win.windowID) \"\(win.title ?? "")\" frame=\(Int(win.frame.minX)),\(Int(win.frame.minY)),\(Int(win.frame.width))x\(Int(win.frame.height)) shared-screen=\(frac < 0.02 ? "HIDDEN" : "VISIBLE") diff=\(String(format: "%.3f", frac)) window-share=\(single)")
        }
    }
}

let sem = DispatchSemaphore(value: 0)
Task { do { try await run() } catch { print("ERROR \(error)") }; sem.signal() }
sem.wait()
