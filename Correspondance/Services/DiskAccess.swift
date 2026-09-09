import AppKit
import Foundation

/// L'accès complet au disque, et tout ce que macOS ne dit pas à son sujet.
///
/// Trois pièges, vus en vrai : la case cochée ne vaut qu'au PROCHAIN lancement
/// (l'app qui tournait reste refusée) ; lancée depuis Xcode, c'est à Xcode que
/// TCC demande l'accès, pas à l'app ; et quand plusieurs copies du même bundle
/// traînent (DerivedData, build/, /Applications), Réglages Système peut valider
/// la mauvaise, et la case retombe. D'où : la bannière dit quel cas on est, et
/// le bouton « Quitter et rouvrir » fait le geste que macOS impose.
enum DiskAccess {
  static var databaseURL: URL { IMessageDatabase.defaultDatabaseURL }

  /// `chat.db` se lit-elle ? C'est le seul juge : TCC ne s'interroge pas.
  static var isGranted: Bool {
    FileManager.default.isReadableFile(atPath: databaseURL.path)
  }

  /// Un débogueur est attaché : lancée depuis Xcode, l'accès disque est celui
  /// d'Xcode (le « processus responsable »), pas celui de l'app.
  static var isRunFromXcode: Bool {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    let status = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
    guard status == 0 else { return false }
    return (info.kp_proc.p_flag & P_TRACED) != 0
  }

  /// Le bundle qui tourne, celui qu'il faut coche dans les Réglages.
  static var bundleURL: URL { Bundle.main.bundleURL }

  static var isInstalledInApplications: Bool {
    bundleURL.path.hasPrefix("/Applications/")
  }

  static func openSettings() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
    NSWorkspace.shared.open(url)
  }

  static func revealInFinder() {
    NSWorkspace.shared.activateFileViewerSelecting([bundleURL])
  }

  /// Quitter et rouvrir : ce que macOS exige pour appliquer la case. On rouvre
  /// LA copie qui tourne, quelle que soit sa place.
  static func relaunch() {
    let path = bundleURL.path
    let script = "sleep 0.6; /usr/bin/open -n \"\(path)\""
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", script]
    try? process.run()
    NSApplication.shared.terminate(nil)
  }
}
