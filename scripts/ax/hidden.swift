import AppKit
let bid = "com.apple.MobileSMS"
func app() -> NSRunningApplication? { NSRunningApplication.runningApplications(withBundleIdentifier: bid).first }
let frontBefore = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
print("avant : front=\(frontBefore) hidden=\(app()?.isHidden ?? false)")
// 1) lancement/deep link sans activation
let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = false; cfg.hides = true; cfg.addsToRecentItems = false
let sem = DispatchSemaphore(value: 0)
NSWorkspace.shared.open([URL(string: "imessage://moi@exemple.fr")!],
  withApplicationAt: URL(fileURLWithPath: "/System/Applications/Messages.app"),
  configuration: cfg) { _, e in print("open err=\(String(describing: e))"); sem.signal() }
_ = sem.wait(timeout: .now() + 10)
usleep(1_500_000)
print("après lien : front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?") hidden=\(app()?.isHidden ?? false) active=\(app()?.isActive ?? false)")
// 2) hide() explicite (ce que fait hideIfNeeded)
let ok = app()?.hide() ?? false
usleep(900_000)
print("après hide()=\(ok) : front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?") hidden=\(app()?.isHidden ?? false)")
print("front inchangé : \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier == frontBefore)")
