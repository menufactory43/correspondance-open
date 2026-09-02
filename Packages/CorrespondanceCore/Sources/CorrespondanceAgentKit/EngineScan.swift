import CorrespondanceMatrixClient
import Foundation

/// Quels moteurs cette machine sait lancer — le scan que `doctor` imprime et
/// que l'agent poste dans ses rooms en tête-à-tête (`agent.status`), pour que
/// l'app puisse le lire sans SSH : les moteurs vivent là où l'agent tourne,
/// pas là où l'app tourne.
public struct EngineScan: Sendable, Equatable {
  public struct Engine: Sendable, Equatable {
    public var name: String
    /// `nil` : introuvable — ni au chemin configuré, ni aux endroits habituels
    /// (`~/.local/bin` compris : l'installeur d'Hermes pose son binaire là,
    /// hors du PATH de la plupart des shells non-login).
    public var path: String?
    public var version: String?
    /// `false` : installé mais jamais connecté — le premier tour échouerait
    /// sur une erreur d'authentification. `nil` : pas de preuve connue.
    public var loggedIn: Bool?

    public var isPresent: Bool { path != nil }
    public var isLoggedOut: Bool { isPresent && loggedIn == false }
  }

  public var engines: [Engine]
  /// L'exécutable qu'il faut pour le moteur configuré. Pour `acp` ce n'est pas
  /// « acp » mais l'adaptateur (`claude-code-acp`, `codex-acp`, `goose`) : le
  /// nom du moteur et le nom du binaire ont cessé d'être le même mot.
  public var configuredEngine: String?

  public init(engines: [Engine], configuredEngine: String? = nil) {
    self.engines = engines
    self.configuredEngine = configuredEngine
  }

  /// Scanne les moteurs connus. Bloquant (un `--version` par moteur trouvé,
  /// dix secondes au plus) : à appeler hors des acteurs.
  public static func scan(config: AgentConfig) -> EngineScan {
    var candidates: [(name: String, configured: String?)] = [
      ("claude", config.claude.binary),
      ("hermes", config.hermes.binary),
    ]
    if !candidates.contains(where: { $0.name == config.acp.command }) {
      candidates.append((config.acp.command, config.acp.binary))
    }
    let configuredEngine = switch config.backend {
    case .claude: "claude"
    case .hermes: "hermes"
    case .acp: config.acp.command
    }
    let engines = candidates.map { candidate in
      guard let path = Subprocess.find(candidate.name, configured: candidate.configured) else {
        return Engine(name: candidate.name, path: nil, version: nil)
      }
      let version = try? Subprocess.run(
        binary: path, arguments: ["--version"], stdin: "", cwd: nil, timeoutSeconds: 10
      ).stdout
      let text = version.flatMap { String(data: $0, encoding: .utf8) }?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return Engine(
        name: candidate.name, path: path, version: text.flatMap { $0.isEmpty ? nil : $0 },
        loggedIn: EngineLogin.isLoggedIn(engine: candidate.name)
      )
    }
    return EngineScan(engines: engines, configuredEngine: configuredEngine)
  }

  /// La ligne que l'agent poste dans son event de status :
  /// `cc tourne sur umbrel depuis 14 h 02 · moteur acp · prêts : claude`.
  /// Sans l'hôte ni l'heure, les réglages disent « ça tourne » sans dire *où* —
  /// et avec deux hôtes possibles (ce Mac, le NUC), c'est la question qu'on pose.
  public func statusLine(backend: AgentConfig.Backend, agent: String? = nil, host: String? = nil, since: Date? = nil)
    -> String
  {
    // « Prêt » veut dire installé **et** pas prouvé déconnecté : un moteur à
    // connecter est dit à part, pour que l'app ne le propose pas comme prêt.
    let present = engines.filter { $0.isPresent && !$0.isLoggedOut }.map(\.name)
    let aConnecter = engines.filter(\.isLoggedOut).map(\.name)
    let list = present.isEmpty ? "aucun" : present.joined(separator: ", ")
    var line = ""
    if let agent, let host {
      line += "\(agent) tourne sur \(host)"
      if let since { line += " depuis \(Self.hourFormatter.string(from: since))" }
      line += " · "
    }
    line += "moteur \(backend.rawValue) · prêts : \(list)"
    if !aConnecter.isEmpty { line += " · à connecter : \(aConnecter.joined(separator: ", "))" }
    return line
  }

