import AppKit
import Foundation

/// Pont vers **Dictus** (getdictus.com, MIT) : dictée 100 % locale (Parakeet / Whisper).
/// Correspondance n'embarque pas son code — elle pilote l'app installée par sa CLI,
/// et Dictus colle le texte dans le champ qui a le focus.
///
/// Absent ou désactivé, la dictée retombe sur Speech (Apple), comme avant.
enum DictusBridge {
  static let bundleID = "com.dictus.desktop"
  static let websiteURL = URL(string: "https://www.getdictus.com")!
  static let defaultsKey = "dictation.useDictus"

  /// Réglage utilisateur : passer par Dictus quand il est installé (défaut : oui).
  static var isPreferred: Bool {
    get { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
    set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
  }

  static var appURL: URL? {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
  }

  static var isInstalled: Bool { appURL != nil }

  static var isRunning: Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
  }

  /// Dictus prend la main si on le veut *et* qu'il est là.
  static var isActive: Bool { isPreferred && isInstalled }

  /// Le raccourci « Transcribe » configuré dans Dictus, lisible dans ses réglages.
  /// Sert à l'afficher, jamais à le simuler.
  static var transcribeShortcutFR: String? {
    let url = FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent(bundleID)
      .appendingPathComponent("settings_store.json")
    guard
      let data = try? Data(contentsOf: url),
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let settings = root["settings"] as? [String: Any],
      let bindings = settings["bindings"] as? [String: Any],
      let transcribe = bindings["transcribe"] as? [String: Any],
      let binding = transcribe["current_binding"] as? String
    else { return nil }
    return binding
      .split(separator: "+")
      .map { key -> String in
        switch key.replacingOccurrences(of: "_left", with: "").replacingOccurrences(of: "_right", with: "") {
        case "option", "alt": "⌥"
        case "command", "meta", "super": "⌘"
        case "shift": "⇧"
        case "control", "ctrl": "⌃"
        case "space": "Espace"
        default: key.capitalized
        }
      }
      .joined(separator: " ")
  }

  enum Command: String {
    case toggleTranscription = "--toggle-transcription"
    case cancel = "--cancel"
  }

  /// Démarre/arrête l'enregistrement. Lance Dictus caché s'il ne tourne pas encore
  /// (premier chargement du modèle : quelques secondes).
  static func toggleTranscription() async throws {
    try await ensureRunning()
    try send(.toggleTranscription)
  }

  static func cancel() {
    guard isRunning else { return }
    try? send(.cancel)
  }

  static func openWebsite() {
    NSWorkspace.shared.open(websiteURL)
  }

  // MARK: - Interne

  private static func ensureRunning() async throws {
    guard !isRunning else { return }
    guard let appURL else { throw DictusBridgeError.notInstalled }
    let config = NSWorkspace.OpenConfiguration()
    config.activates = false
    config.hides = true
    config.arguments = ["--start-hidden"]
    _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
    // Laisse l'instance s'installer avant de lui relayer une commande.
    for _ in 0..<20 where !isRunning {
      try await Task.sleep(for: .milliseconds(150))
    }
    try await Task.sleep(for: .milliseconds(400))
  }

  /// Le binaire relaie le flag à l'instance qui tourne et se termine aussitôt.
  private static func send(_ command: Command) throws {
    guard let appURL else { throw DictusBridgeError.notInstalled }
    let binary = appURL
      .appendingPathComponent("Contents/MacOS/dictus")
    let process = Process()
    process.executableURL = binary
    process.arguments = [command.rawValue]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
  }
}

enum DictusBridgeError: LocalizedError {
  case notInstalled

  var errorDescription: String? {
    switch self {
    case .notInstalled: "Dictus n’est pas installé."
    }
  }
}
