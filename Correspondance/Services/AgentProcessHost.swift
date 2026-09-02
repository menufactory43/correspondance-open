import CorrespondanceAgentKit
import CorrespondanceCore
import Foundation
import OSLog

/// Les agents tournent **dans l'app** : un processus enfant par agent,
/// surveillé, qui meurt avec elle.
///
/// Pourquoi pas un LaunchAgent — la question a été tranchée sur pièces après un
/// essai réel (l'enquête complète est dans `docs/AGENT.md`, § « Pourquoi cc ne
/// tourne pas en LaunchAgent ») : `SMAppService` n'achetait qu'une chose, cc
/// qui répond quand l'app est *quittée* et le Mac allumé. Pour un cc joignable
/// jour et nuit, la réponse a toujours été l'hôte distant. Ce bénéfice mince ne
/// valait ni l'approbation macOS, ni quatre états d'installation, ni un chemin
/// qu'on ne peut pas éprouver depuis Xcode.
///
/// **Un processus par agent, et un seul par agent.** Un agent est un compte
/// Matrix ; deux processus sur le même compte, ce sont deux réponses à chaque
/// message (`docs/AGENT.md`, § « Au plus un agent vivant par compte »). Le
/// registre est donc indexé par nom : démarrer `hermes` ne touche pas à `cc`,
/// et redémarrer `cc` ne le lance pas deux fois.
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

    /// L'agent embarqué dans le bundle de l'app. Le nom passe en `--agent` :
    /// c'est lui qui décide du dossier d'amorce (`~/.correspondance-<nom>`) et
    /// du compte Matrix auquel le processus se connecte.
    static func embeddedAgent(named agent: String) -> Launch? {
      guard let executable = Self.embeddedAgentURL else { return nil }
      return Launch(
        executable: executable,
        // `--watch-parent` : l'agent meurt avec nous, **quelle que soit la
        // façon dont nous mourons**. `applicationWillTerminate` ne couvre que
        // la fermeture propre — le seul cas où on n'a besoin de personne. Un
        // `pkill` sur l'app laissait l'agent vivant et connecté au Relais.
        arguments: [
          "run", "--agent", agent,
          "--watch-parent", String(ProcessInfo.processInfo.processIdentifier),
        ],
        // Le journal suit l'essai lui aussi : un cc d'essai ne doit pas écrire
        // par-dessus le journal du cc de production.
        logURL: URL(fileURLWithPath: "/tmp/correspondance-\(AgentPaths.sanitize(agent))\(CorrespondanceHome.trialSuffix).log")
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

  /// Le palier appliqué aux agents démarrés ensuite. Les tests le resserrent
  /// pour éprouver le redémarrage sans éprouver leur patience.
  var backoff = Backoff()

  /// Un processus surveillé par agent. La clé est le nom de l'agent, tel qu'il
  /// est passé en `--agent` : c'est aussi la clé de son amorce et de son compte.
  private var supervises: [String: Supervise] = [:]

  // MARK: - Lire l'état, par agent

  /// Le processus de cet agent tourne-t-il ? **Constaté**, pas cru : c'est le
  /// `Process` que l'app a lancé et n'a pas vu mourir.
  func isRunning(agent: String) -> Bool { supervises[agent]?.isRunning ?? false }

  /// Combien de fois cet agent est retombé depuis son démarrage.
  func redemarrages(agent: String) -> Int { supervises[agent]?.redemarrages ?? 0 }

  /// Pourquoi on ne le relance plus, quand on a renoncé.
  func abandon(agent: String) -> String? { supervises[agent]?.abandon }

  /// Le journal de cet agent, s'il a été lancé.
  func logURL(agent: String) -> URL? { supervises[agent]?.launch.logURL }

  /// Les agents dont un processus tourne en ce moment. L'écran des réglages
  /// s'en sert pour dire « local » sans le supposer.
  var agentsVivants: [String] {
    supervises.filter { $0.value.isRunning }.keys.sorted()
  }

  // MARK: - Démarrer, arrêter

  @discardableResult
  func start(_ launch: Launch, agent: String) throws -> Bool {
    // Un agent, un processus : on arrête le précédent avant d'en lancer un
    // autre sous le même nom. Deux processus sur un compte, ce sont deux
    // réponses au même message.
    stop(agent: agent)
    let supervise = Supervise(agent: agent, launch: launch, backoff: backoff)
    supervises[agent] = supervise
    return try supervise.lancer()
  }

  /// Arrêt propre d'un agent. Un agent orphelin qui continuerait de répondre au
  /// nom de quelqu'un serait pire qu'un agent mort.
  func stop(agent: String) {
    supervises[agent]?.stop()
  }

  /// Tout le monde s'arrête — appelé quand l'app se ferme. Avec plusieurs
  /// agents locaux, oublier ce pluriel laisserait les autres vivants.
  func stopAll() {
    for supervise in supervises.values { supervise.stop() }
  }

  /// Un processus d'agent, sa surveillance, son palier. Une instance par
  /// agent : le palier, le compteur de chutes et l'abandon sont *à lui*.
  @MainActor
  private final class Supervise {
    let agent: String
    let launch: Launch
    let backoff: Backoff

    private(set) var isRunning = false
    private(set) var redemarrages = 0
    private(set) var abandon: String?

    private var process: Process?
    private var arretVoulu = false
    private var relance: Task<Void, Never>?

    init(agent: String, launch: Launch, backoff: Backoff) {
      self.agent = agent
      self.launch = launch
      self.backoff = backoff
    }

    func stop() {
      arretVoulu = true
      relance?.cancel()
      relance = nil
      if let process, process.isRunning {
        process.terminate()
        AgentProcessHost.log.info("agent \(self.agent, privacy: .public) arrêté")
      }
      process = nil
      isRunning = false
    }

    @discardableResult
    func lancer() throws -> Bool {
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
      AgentProcessHost.log.info(
        "agent \(self.agent, privacy: .public) démarré (pid \(process.processIdentifier))"
      )
      return true
    }

    /// L'agent est tombé. On redémarre, avec un palier — pas une boucle folle.
    private func termine(code: Int32) {
      isRunning = false
      process = nil
      guard !arretVoulu else { return }

      // Toutes les chutes ne se valent pas. Un mot de passe refusé par le
      // Relais ne se répare pas tout seul : relancer huit fois ne ferait que
      // remplir le journal, en donnant l'illusion d'un plantage à répétition
      // alors que rien ne plante — c'est une configuration à refaire.
      guard AgentExit.shouldRestart(after: code) else {
        abandon = AgentExit.raisonFR(code) ?? "\(agent) s'est arrêté (code \(code))."
        AgentProcessHost.log.error(
          "\(self.agent, privacy: .public) : arrêt définitif (code \(code)) — pas de redémarrage"
        )
        return
      }

      redemarrages += 1
      guard !backoff.renonce(apres: redemarrages) else {
        abandon = "\(agent) s'est arrêté \(redemarrages) fois de suite (dernier code \(code)). "
          + "Son journal dira pourquoi."
        AgentProcessHost.log.error(
          "\(self.agent, privacy: .public) : abandon après \(self.redemarrages) redémarrages"
        )
        return
      }
      let delai = backoff.delai(essai: redemarrages)
      AgentProcessHost.log.info(
        "\(self.agent, privacy: .public) tombé (code \(code)) — redémarrage dans \(delai) s"
      )
      relance = Task { @MainActor [weak self] in
        try? await Task.sleep(for: .seconds(delai))
        guard let self, !self.arretVoulu else { return }
        _ = try? self.lancer()
      }
    }
  }
}
