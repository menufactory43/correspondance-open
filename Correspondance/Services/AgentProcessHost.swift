import Foundation
import OSLog

/// L'agent tourne **dans l'app** : un processus enfant, surveillé, qui meurt
/// avec elle.
///
/// Pourquoi pas un LaunchAgent — la question a été tranchée sur pièces après un
/// essai réel (l'enquête complète est dans `docs/AGENT.md`, § « Pourquoi cc ne
/// tourne pas en LaunchAgent ») : `SMAppService` n'achetait qu'une chose, cc
/// qui répond quand l'app est *quittée* et le Mac allumé. Pour un cc joignable
/// jour et nuit, la réponse a toujours été l'hôte distant. Ce bénéfice mince ne
/// valait ni l'approbation macOS, ni quatre états d'installation, ni un chemin
/// qu'on ne peut pas éprouver depuis Xcode.
///
/// Ce que ça donne : « Activer sur ce Mac » démarre, l'agent redémarre s'il
/// tombe, l'app le tue en partant, et son journal s'ouvre depuis les réglages.
@MainActor
final class AgentProcessHost {
  static let shared = AgentProcessHost()
  static let log = Logger(subsystem: "com.correspondance.app", category: "agent-process")

  /// Quand redémarrer, et quand renoncer. Pur : c'est ce que les tests
  /// exercent, sans lancer un seul processus.
  struct Backoff: Equatable, Sendable {
    /// Le premier redémarrage est immédiat — un agent qui tombe une fois au
    /// démarrage (le Relais pas encore prêt) doit repartir tout de suite.
    var premier: TimeInterval = 1
    /// Puis on double, jusqu'à ce plafond : un agent mal configuré ne doit pas
    /// tourner en boucle folle et remplir le disque de journaux.
    var plafond: TimeInterval = 60
    /// Au-delà, on s'arrête et on le dit. Réessayer cent fois ne répare rien.
    var essaisMax: Int = 8

    func delai(essai: Int) -> TimeInterval {
      guard essai > 0 else { return 0 }
      return min(plafond, premier * pow(2, Double(essai - 1)))
    }

    func renonce(apres essais: Int) -> Bool { essais >= essaisMax }
  }

  /// Ce qu'on lance. Injectable : les tests surveillent `/bin/sh`, pas l'agent.
  struct Launch: Sendable {
    var executable: URL
    var arguments: [String]
    var logURL: URL

    /// L'agent embarqué dans le bundle de l'app.
    static func embeddedAgent(named agent: String) -> Launch? {
      guard let executable = Self.embeddedAgentURL else { return nil }
      return Launch(
        executable: executable,
        arguments: ["run", "--agent", agent],
        logURL: URL(fileURLWithPath: "/tmp/correspondance-\(agent).log")
      )
    }

    /// Le binaire dans `Contents/MacOS`, **vérifié sur le disque**. C'est la
    /// seule façon honnête de dire « introuvable » : on regarde le fichier, on
    /// n'interroge pas macOS sur un service.
    static var embeddedAgentURL: URL? {
      let url = Bundle.main.bundleURL
        .appending(path: "Contents/MacOS/correspondance-agent")
      return FileManager.default.isExecutableFile(atPath: url.path()) ? url : nil
    }
  }

  private(set) var isRunning = false
  /// Combien de fois l'agent est retombé depuis le démarrage.
  private(set) var redemarrages = 0
  /// Pourquoi il ne tourne plus, quand on a renoncé.
  private(set) var abandon: String?

  var backoff = Backoff()
  private var process: Process?
  private var launch: Launch?
  private var arretVoulu = false
  private var relance: Task<Void, Never>?

  /// Le journal de l'agent, s'il en a un.
  var logURL: URL? { launch?.logURL }

  // MARK: - Démarrer, arrêter

  @discardableResult
  func start(_ launch: Launch) throws -> Bool {
    stop()
    self.launch = launch
    arretVoulu = false
    redemarrages = 0
    abandon = nil
    return try lancer(launch)
  }

  /// Arrêt propre. Appelé quand l'app se ferme : un agent orphelin qui
  /// continuerait de répondre au nom de quelqu'un serait pire qu'un agent mort.
  func stop() {
    arretVoulu = true
    relance?.cancel()
    relance = nil
    if let process, process.isRunning {
      process.terminate()
      Self.log.info("agent arrêté")
    }
    process = nil
    isRunning = false
  }

  private func lancer(_ launch: Launch) throws -> Bool {
    let process = Process()
    process.executableURL = launch.executable
    process.arguments = launch.arguments
    // Le PATH d'un enfant de l'app n'est pas celui d'un shell de connexion :
    // sans ça, ni `claude` ni l'adaptateur ACP ne seraient trouvables.
    var env = ProcessInfo.processInfo.environment
    let chemins = [
      "\(NSHomeDirectory())/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
      "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]
    env["PATH"] = chemins.joined(separator: ":")
    // Un `claude` lancé depuis un `claude` refuse de démarrer.
    for cle in env.keys where cle.hasPrefix("CLAUDECODE") || cle.hasPrefix("CLAUDE_CODE_") {
      env.removeValue(forKey: cle)
    }
    process.environment = env

    FileManager.default.createFile(atPath: launch.logURL.path(), contents: nil)
    if let handle = try? FileHandle(forWritingTo: launch.logURL) {
      handle.seekToEndOfFile()
      process.standardOutput = handle
      process.standardError = handle
    }

    process.terminationHandler = { [weak self] fini in
      Task { @MainActor in self?.termine(code: fini.terminationStatus) }
    }
    try process.run()
    self.process = process
    isRunning = true
    Self.log.info("agent démarré (pid \(process.processIdentifier))")
    return true
  }

  /// L'agent est tombé. On redémarre, avec un palier — pas une boucle folle.
  private func termine(code: Int32) {
    isRunning = false
    process = nil
    guard !arretVoulu else { return }
    guard let launch else { return }

    redemarrages += 1
    guard !backoff.renonce(apres: redemarrages) else {
      abandon = "cc s'est arrêté \(redemarrages) fois de suite (dernier code \(code)). "
        + "Son journal dira pourquoi."
      Self.log.error("abandon après \(self.redemarrages) redémarrages")
      return
    }
    let delai = backoff.delai(essai: redemarrages)
    Self.log.info("agent tombé (code \(code)) — redémarrage dans \(delai) s")
    relance = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(delai))
      guard let self, !self.arretVoulu else { return }
      _ = try? self.lancer(launch)
    }
  }
}
