import Foundation
import ApplicationServices
// Asks the accessibility system what is in the sign-in window of a running app, without touching the mouse: how many sheets are open,
// is there a "Continue with Google" button, and where is the middle of the Close button.
let pid = Int32(CommandLine.arguments[1])!
let app = AXUIElementCreateApplication(pid)

func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
    var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
}
func text(_ e: AXUIElement, _ a: String) -> String { (attr(e, a) as? String) ?? "" }
func children(_ e: AXUIElement) -> [AXUIElement] { (attr(e, "AXChildren") as? [AXUIElement]) ?? [] }
func point(_ e: AXUIElement) -> CGPoint? { var p = CGPoint.zero; guard let v = attr(e, "AXPosition"), AXValueGetValue(v as! AXValue, .cgPoint, &p) else { return nil }; return p }
func size(_ e: AXUIElement) -> CGSize? { var s = CGSize.zero; guard let v = attr(e, "AXSize"), AXValueGetValue(v as! AXValue, .cgSize, &s) else { return nil }; return s }

var buttons: [AXUIElement] = []     // every button of the app
var sheetButtons: [AXUIElement] = []  // the ones inside the sheet (the main window has a Close of its own)
var sheets = 0
func walk(_ e: AXUIElement, _ depth: Int, inSheet: Bool) {
    if depth > 14 { return }
    let role = text(e, "AXRole")
    if role == "AXSheet" { sheets += 1 }
    if role == "AXButton" { buttons.append(e); if inSheet { sheetButtons.append(e) } }
    for c in children(e) { walk(c, depth + 1, inSheet: inSheet || role == "AXSheet") }
}
walk(app, 0, inSheet: false)
if CommandLine.arguments.count > 2 { for b in buttons { print("BUTTON \(label(b)) at \(point(b).map { "\(Int($0.x)),\(Int($0.y))" } ?? "?") size \(size(b).map { "\(Int($0.width))x\(Int($0.height))" } ?? "?")") } }

func label(_ e: AXUIElement) -> String { [text(e, "AXDescription"), text(e, "AXTitle")].joined(separator: " ") }
let google = sheetButtons.filter { label($0).contains("Google") }
print("SHEETS \(sheets)")
print("GOOGLE_BUTTONS \(google.count)")
guard let close = sheetButtons.first(where: { text($0, "AXDescription") == "Close" }), let p = point(close), let s = size(close) else {
    print("CLOSE_BUTTON missing"); exit(0)
}
print("CLOSE_AT \(Int(p.x + s.width / 2)) \(Int(p.y + s.height / 2))")
