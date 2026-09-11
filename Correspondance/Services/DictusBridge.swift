import AppKit
import Foundation
import os

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
    guard
      let data = try? Data(contentsOf: settingsURL),
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
    case cancel = "--cancel"
  }

  private static let journal = Logger(subsystem: "app.correspondance", category: "dictation")

  /// Démarre/arrête l'enregistrement. Lance Dictus caché s'il ne tourne pas encore
  /// (premier chargement du modèle : quelques secondes).
  ///
  /// Par signal, pas par sa CLI : depuis Dictus 0.3.0, relancer son binaire pour lui
  /// relayer un flag vaut « réouverture » de l'app, et Dictus montre sa fenêtre au
  /// premier plan — le texte dicté était alors tapé dedans, pas dans le composer.
  /// Dictus écoute SIGUSR2 pour « transcribe » (son `signal_handle`) : même action,
  /// sans fenêtre.
  static func toggleTranscription() async throws {
    try await ensureRunning()
    try signalToggle()
  }

  /// Démarre l'enregistrement, et s'assure que Dictus a bien réagi.
  ///
  /// Le relais CLI répond « ok » quoi qu'il arrive : il pose les arguments sur le socket
  /// de l'instance et se termine. Que l'instance les ait traités, seul son journal le dit.
  /// Vu le 11 sept. : une instance dont le coordinateur de transcription avait paniqué
  /// au démarrage ignorait tout (« channel closed »), et une instance de la veille
  /// (0.2.0, avant la mise à jour automatique en 0.3.0) ne répondait plus au relais neuf.
  /// Si le journal ne montre pas d'enregistrement lancé, on relance Dictus et on renvoie.
  static func startTranscription() async throws {
    try await ensureRunning()
    guard let mark = journalMark() else {
      try signalToggle()
      return
    }
    try signalToggle()
    if await journalShows("Recording started", since: mark, within: .seconds(3)) { return }
    journal.warning("Dictus n'a pas lancé l'enregistrement demandé : relance de l'instance.")
    await terminate()
    try await ensureRunning()
    try signalToggle()
  }

  /// Abandonne l'enregistrement en cours. Passe par la CLI (pas de signal pour ça),
  /// donc Dictus montre sa fenêtre : on la recache aussitôt.
  static func cancel() {
    let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    guard !apps.isEmpty else { return }
    try? send(.cancel)
    Task {
      try? await Task.sleep(for: .milliseconds(600))
      apps.forEach { $0.hide() }
    }
  }

  static func openWebsite() {
    NSWorkspace.shared.open(websiteURL)
  }

  // MARK: - Interne

  private static var settingsURL: URL {
    FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent(bundleID)
      .appendingPathComponent("settings_store.json")
  }

  private static var journalURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs")
      .appendingPathComponent(bundleID)
      .appendingPathComponent("dictus.log")
  }

  /// Le journal de Dictus dit ce qu'il fait tant que son niveau est info ou plus bas
  /// (debug par défaut). Au-dessus, il se tait, et on ne vérifie rien.
  private static var journalIsReadable: Bool {
    guard
      let data = try? Data(contentsOf: settingsURL),
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let settings = root["settings"] as? [String: Any]
    else { return true }
    guard let level = settings["log_level"] as? String else { return true }
    return ["trace", "debug", "info"].contains(level.lowercased())
  }

  /// Position courante dans le journal de Dictus ; nil s'il n'y a rien à lire.
  private static func journalMark() -> UInt64? {
    guard journalIsReadable else { return nil }
    return (try? FileManager.default.attributesOfItem(atPath: journalURL.path))?[.size] as? UInt64
  }

  private static func journalAppended(since mark: UInt64) -> String {
    guard let handle = try? FileHandle(forReadingFrom: journalURL) else { return "" }
    defer { try? handle.close() }
    guard (try? handle.seek(toOffset: mark)) != nil, let data = try? handle.readToEnd() else { return "" }
    return String(decoding: data, as: UTF8.self)
  }

  /// Attend que Dictus écrive `needle` dans son journal, au plus `limit`.
  private static func journalShows(_ needle: String, since mark: UInt64, within limit: Duration) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
      if journalAppended(since: mark).contains(needle) { return true }
      try? await Task.sleep(for: .milliseconds(150))
    }
    return journalAppended(since: mark).contains(needle)
  }

  /// Termine l'instance qui tourne, de force si elle ne répond pas.
  private static func terminate() async {
    let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    guard !apps.isEmpty else { return }
    apps.forEach { $0.terminate() }
    for _ in 0..<20 where isRunning {
      try? await Task.sleep(for: .milliseconds(100))
    }
    if isRunning {
      apps.forEach { $0.forceTerminate() }
      for _ in 0..<20 where isRunning {
        try? await Task.sleep(for: .milliseconds(100))
      }
    }
  }

  /// Lance Dictus caché s'il ne tourne pas, et attend qu'il soit prêt à recevoir.
  ///
  /// Une commande relayée avant la fin de son démarrage est perdue (mesuré : 0,4 s
  /// après l'apparition du processus, Dictus 0.3.0 la prend pour une demande d'ouvrir
  /// sa fenêtre — « Main window not found » — et n'enregistre rien ; à 6 s, tout va).
  /// Son journal dit quand il est prêt : « Shortcuts initialized successfully ».
  private static func ensureRunning() async throws {
    guard !isRunning else { return }
    guard let appURL else { throw DictusBridgeError.notInstalled }
    let mark = journalMark()
    let config = NSWorkspace.OpenConfiguration()
    config.activates = false
    config.hides = true
    config.arguments = ["--start-hidden"]
    _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
    for _ in 0..<20 where !isRunning {
      try await Task.sleep(for: .milliseconds(150))
    }
    if let mark, await journalShows("Shortcuts initialized successfully", since: mark, within: .seconds(15)) {
      // Les raccourcis viennent après la fenêtre et le coordinateur : tout est en place.
      try await Task.sleep(for: .milliseconds(300))
    } else {
      // Sans journal, on laisse le temps qu'il faut d'ordinaire (2 s), avec de la marge :
      // un signal arrivé avant ses gestionnaires tuerait Dictus.
      try await Task.sleep(for: .seconds(8))
    }
  }

  /// SIGUSR2 = « transcribe » pour Dictus. Le signal doit trouver ses gestionnaires
  /// en place (sinon il tue le processus) : `ensureRunning` attend qu'ils le soient.
  private static func signalToggle() throws {
    let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    guard let pid = apps.first?.processIdentifier else { throw DictusBridgeError.notRunning }
    guard kill(pid, SIGUSR2) == 0 else { throw DictusBridgeError.notRunning }
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
  case notRunning

  var errorDescription: String? {
    switch self {
    case .notInstalled: "Dictus n’est pas installé."
    case .notRunning: "Dictus ne tourne pas."
    }
  }
}
