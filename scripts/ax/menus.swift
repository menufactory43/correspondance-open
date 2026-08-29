import AppKit
import ApplicationServices
let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MobileSMS").first!
let axApp = AXUIElementCreateApplication(app.processIdentifier)
func attr(_ el: AXUIElement, _ n: String) -> CFTypeRef? { var v: CFTypeRef?; guard AXUIElementCopyAttributeValue(el, n as CFString, &v) == .success else { return nil }; return v }
func s(_ el: AXUIElement, _ n: String) -> String { (attr(el, n) as? String) ?? "" }
func kids(_ el: AXUIElement) -> [AXUIElement] { (attr(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? [] }
func acts(_ el: AXUIElement) -> [String] { var n: CFArray?; AXUIElementCopyActionNames(el, &n); return (n as? [String]) ?? [] }
func walk(_ el: AXUIElement, _ d: Int) {
  let r = s(el, kAXRoleAttribute as String)
  let t = s(el, kAXTitleAttribute as String)
  let cmd = s(el, "AXMenuItemCmdChar"); let mods = s(el, "AXMenuItemCmdModifiers")
  let en = (attr(el, kAXEnabledAttribute as String) as? NSNumber)?.boolValue ?? true
  print(String(repeating: "  ", count: d) + "\(r) « \(t) » \(cmd.isEmpty ? "" : "[⌘\(cmd) mods=\(mods)]") enabled=\(en)")
  if d < 3 { for c in kids(el) { walk(c, d+1) } }
}
guard let mb = attr(axApp, kAXMenuBarAttribute as String) else { print("pas de menubar"); exit(1) }
for item in kids(mb as! AXUIElement) {
  let id = s(item, "AXIdentifier")
  if ["com.apple.menu.window", "com.messages.conversationsmenu", "com.apple.menu.file", "com.apple.menu.edit"].contains(id) {
    print("### \(id)")
    walk(item, 0)
  }
}
