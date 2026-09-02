import CorrespondanceCore
import Foundation
import OSLog
import ServiceManagement

/// L'hôte « Ce Mac » : l'amorce sur le disque, et l'agent lancé **par l'app**
/// (`AgentProcessHost`).
///
/// C'est le chemin qui fait de « avoir cc » un bouton plutôt qu'un week-end :
/// `claude` est déjà connecté sur cette machine, donc l'abonnement est là, et
/// il n'y a ni serveur à louer ni SSH à ouvrir. Son prix, dit franchement dans
/// l'interface : cc s'arrête quand on quitte l'app.
///
/// Ce que l'app pose : l'amorce dans `~/.correspondance-<agent>/config.json`
/// (en `0600`). Le service LaunchAgent est rangé derrière `useLaunchAgent`,
/// faux et non proposé dans l'interface — l'enquête qui a mené là est dans
/// `docs/AGENT.md`, § « Pourquoi cc ne tourne pas en LaunchAgent ».
@MainActor
enum AgentLocalHost {
  static let log = Logger(subsystem: "com.correspondance.app", category: "agent-local")

  /// **Rangé, pas jeté.** `SMAppService` reste dans le dépôt derrière ce
  /// drapeau — faux, et non proposé dans l'interface. Il achèterait une seule
  /// chose : cc qui répond quand l'app est *quittée*, le Mac allumé. Pour un cc
  /// joignable jour et nuit, c'est l'hôte distant qu'il faut. L'enquête (quatre
  /// hypothèses éliminées, deux restantes) est dans `docs/AGENT.md`.
  static let useLaunchAgent = false

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
    /// Jamais démarré, ou arrêté.
    case absent
    /// Le processus tourne, et l'agent a donné signe de vie récemment.
    case actif
    /// Le processus tourne, mais l'agent n'a rien publié depuis longtemps. On
    /// le dit — un processus vivant qui ne parle plus n'est pas « actif ».
    case silencieux(depuis: Date?)
    /// L'amorce n'est pas sur le disque : l'agent ne peut pas se connecter.
    /// C'est cassé, pas actif — et ça se répare en refaisant le chemin.
    case incomplet
    /// Le binaire n'est pas dans le bundle. **Constaté sur le disque**, jamais
    /// deviné : on regarde `Contents/MacOS/correspondance-agent`.
    case introuvable
    /// L'agent est tombé trop de fois de suite. On dit combien, et on renvoie au
    /// journal — pas de boucle folle, pas de silence non plus.
    case abandonne(raison: String)

