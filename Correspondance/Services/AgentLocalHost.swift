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

  /// L'état de l'agent sur ce Mac.
  ///
  /// **`.actif` est une conclusion, jamais une lecture.** Le drapeau de macOS
  /// ne prouve rien tout seul : il survit à une désinstallation, à un dossier
  /// d'amorce effacé, à une app reconstruite ailleurs. Éprouvé sur une vraie
  /// machine — les réglages annonçaient « actif » alors qu'aucun service,
  /// aucune amorce et aucun compte n'existaient, et l'écran ne proposait plus
  /// que « Désactiver ».
  ///
  /// Il faut donc **trois** choses pour dire « actif » : le drapeau, l'amorce
  /// sur le disque, et un signe de vie de l'agent lui-même.
  enum State: Equatable {
    /// Jamais enregistré, ou désenregistré.
    case absent
    /// Tout est là, et l'agent a donné signe de vie récemment.
    case actif
    /// Tout est là, mais l'agent n'a rien publié depuis longtemps. On le dit —
    /// un service enregistré qui ne parle plus n'est pas « actif ».
    case silencieux(depuis: Date?)
    /// Enregistré, mais **l'utilisateur doit l'autoriser** dans
    /// Réglages Système › Général › Ouverture et extensions › Éléments d'ouverture.
    /// C'est le cas qu'il faut *montrer*, pas espérer.
    case attenteApprobation
    /// Le drapeau dit « enregistré », mais l'amorce n'est pas là : le service
    /// ne peut pas démarrer. C'est cassé, pas actif — et ça se répare en
    /// refaisant le chemin en entier.
    case incomplet
    /// Le plist n'est pas dans l'app : build sans l'agent embarqué.
    case introuvable

    var labelFR: String {
      switch self {
      case .absent: "pas installé sur ce Mac"
      case .actif: "actif sur ce Mac"
      case .silencieux(let depuis):
        if let depuis {
          "installé, mais muet depuis \(Self.ageFR(depuis))"
        } else {
          "installé, mais il n'a encore rien publié"
        }
      case .attenteApprobation: "à autoriser dans Réglages Système › Éléments d'ouverture"
      case .incomplet: "installé à moitié : le service est enregistré, son amorce a disparu"
      case .introuvable: "le service n'est pas dans l'app (build sans l'agent embarqué)"
      }
    }

    /// Au-delà, on ne parle plus d'un agent « actif ». Large exprès : un agent
    /// qui n'a rien à faire ne poste rien, et on ne veut pas crier au loup.
    static let silenceMax: TimeInterval = 3600

    static func ageFR(_ date: Date) -> String {
      let minutes = Int(max(0, Date().timeIntervalSince(date)) / 60)
      if minutes < 60 { return "\(minutes) min" }
      let heures = minutes / 60
      return heures < 24 ? "\(heures) h" : "\(heures / 24) j"
    }
  }

  /// La conclusion, à partir de ce qu'on sait vraiment. Pure, donc éprouvée :
  /// c'est elle qui empêche l'app d'affirmer ce qu'elle n'a pas vérifié.
  ///
  /// - `flagEnregistre` : ce que dit `SMAppService`, et rien de plus ;
  /// - `amorcePresente` : le `config.json` est-il sur le disque ;
  /// - `dernierStatus` : quand l'agent a publié son status dans la console.
  static func decide(
    flagEnregistre: Bool,
    demandeApprobation: Bool,
    plistPresent: Bool,
    amorcePresente: Bool,
    dernierStatus: Date?,
    maintenant: Date = Date()
  ) -> State {
    guard plistPresent else { return .introuvable }
    if demandeApprobation { return .attenteApprobation }
    guard flagEnregistre else { return .absent }
    // Le drapeau seul ne suffit pas : sans amorce, le service ne démarre pas.
    guard amorcePresente else { return .incomplet }
    guard let dernierStatus else { return .silencieux(depuis: nil) }
    if maintenant.timeIntervalSince(dernierStatus) > State.silenceMax {
      return .silencieux(depuis: dernierStatus)
    }
    return .actif
  }

  /// L'état réel : le drapeau de macOS, le disque, et le dernier status que
  /// l'agent a publié dans sa room console (l'app le lit déjà).
  static func state(agent: String, dernierStatus: Date? = nil) -> State {
    let service = SMAppService.agent(plistName: plistName(agent: agent))
    return decide(
      flagEnregistre: service.status == .enabled,
      demandeApprobation: service.status == .requiresApproval,
      plistPresent: service.status != .notFound,
      amorcePresente: hasBootstrap(agent: agent),
      dernierStatus: dernierStatus
    )
  }

  /// Écrit l'amorce, puis enregistre le service.
  ///
  /// L'ordre compte : un service qui démarre sans amorce boucle sur une erreur
  /// de config, et macOS finit par le brider.
  static func install(bootstrap: MatrixBridgeService.AgentBootstrap, agent: String) throws -> State {
    try writeBootstrap(bootstrap, agent: agent)
    let service = SMAppService.agent(plistName: plistName(agent: agent))
    // Un service déjà enregistré ne se réenregistre pas — mais on ne rend pas
    // `.actif` pour autant : l'amorce vient d'être écrite, l'agent n'a pas
    // encore parlé, et c'est `state(agent:)` qui conclut.
    if service.status != .enabled {
      try service.register()
      log.info("service enregistré pour \(agent, privacy: .public)")
    }
    return state(agent: agent)
  }

  /// Refait le chemin en entier : désenregistre, puis laisse l'appelant
  /// réinstaller. C'est la sortie du cas « installé à moitié », qui n'en avait
  /// aucune — un écran sans action possible est un cul-de-sac.
  static func reset(agent: String) {
    let service = SMAppService.agent(plistName: plistName(agent: agent))
    try? service.unregister()
    log.info("service remis à zéro pour \(agent, privacy: .public)")
  }

  static func uninstall(agent: String) throws {
    let service = SMAppService.agent(plistName: plistName(agent: agent))
    try service.unregister()
    log.info("service désenregistré pour \(agent, privacy: .public)")
  }

  /// Ce qu'on répond quand le service n'est pas dans l'app : une explication,
  /// pas un cul-de-sac.
  static let aideIntrouvable = """
    Cette build de l'app n'embarque pas l'agent. Reconstruis-la \
    (`xcodegen generate` puis un build Xcode), et vérifie que \
    Correspondance.app/Contents/MacOS/correspondance-agent existe. \
    En attendant, cc peut tourner sur une autre machine : « Sur une autre machine » ci-dessous.
    """

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
