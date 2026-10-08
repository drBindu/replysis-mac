import Foundation
import CoreGraphics
let pid = Int32(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
var n = 0
for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let onscreen = (w[kCGWindowIsOnscreen as String] as? Bool) ?? false
    let alpha = (w[kCGWindowAlpha as String] as? Double) ?? -1
    print("window layer=\(w[kCGWindowLayer as String] ?? "?") alpha=\(alpha) onscreen=\(onscreen) x=\(b["X"] ?? "?") y=\(b["Y"] ?? "?") w=\(b["Width"] ?? "?") h=\(b["Height"] ?? "?")")
    n += 1
}
print("windows of pid \(pid): \(n)")