    /// Ce que l'écran affiche. Le nom de l'agent est un paramètre : la phrase
    /// « l'amorce de cc n'est pas sur le disque » était fausse dès qu'on
    /// regardait `hermes`, et une phrase fausse dans un écran d'état coûte
    /// plus cher qu'une phrase absente.
    func labelFR(agent: String = MatrixIdentity.agentName) -> String {
      switch self {
      case .absent: "arrêté"
      case .actif: "actif — \(agent) répond tant que Correspondance est ouverte"
      case .silencieux(let depuis):
        if let depuis {
          "démarré, mais muet depuis \(Self.ageFR(depuis))"
        } else {
          "démarré, il n'a pas encore publié son premier status"
        }
      case .incomplet: "l'amorce de \(agent) n'est pas sur le disque"
      case .introuvable: "cette build n'embarque pas l'agent"
      case .abandonne(let raison): raison
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
  /// Le premier essai réel avait montré pourquoi elle doit exister : macOS
  /// répondait « enregistré » alors qu'aucun service, aucune amorce et aucun
  /// compte n'existaient, et l'écran ne proposait plus que « Désactiver ».
  static func decide(
    binairePresent: Bool,
    processusVivant: Bool,
    amorcePresente: Bool,
    dernierStatus: Date?,
    abandon: String? = nil,
    maintenant: Date = Date()
  ) -> State {
    guard binairePresent else { return .introuvable }
    if let abandon { return .abandonne(raison: abandon) }
    // L'amorce d'abord : sans elle, démarrer le processus ne sert à rien, et
    // c'est le cas qu'il faut savoir réparer.
    guard amorcePresente else { return .incomplet }
    guard processusVivant else { return .absent }
    guard let dernierStatus else { return .silencieux(depuis: nil) }
    if maintenant.timeIntervalSince(dernierStatus) > State.silenceMax {
      return .silencieux(depuis: dernierStatus)
    }
    return .actif
  }

  /// L'état réel : le binaire sur le disque, le processus que l'app surveille,
  /// l'amorce, et le dernier status publié dans la room console.
  static func state(agent: String, dernierStatus: Date? = nil) -> State {
    decide(
      binairePresent: AgentProcessHost.Launch.embeddedAgentURL != nil,
      processusVivant: AgentProcessHost.shared.isRunning(agent: agent),
      amorcePresente: hasBootstrap(agent: agent),
      dernierStatus: dernierStatus,
      abandon: AgentProcessHost.shared.abandon(agent: agent)
    )
  }

  // MARK: - Reprise au lancement

  /// « cc est voulu sur ce Mac » : posé par « Activer », retiré par « Arrêter ».
  /// C'est un choix de l'utilisateur, pas une croyance sur l'état du monde —
  /// l'état, lui, se constate (`state`).
  static func wantedKey(agent: String) -> String { "agent.\(AgentPaths.sanitize(agent)).voulu" }

  static func isWanted(agent: String) -> Bool {
    UserDefaults.standard.bool(forKey: wantedKey(agent: agent))
  }

  static func setWanted(_ value: Bool, agent: String) {
    UserDefaults.standard.set(value, forKey: wantedKey(agent: agent))
    // Le drapeau seul ne dit pas *qui* : au lancement il faut la liste, sinon
    // on ne saurait relancer que l'agent dont on connaît déjà le nom — et un
    // second agent activé hier resterait mort sans que rien ne le dise.
    var connus = Set(knownWantedAgents)
    if value { connus.insert(agent) } else { connus.remove(agent) }
    UserDefaults.standard.set(connus.sorted(), forKey: wantedListKey)
  }

  /// La clé de la liste des agents voulus sur ce Mac.
  static let wantedListKey = "agents.voulus"

  /// Les agents que l'utilisateur a voulus ici, dans l'ordre. C'est un choix
  /// mémorisé, pas un état : ce qui tourne vraiment se constate (`state`).
  static var knownWantedAgents: [String] {
    var noms = Set(UserDefaults.standard.array(forKey: wantedListKey) as? [String] ?? [])
    // Reprise des installations d'avant la liste : cc y était voulu sans que
    // personne n'ait écrit son nom nulle part.
    if isWanted(agent: MatrixIdentity.agentName) { noms.insert(MatrixIdentity.agentName) }
    return noms.filter { isWanted(agent: $0) }.sorted()
  }

  /// Faut-il relancer l'agent au lancement de l'app ? Pur, pour les tests :
  /// il faut que l'utilisateur l'ait voulu, que l'amorce soit là et le binaire
  /// aussi. Trouvé en vrai : cc mourait avec l'app (voulu), et rien ne le
  /// relançait — l'écran disait « arrêté » et proposait de *ré-activer*, ce qui
  /// refait le compte et repose un mot de passe pour rien.
  static func shouldResume(wanted: Bool, amorcePresente: Bool, binairePresent: Bool) -> Bool {
    wanted && amorcePresente && binairePresent
  }

  /// Relance l'agent avec l'amorce déjà sur le disque — sans repasser par le
  /// Relais. `force` est le bouton « Démarrer » ; sans lui, c'est la reprise au
  /// lancement, qui respecte un « Arrêter » antérieur. Rend `nil` quand il n'y
  /// avait rien à reprendre.
  @discardableResult
  static func resume(agent: String, force: Bool = false) -> State? {
    let launch = AgentProcessHost.Launch.embeddedAgent(named: agent)
    guard shouldResume(
      wanted: force || isWanted(agent: agent),
      amorcePresente: hasBootstrap(agent: agent),
      binairePresent: launch != nil
    ), let launch else { return nil }
    if force { setWanted(true, agent: agent) }
    do {
      try AgentProcessHost.shared.start(launch, agent: agent)
      log.info("agent relancé pour \(agent, privacy: .public)")
    } catch {
      log.error("relance impossible pour \(agent, privacy: .public) : \(error.localizedDescription, privacy: .public)")
    }
    return state(agent: agent)
  }

  /// Relance **tous** les agents voulus dont l'amorce est là. C'est ce que
  /// l'app fait à son lancement : `cc` et `hermes` sur ce Mac renaissent tous
  /// les deux, pas seulement le premier. Rend les noms effectivement relancés,
  /// pour que l'appelant puisse le dire plutôt que le supposer.
  @discardableResult
  static func resumeAll() -> [String] {
    knownWantedAgents.filter { resume(agent: $0) != nil }
  }

  /// Écrit l'amorce, puis démarre l'agent.
  ///
  /// L'ordre compte : un agent qui démarre sans amorce boucle sur une erreur de
  /// configuration.
  @discardableResult
  static func install(bootstrap: MatrixBridgeService.AgentBootstrap, agent: String) throws -> State {
    try writeBootstrap(bootstrap, agent: agent)
    setWanted(true, agent: agent)
    if useLaunchAgent {
      let service = SMAppService.agent(plistName: plistName(agent: agent))
      if service.status != .enabled { try service.register() }
      return state(agent: agent, dernierStatus: nil)
    }
    guard let launch = AgentProcessHost.Launch.embeddedAgent(named: agent) else {
      return .introuvable
    }
    try AgentProcessHost.shared.start(launch, agent: agent)
    return state(agent: agent)
  }

  static func uninstall(agent: String) throws {
    setWanted(false, agent: agent)
    AgentProcessHost.shared.stop(agent: agent)
    if useLaunchAgent {
      try SMAppService.agent(plistName: plistName(agent: agent)).unregister()
    }
    log.info("agent arrêté pour \(agent, privacy: .public)")
  }

  /// Refait le chemin en entier. C'est la sortie du cas « installé à moitié »,
  /// qui n'en avait aucune — un écran sans action possible est un cul-de-sac.
  static func reset(agent: String) {
    setWanted(false, agent: agent)
    AgentProcessHost.shared.stop(agent: agent)
    if useLaunchAgent {
      try? SMAppService.agent(plistName: plistName(agent: agent)).unregister()
    }
    log.info("agent remis à zéro pour \(agent, privacy: .public)")
  }

  /// Le journal d'un agent, pour l'ouvrir depuis les réglages.
  static func logURL(agent: String) -> URL? { AgentProcessHost.shared.logURL(agent: agent) }

  /// Ce qu'on dit quand le binaire n'est pas dans le bundle. On **constate**,
  /// on ne devine pas : l'ancien message conseillait de vérifier un fichier qui
  /// existait bel et bien, ce qui envoyait chercher au mauvais endroit.
  static let aideIntrouvable = """
    Cette build n'embarque pas l'agent : \
    Correspondance.app/Contents/MacOS/correspondance-agent est absent. \
    Reconstruis avec `xcodegen generate` puis un build Xcode — la phase \
    « Embed correspondance-agent » le pose. En attendant, cc peut tourner sur \
    une autre machine (« Sur une autre machine », ci-dessous).
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
  /// **`CORRESPONDANCE_HOME` déplace ce dossier**, exactement comme il déplace
  /// les données de l'app et son entrée du Trousseau. Sans ça, un essai
  /// écrivait l'amorce de son cc par-dessus celle du cc de production —
  /// `docs/MATRIX-SETUP.md` signalait le piège et conseillait de sauter
  /// l'étape ; il est corrigé, pas contourné. L'agent recalcule le même chemin
  /// de son côté (`AgentHome.folderName`) : il hérite de la variable en tant
  /// que processus enfant, donc les deux tombent d'accord sans se parler.
  static func directory(
    agent: String,
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL {
    home.appending(path: folderName(agent: agent, environment: environment))
  }

  static func folderName(
    agent: String,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> String {
    let name = sanitize(agent)
    let base = name == "cc" ? ".correspondance-agent" : ".correspondance-\(name)"
    guard let essai = CorrespondanceHome.resolvedName(from: environment) else { return base }
    return "\(base)-\(essai)"
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