  /// Le nom de cette machine, court : `umbrel`, pas `umbrel.local`.
  public static var hostName: String {
    let name = ProcessInfo.processInfo.hostName
    return name.split(separator: ".").first.map(String.init) ?? name
  }

  static let hourFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "fr_FR")
    formatter.dateFormat = "HH 'h' mm"
    return formatter
  }()

  /// Le rapport de `doctor`, une ligne par moteur, la conclusion en dernier.
  public func reportFR(backend: AgentConfig.Backend) -> String {
    var lines = engines.map { engine in
      guard let path = engine.path else { return "✗ \(engine.name) — introuvable" }
      let version = engine.version.map { " (\($0))" } ?? ""
      if engine.isLoggedOut { return "! \(engine.name) — \(path)\(version) — installé mais pas connecté" }
      return "✓ \(engine.name) — \(path)\(version)"
    }
    let label = configuredEngine.map { $0 == backend.rawValue ? $0 : "\(backend.rawValue) (\($0))" } ?? backend.rawValue
    if isPresent(backend) {
      lines.append("moteur configuré : \(label) — prêt")
    } else {
      lines.append("moteur configuré : \(label) — ABSENT : l'agent ne pourra pas répondre")
    }
    return lines.joined(separator: "\n")
  }

  /// Ce que l'agent répond quand son moteur n'est pas là.
  ///
  /// Se taire était le pire des choix : on écrit « @cc … », rien ne revient, et
  /// il faut aller lire un journal sur une autre machine pour apprendre que
  /// `hermes` n'a jamais été installé. Un agent qui ne peut pas répondre doit
  /// **dire pourquoi**, avec l'endroit et le geste — c'est encore vider la
  /// file, pas la remplir : une réponse close une demande, un silence non.
  ///
  /// Pure, donc éprouvée : c'est un message qu'on lit dans une conversation.
  public static func absenceFR(engine: String, host: String) -> String {
    var lignes = ["\(engine) n'est pas installé sur \(host) : je ne peux pas répondre."]
    if let geste = installationFR[engine] {
      lignes.append("Là-bas : \(geste)")
    }
    lignes.append(
      "Ou change mon moteur depuis Réglages › Agents — le réglage part par ma console, "
        + "sans SSH ni redémarrage."
    )
    return lignes.joined(separator: "\n")
  }

  /// Le geste d'installation par moteur. Volontairement court : c'est une
  /// bulle dans une conversation, pas une page de documentation.
  public static let installationFR: [String: String] = [
    "claude": "npm install -g @anthropic-ai/claude-code, puis `claude` une fois pour ouvrir la session.",
    "hermes": "l'installeur d'Hermes pose son binaire dans ~/.local/bin.",
    "claude-code-acp": "npm install -g @zed-industries/claude-code-acp",
    "codex-acp": "npm install -g @agentclientprotocol/codex-acp, puis `codex login` une fois (compte ChatGPT).",
    "goose": "brew install block-goose-cli",
    "grok": "curl -fsSL https://x.ai/cli/install.sh | bash, puis `grok login` une fois (SuperGrok ou X Premium).",
  ]

  public func isPresent(_ backend: AgentConfig.Backend) -> Bool {
    let name = configuredEngine ?? backend.rawValue
    return engines.first { $0.name == name }?.isPresent == true
  }

  /// Installé, mais sa trace de connexion manque : le tour échouerait sur une
  /// erreur d'authentification brute, en anglais, sans le geste.
  public func isLoggedOut(_ backend: AgentConfig.Backend) -> Bool {
    let name = configuredEngine ?? backend.rawValue
    return engines.first { $0.name == name }?.isLoggedOut == true
  }

  /// Ce que l'agent répond quand son moteur est là mais pas connecté. Même
  /// principe que l'absence : dire où, et quoi faire, plutôt que l'erreur brute.
  public static func nonConnecteFR(engine: String, host: String) -> String {
    var lignes = ["\(engine) est installé sur \(host) mais pas connecté : je ne peux pas répondre."]
    if let geste = EngineLogin.gesture(for: engine) {
      lignes.append("Là-bas : \(geste)")
    }
    lignes.append(
      "Ou change mon moteur depuis Réglages › Agents — le réglage part par ma console, "
        + "sans SSH ni redémarrage."
    )
    return lignes.joined(separator: "\n")
  }
}
