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

  /// Un événement qui se répète (chaque bascule de fil), avec une valeur.
  @MainActor
  static func event(_ name: StaticString, _ value: Int = 0) {
    let ms = Int((Date().timeIntervalSince1970 - processStart) * 1000)
    os_log("EVENT %{public}@ ms=%d n=%d", log: log, "\(name)", ms, value)
  }

  @MainActor
  static func mark(_ name: StaticString) {
    let key = "\(name)"
    guard marked.insert(key).inserted else { return }
    let ms = Int((Date().timeIntervalSince1970 - processStart) * 1000)
    os_log("LAUNCH %{public}@ ms=%d", log: log, key, ms)
  }
}


extension Duration {
  /// Millisecondes entières — pour les jalons du lancement et du banc.
  var ms: Double {
    Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
  }
}

/// Banc de bascule de fil, en Release, piloté par `CORR_BENCH=switch[:N]`.
///
/// Une fois le premier fil peint, on ouvre tour à tour les N premières
/// conversations de la file et on chronomètre chacune : de l'appel à `select`
/// jusqu'à la passe qui montre le fil (`LaunchTrace.event("shown")`). Le
/// résultat part dans le journal (`BENCH switch …`), lu par `tools/launch`.
/// Sans la variable, rien de tout cela n'existe.
@MainActor
enum LaunchBench {
  private static let log = OSLog(subsystem: "app.correspondance.launch", category: "bench")

  static var switchCount: Int? = {
    guard let raw = ProcessInfo.processInfo.environment["CORR_BENCH"], raw.hasPrefix("switch") else {
      return nil
    }
    let parts = raw.split(separator: ":")
    return parts.count > 1 ? Int(parts[1]) ?? 12 : 12
  }()

  private static var shownAt: ContinuousClock.Instant?

  /// Appelé par le fil quand il se montre après une bascule. Un fil encore
  /// vide (la session vient de naître, le chargement suit) ne compte pas :
  /// c'est le premier fil garni qu'on attend.
  static func noteShown(count: Int) {
    guard count > 0 else { return }
    shownAt = .now
  }

  /// Ouvre chaque fil et attend qu'il soit montré ; renvoie les latences en ms.
  static func run(select: @escaping (String) async -> Void, ids: [String]) async -> [Double] {
    var samples: [Double] = []
    for id in ids {
      try? await Task.sleep(for: .milliseconds(350))
      shownAt = nil
      let began = ContinuousClock.now
      await select(id)
      let deadline = began + .seconds(3)
      while shownAt == nil, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(2))
      }
      let end = shownAt ?? .now
      let ms = (end - began).ms
      samples.append(ms)
      os_log("BENCH switch id=%{public}@ ms=%d", log: log, id, Int(ms))
    }
    let sorted = samples.sorted()
    if !sorted.isEmpty {
      let median = sorted[sorted.count / 2]
      let p90 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))]
      os_log("BENCH switch-summary n=%d median=%d p90=%d", log: log, sorted.count, Int(median), Int(p90))
    }
    return samples
  }
}
