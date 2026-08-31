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

  /// Scanne les moteurs connus. Bloquant (un `--version` par moteur trouvé,
  /// dix secondes au plus) : à appeler hors des acteurs.
  public static func scan(config: AgentConfig) -> EngineScan {
    let candidates: [(name: String, configured: String?)] = [
      ("claude", config.claude.binary),
      ("hermes", config.hermes.binary),
    ]
    return EngineScan(engines: candidates.map { candidate in
      guard let path = Subprocess.find(candidate.name, configured: candidate.configured) else {
        return Engine(name: candidate.name, path: nil, version: nil)
      }
      let version = try? Subprocess.run(
        binary: path, arguments: ["--version"], stdin: "", cwd: nil, timeoutSeconds: 10
      ).stdout
      let text = version.flatMap { String(data: $0, encoding: .utf8) }?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return Engine(name: candidate.name, path: path, version: text.flatMap { $0.isEmpty ? nil : $0 })
    })
  }

  /// La ligne que l'agent poste dans son event de status :
  /// `moteur hermes · prêts : claude, hermes` — ou `· prêts : aucun`.
  public func statusLine(backend: AgentConfig.Backend) -> String {
    let present = engines.filter(\.isPresent).map(\.name)
    let list = present.isEmpty ? "aucun" : present.joined(separator: ", ")
    return "moteur \(backend.rawValue) · prêts : \(list)"
  }

  /// Le rapport de `doctor`, une ligne par moteur, la conclusion en dernier.
  public func reportFR(backend: AgentConfig.Backend) -> String {
    var lines = engines.map { engine in
      guard let path = engine.path else { return "✗ \(engine.name) — introuvable" }
      return "✓ \(engine.name) — \(path)\(engine.version.map { " (\($0))" } ?? "")"
    }
    let selected = engines.first { $0.name == backend.rawValue }
    if selected?.isPresent == true {
      lines.append("moteur configuré : \(backend.rawValue) — prêt")
    } else {
      lines.append("moteur configuré : \(backend.rawValue) — ABSENT : l'agent ne pourra pas répondre")
    }
    return lines.joined(separator: "\n")
  }

  public func isPresent(_ backend: AgentConfig.Backend) -> Bool {
    engines.first { $0.name == backend.rawValue }?.isPresent == true
  }
}
