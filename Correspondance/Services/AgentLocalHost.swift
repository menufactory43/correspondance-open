import CorrespondanceCore
import Foundation
import OSLog
import ServiceManagement

/// L'hôte « Ce Mac » : l'agent tourne à côté de l'app, en LaunchAgent.
///
/// C'est le seul chemin qui fait de « avoir cc » un bouton plutôt qu'un
/// week-end : `claude` est déjà connecté sur cette machine, donc l'abonnement
/// est là, et il n'y a ni serveur à louer ni SSH à ouvrir.
///
/// Ce que l'app pose : l'amorce dans `~/.correspondance-<agent>/config.json`
/// (en `0600`), et le service par `SMAppService.agent(plistName:)` — le plist
/// est **dans le bundle**, `Contents/Library/LaunchAgents/`, c'est macOS qui
/// l'exige. Un plist statique ne connaît pas `~` : il passe `--agent <nom>`, et
/// c'est le binaire qui en déduit son dossier (`AgentHome`).
@MainActor
enum AgentLocalHost {
  static let log = Logger(subsystem: "com.correspondance.app", category: "agent-local")

  /// Le nom du plist embarqué, sans extension de chemin : macOS le cherche
  /// dans `Contents/Library/LaunchAgents/`.
  static func plistName(agent: String) -> String { "app.correspondance.agent.plist" }

  /// L'état du service, tel que macOS le voit.
  enum State: Equatable {
    /// Jamais enregistré, ou désenregistré.
    case absent
    /// Enregistré et lancé.
    case actif
    /// Enregistré, mais **l'utilisateur doit l'autoriser** dans
    /// Réglages Système › Général › Ouverture et extensions › Éléments d'ouverture.
    /// C'est le cas qu'il faut *montrer*, pas espérer.
    case attenteApprobation
    case introuvable

    var labelFR: String {
      switch self {
      case .absent: "pas installé sur ce Mac"
      case .actif: "actif sur ce Mac"
      case .attenteApprobation: "à autoriser dans Réglages Système › Éléments d'ouverture"
      case .introuvable: "le service n'est pas dans l'app (build sans l'agent embarqué)"
      }
    }
  }

  static func state(agent: String) -> State {
    let service = SMAppService.agent(plistName: plistName(agent: agent))
    return switch service.status {
    case .enabled: .actif
    case .requiresApproval: .attenteApprobation
    case .notRegistered: .absent
    case .notFound: .introuvable
    @unknown default: .introuvable
    }
  }

  /// Écrit l'amorce, puis enregistre le service.
  ///
  /// L'ordre compte : un service qui démarre sans amorce boucle sur une erreur
  /// de config, et macOS finit par le brider.
  static func install(bootstrap: MatrixBridgeService.AgentBootstrap, agent: String) throws -> State {
    try writeBootstrap(bootstrap, agent: agent)
    let service = SMAppService.agent(plistName: plistName(agent: agent))
    if service.status == .enabled { return .actif }
    try service.register()
    log.info("service enregistré pour \(agent, privacy: .public)")
    return state(agent: agent)
  }

  static func uninstall(agent: String) throws {
    let service = SMAppService.agent(plistName: plistName(agent: agent))
    try service.unregister()
    log.info("service désenregistré pour \(agent, privacy: .public)")
  }

  /// Ouvre le panneau où l'approbation se donne — parce que « va dans les
  /// réglages » n'est pas une instruction, c'est un aveu.
  static func openLoginItemsSettings() {
    SMAppService.openSystemSettingsLoginItems()
  }

  /// L'amorce sur le disque, en `0600` : elle contient le mot de passe Matrix
  /// de l'agent.
  static func writeBootstrap(_ bootstrap: MatrixBridgeService.AgentBootstrap, agent: String) throws {
    let directory = AgentPaths.directory(agent: agent)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
    )
    let url = directory.appending(path: "config.json")
    let data = Data(bootstrap.configJSON().utf8)
    try data.write(to: url, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path())
  }

  /// L'amorce est-elle déjà posée pour cet agent ?
  static func hasBootstrap(agent: String) -> Bool {
    FileManager.default.fileExists(atPath: AgentPaths.directory(agent: agent).appending(path: "config.json").path())
  }
}

/// Le même calcul que `AgentHome` côté agent, redit ici parce que l'app ne peut
/// pas dépendre de l'AgentKit (`Process` n'existe pas sur iOS). Les deux
/// définitions sont tenues ensemble par un test.
enum AgentPaths {
  static func directory(agent: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
    let name = sanitize(agent)
    if name == "cc" { return home.appending(path: ".correspondance-agent") }
    return home.appending(path: ".correspondance-\(name)")
  }

  static func sanitize(_ agent: String) -> String {
    let cleaned = agent.lowercased().map { character -> Character in
      character.isLetter || character.isNumber || character == "." || character == "-" || character == "_"
        ? character : "-"
    }
    let text = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
    return text.isEmpty ? "cc" : text
  }
}
