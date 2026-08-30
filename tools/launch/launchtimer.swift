import AppKit
import CoreGraphics
import Darwin
import Foundation

// launchtimer <app path> <runs>
// Lance l'app via LaunchServices (comme le Dock), guette l'apparition de sa
// fenêtre à l'écran, et mesure l'écart depuis l'heure de création du process.

let args = CommandLine.arguments
guard args.count >= 3, let runs = Int(args[2]) else {
  FileHandle.standardError.write("usage: launchtimer <app> <runs>\n".data(using: .utf8)!)
  exit(2)
}
let appURL = URL(fileURLWithPath: args[1])
let ownerName = "Correspondance"

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

var results: [Double] = []
for i in 1...runs {
  kill(); Thread.sleep(forTimeInterval: 1.5)
  let cfg = NSWorkspace.OpenConfiguration()
  cfg.activates = true
  if args.count >= 4, let eq = args[3].firstIndex(of: "=") {
    cfg.environment = [String(args[3][..<eq]): String(args[3][args[3].index(after: eq)...])]
  }
  let sem = DispatchSemaphore(value: 0)
  NSWorkspace.shared.openApplication(at: appURL, configuration: cfg) { _, _ in sem.signal() }
  let deadline = Date().addingTimeInterval(15)
  var got: Double? = nil
  while Date() < deadline {
    if let pid = visibleWindowPID(), let start = processStart(pid: pid) {
      let now = Date().timeIntervalSince1970
      got = (now - start) * 1000
      break
    }
    usleep(2000)
  }
  sem.wait()
  if let got {
    results.append(got)
    print(String(format: "run %d: %.0f ms", i, got)); fflush(stdout)
  } else {
    print("run \(i): timeout"); fflush(stdout)
  }
  Thread.sleep(forTimeInterval: 1.0)
}
kill()
let sorted = results.sorted()
if !sorted.isEmpty {
  let median = sorted[sorted.count / 2]
  let mean = sorted.reduce(0, +) / Double(sorted.count)
  print(String(format: "median %.0f ms  mean %.0f ms  min %.0f ms  max %.0f ms  (n=%d)", median, mean, sorted.first!, sorted.last!, sorted.count))
}
