import Darwin
import Foundation
import os

/// Variantes de lancement, lues dans `CORR_EXP` (liste séparée par des virgules).
///
/// La machine de mesure est bruyante : la seule façon honnête de juger une
/// optimisation du lancement est de lancer la MÊME build avec et sans, en
/// blocs alternés, et de comparer les médianes. Les drapeaux vivent ici le
/// temps de trancher, puis le code gagnant devient le code tout court.
/// Cf. `tools/launch/README.md`.
enum LaunchExperiment {
  private static let flags: Set<String> = {
    let raw = ProcessInfo.processInfo.environment["CORR_EXP"] ?? ""
    return Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
  }()

  static func isOn(_ name: String) -> Bool { flags.contains(name) }
}

/// Jalons du lancement, en millisecondes depuis la création du process, dans le
/// journal système (`subsystem == "app.correspondance.launch"`). Chaîne publique :
/// une `NSLog` sort en `<private>` et ne se lit pas depuis `log show`.
enum LaunchTrace {
  private static let log = OSLog(subsystem: "app.correspondance.launch", category: "trace")

  /// L'heure de naissance du process, la même que celle que lit `launchtimer`.
  private static let processStart: Double = {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date().timeIntervalSince1970 }
    let tv = info.kp_proc.p_starttime
    return Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000
  }()

  /// Un jalon ne s'écrit qu'une fois : la première conversation ouverte, pas
  /// chaque bascule de fil.
  @MainActor private static var marked: Set<String> = []

  @MainActor
  static func mark(_ name: StaticString) {
    let key = "\(name)"
    guard marked.insert(key).inserted else { return }
    let ms = Int((Date().timeIntervalSince1970 - processStart) * 1000)
    os_log("LAUNCH %{public}@ ms=%d", log: log, key, ms)
  }
}

