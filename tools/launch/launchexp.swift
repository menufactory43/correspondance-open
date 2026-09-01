import AppKit
import CoreGraphics
import Darwin
import Foundation

// launchexp <app path> <runs per variant> <variant>[,<variant>…]
//
// Lance l'app via LaunchServices (comme le Dock), une variante après l'autre,
// en blocs alternés (A B C, A B C, …) pour que le bruit de la machine se
// répartisse. Pour chaque lancement :
//   - window_cg : process start → fenêtre à l'écran (CGWindowList, comme launchtimer) ;
//   - window / thread-begin / thread : les jalons `LaunchTrace` lus dans le
//     journal système (ms depuis la création du process).
// La variante « base » lance sans CORR_EXP. Sortie : une ligne par run, puis
// les médianes par variante.

let args = CommandLine.arguments
guard args.count >= 4, let runs = Int(args[2]) else {
  FileHandle.standardError.write("usage: launchexp <app> <runs> <variant,variant,…>\n".data(using: .utf8)!)
  exit(2)
}
let appURL = URL(fileURLWithPath: args[1])
let variants = args[3].split(separator: ",").map(String.init)
let ownerName = "Correspondance"
let subsystem = "app.correspondance.launch"

func processStart(pid: pid_t) -> Double? {
  var info = kinfo_proc()
  var size = MemoryLayout<kinfo_proc>.stride
  var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
  guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
  let tv = info.kp_proc.p_starttime
  return Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000
}

func visibleWindowPID() -> pid_t? {
  guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]] else { return nil }
  for w in list {
    guard (w[kCGWindowOwnerName as String] as? String) == ownerName,
          (w[kCGWindowLayer as String] as? Int) == 0,
          let b = w[kCGWindowBounds as String] as? [String: Any],
          let h = b["Height"] as? Double, h > 200,
          let pid = w[kCGWindowOwnerPID as String] as? pid_t
    else { continue }
    return pid
  }
  return nil
}

func kill() {
  let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
  p.arguments = ["-x", ownerName]; try? p.run(); p.waitUntilExit()
}

/// Les jalons LAUNCH du process `pid`, lus dans le journal.
func marks(pid: pid_t, since: Date) -> [String: Int] {
  let f = DateFormatter()
  f.dateFormat = "yyyy-MM-dd HH:mm:ss"
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
  p.arguments = [
    "show", "--start", f.string(from: since.addingTimeInterval(-2)), "--style", "compact",
    "--predicate", "subsystem == \"\(subsystem)\" AND processIdentifier == \(pid)",
  ]
  let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
  try? p.run()
  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  p.waitUntilExit()
  var out: [String: Int] = [:]
  for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
    guard let r = line.range(of: "LAUNCH ") else { continue }
    let rest = line[r.upperBound...].split(separator: " ")
    guard rest.count >= 2, rest[1].hasPrefix("ms="), let ms = Int(rest[1].dropFirst(3)) else { continue }
    out[String(rest[0])] = ms
  }
  return out
}

struct Sample { var windowCG: Double; var window: Int?; var threadBegin: Int?; var thread: Int?; var main: Int?; var didFinish: Int? }
var samples: [String: [Sample]] = [:]

for run in 1...runs {
  for variant in variants {
    kill(); Thread.sleep(forTimeInterval: 1.5)
    let cfg = NSWorkspace.OpenConfiguration()
    cfg.activates = true
    // « a+b » : plusieurs drapeaux dans une même variante.
    // « nom@/chemin/vers/Autre.app » : la variante lance une AUTRE build — c'est
    // ainsi qu'on compare un avant et un après dans les mêmes blocs alternés.
    var name = variant
    var url = appURL
    if let at = variant.firstIndex(of: "@") {
      name = String(variant[..<at])
      url = URL(fileURLWithPath: String(variant[variant.index(after: at)...]))
    }
    if name != "base" { cfg.environment = ["CORR_EXP": name.replacingOccurrences(of: "+", with: ",")] }
    let since = Date()
    let sem = DispatchSemaphore(value: 0)
    NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in sem.signal() }
    let deadline = Date().addingTimeInterval(15)
    var got: Double? = nil
    var pid: pid_t = 0
    while Date() < deadline {
      if let p = visibleWindowPID(), let start = processStart(pid: p) {
        got = (Date().timeIntervalSince1970 - start) * 1000
        pid = p
        break
      }
      usleep(2000)
    }
    sem.wait()
    // Laisser le fil arriver et le journal se poser.
    Thread.sleep(forTimeInterval: 3.0)
    kill()
    Thread.sleep(forTimeInterval: 0.5)
    guard let got else { print("\(variant) run \(run): timeout"); continue }
    let m = marks(pid: pid, since: since)
    let s = Sample(windowCG: got, window: m["window"], threadBegin: m["thread-begin"], thread: m["thread"], main: m["main"], didFinish: m["didFinish"])
    samples[variant, default: []].append(s)
    func fmt(_ v: Int?) -> String { v.map(String.init) ?? "-" }
    print("\(variant) run \(run): main=\(fmt(m["main"])) didFinish=\(fmt(m["didFinish"])) frame1=\(fmt(m["frame1"])) window_cg=\(Int(got)) window=\(fmt(s.window)) thread=\(fmt(s.thread)) full=\(fmt(m["thread-full"]))")
    fflush(stdout)
  }
}
kill()

func median(_ xs: [Double]) -> Double? {
  guard !xs.isEmpty else { return nil }
  let s = xs.sorted(); return s[s.count / 2]
}
func show(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "-" }
func pad(_ s: String, _ n: Int, left: Bool = false) -> String {
  let fill = String(repeating: " ", count: max(0, n - s.count))
  return left ? s + fill : fill + s
}
print("\n=== médianes (ms depuis la création du process) ===")
print([pad("variante", 20, left: true), pad("main", 8), pad("didFin", 8), pad("win_cg", 8), pad("window", 8), pad("thread", 8), pad("fil", 8), "  n"].joined())
for variant in variants {
  let xs = samples[variant] ?? []
  // « fil » : de la fenêtre à l'écran (CG) au fil montré.
  let fil = xs.compactMap { s -> Double? in
    guard let t = s.thread else { return nil }
    return Double(t) - s.windowCG
  }
  print([
    pad(variant, 20, left: true),
    pad(show(median(xs.compactMap { $0.main.map(Double.init) })), 8),
    pad(show(median(xs.compactMap { $0.didFinish.map(Double.init) })), 8),
    pad(show(median(xs.map(\.windowCG))), 8),
    pad(show(median(xs.compactMap { $0.window.map(Double.init) })), 8),
    pad(show(median(xs.compactMap { $0.thread.map(Double.init) })), 8),
    pad(show(median(fil)), 8),
    "  \(xs.count)",
  ].joined())
}
