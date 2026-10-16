import Foundation
import ApplicationServices
// presses the first button of an app whose label (description + title) starts with the given text, through accessibility
let pid = Int32(CommandLine.arguments[1])!, want = CommandLine.arguments[2]
let app = AXUIElementCreateApplication(pid)
func text(_ e: AXUIElement, _ a: String) -> String { var v: CFTypeRef?; AXUIElementCopyAttributeValue(e, a as CFString, &v); return (v as? String) ?? "" }
func kids(_ e: AXUIElement) -> [AXUIElement] { var v: CFTypeRef?; AXUIElementCopyAttributeValue(e, "AXChildren" as CFString, &v); return (v as? [AXUIElement]) ?? [] }
func find(_ e: AXUIElement, _ d: Int) -> AXUIElement? {
    if d > 16 { return nil }
    if text(e, "AXRole") == "AXButton", (text(e, "AXDescription") + " " + text(e, "AXTitle")).hasPrefix(want) { return e }
    for c in kids(e) { if let f = find(c, d + 1) { return f } }
    return nil
}
if let b = find(app, 0) { print("press: \(AXUIElementPerformAction(b, kAXPressAction as CFString) == .success ? "ok" : "failed")") } else { print("no such button: \(want)") }
