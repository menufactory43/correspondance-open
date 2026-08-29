import AppKit
import ApplicationServices

// Sonde AX de Messages.app : dumpe l'arbre (rôle, identifiant, titre, valeur, description, actions).
// Usage : swift axprobe.swift [profondeur] [--hide] [--focus <identifiantRôle>]

let trusted = AXIsProcessTrusted()
FileHandle.standardError.write("AXIsProcessTrusted = \(trusted)\n".data(using: .utf8)!)

let args = CommandLine.arguments
let maxDepth = Int(args.dropFirst().first(where: { Int($0) != nil }) ?? "") ?? 8
let wantHide = args.contains("--hide")
let wantUnhide = args.contains("--unhide")

guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MobileSMS").first else {
    print("Messages.app pas lancée"); exit(1)
}
if wantHide { _ = app.hide(); usleep(700_000) }
if wantUnhide { _ = app.unhide(); usleep(400_000) }
print("pid=\(app.processIdentifier) isHidden=\(app.isHidden) isActive=\(app.isActive) frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")")

let axApp = AXUIElementCreateApplication(app.processIdentifier)

func copyAttr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success else { return nil }
    return value
}
func str(_ el: AXUIElement, _ name: String) -> String? {
    guard let v = copyAttr(el, name) else { return nil }
    if let s = v as? String { return s.isEmpty ? nil : s }
    if let n = v as? NSNumber { return n.stringValue }
    return nil
}
func children(_ el: AXUIElement) -> [AXUIElement] {
    (copyAttr(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}
func actions(_ el: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(el, &names) == .success else { return [] }
    return (names as? [String]) ?? []
}
func attrNames(_ el: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyAttributeNames(el, &names) == .success else { return [] }
    return (names as? [String]) ?? []
}
func frame(_ el: AXUIElement) -> String {
    guard let v = copyAttr(el, kAXPositionAttribute as String),
          let s = copyAttr(el, kAXSizeAttribute as String) else { return "" }
    var p = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(v as! AXValue, .cgPoint, &p)
    AXValueGetValue(s as! AXValue, .cgSize, &sz)
    return String(format: " @(%.0f,%.0f %.0fx%.0f)", p.x, p.y, sz.width, sz.height)
}

func dump(_ el: AXUIElement, depth: Int, path: String) {
    let role = str(el, kAXRoleAttribute as String) ?? "?"
    let sub = str(el, kAXSubroleAttribute as String)
    var parts: [String] = [role]
    if let sub { parts.append("(\(sub))") }
    if let i = str(el, "AXIdentifier") { parts.append("id=\(i)") }
    if let t = str(el, kAXTitleAttribute as String) { parts.append("title=\(t.prefix(70).debugDescription)") }
    if let d = str(el, kAXDescriptionAttribute as String) { parts.append("desc=\(d.prefix(90).debugDescription)") }
    if let v = str(el, kAXValueAttribute as String) { parts.append("value=\(v.prefix(90).debugDescription)") }
    if let h = str(el, kAXHelpAttribute as String) { parts.append("help=\(h.prefix(50).debugDescription)") }
    let acts = actions(el)
    if !acts.isEmpty { parts.append("actions=\(acts.joined(separator: ","))") }
    parts.append(frame(el))
    print(String(repeating: "  ", count: depth) + "[\(path)] " + parts.joined(separator: " "))
    if depth >= maxDepth { 
        let n = children(el).count
        if n > 0 { print(String(repeating: "  ", count: depth + 1) + "… \(n) enfants (profondeur max)") }
        return
    }
    for (i, c) in children(el).enumerated() {
        dump(c, depth: depth + 1, path: path.isEmpty ? "\(i)" : "\(path).\(i)")
    }
}

print("=== attributs de l'application ===")
print(attrNames(axApp).joined(separator: ", "))
if let wins = copyAttr(axApp, kAXWindowsAttribute as String) as? [AXUIElement] {
    print("fenêtres: \(wins.count)")
    for (i, w) in wins.enumerated() {
        print("=== fenêtre \(i) ===")
        dump(w, depth: 0, path: "w\(i)")
    }
} else {
    print("AXWindows illisible")
}
