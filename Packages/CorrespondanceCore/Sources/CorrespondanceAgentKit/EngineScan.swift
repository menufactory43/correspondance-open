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

    public var isPresent: Bool { path != nil }
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
      return Engine(name: candidate.name, path: path, version: text.flatMap { $0.isEmpty ? nil : $0 })
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
    let present = engines.filter(\.isPresent).map(\.name)
    let list = present.isEmpty ? "aucun" : present.joined(separator: ", ")
    var line = ""
    if let agent, let host {
      line += "\(agent) tourne sur \(host)"
      if let since { line += " depuis \(Self.hourFormatter.string(from: since))" }
      line += " · "
    }
    return line + "moteur \(backend.rawValue) · prêts : \(list)"
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
      return "✓ \(engine.name) — \(path)\(engine.version.map { " (\($0))" } ?? "")"
    }
    let label = configuredEngine.map { $0 == backend.rawValue ? $0 : "\(backend.rawValue) (\($0))" } ?? backend.rawValue
    if isPresent(backend) {
      lines.append("moteur configuré : \(label) — prêt")
    } else {
      lines.append("moteur configuré : \(label) — ABSENT : l'agent ne pourra pas répondre")
    }
    return lines.joined(separator: "\n")
  }

  public func isPresent(_ backend: AgentConfig.Backend) -> Bool {
    let name = configuredEngine ?? backend.rawValue
    return engines.first { $0.name == name }?.isPresent == true
  }
}
