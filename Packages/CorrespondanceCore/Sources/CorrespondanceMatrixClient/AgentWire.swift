import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Le format de fil entre l'app et l'agent : les types d'events et le nom de
/// leurs champs.
///
/// Il vit ici, dans le client Matrix, parce que **les deux côtés en ont besoin
/// et qu'aucun des deux ne peut dépendre de l'autre** : l'app tourne sur iOS,
/// où `Process` n'existe pas, donc `CorrespondanceCore` ne peut pas dépendre de
/// `CorrespondanceAgentKit` ; et l'agent tourne sous Linux, sans SwiftUI, donc
/// il ne peut pas dépendre de `CorrespondanceCore`.
///
/// Une seule définition des clés, donc, et pas deux qui divergent au premier
/// champ ajouté. Les ponts mautrix ne relaient aucun de ces types : ce qui s'y
/// dit reste entre le Relais et ses clients.
public enum AgentWire {

  // MARK: - Types d'events

  /// Ce que l'agent propose, et que l'app rend en brouillon.
  public static let proposalType = "fr.correspondance.agent.proposal"
  /// Une demande d'outil. Conservée pour les agents d'avant la pleine
  /// permission ; plus rien ne l'émet côté ACP.
  public static let permissionType = "fr.correspondance.agent.permission"
  /// Ce que l'agent sait de sa machine : « cc tourne sur umbrel depuis 14 h 02 ».
  public static let statusType = "fr.correspondance.agent.status"
  /// La configuration de l'agent — event **d'état** de sa room console.
  public static let configType = "fr.correspondance.agent.config"
  /// Un tour journalisé : qui, quoi, quels outils, combien de temps.
  public static let journalType = "fr.correspondance.agent.journal"
  /// Un ordre d'un propriétaire à l'agent, posté dans sa console — event de
  /// timeline, pas d'état : un ordre se donne une fois, il ne se rejoue pas.
  /// Le seul aujourd'hui : `rescan`, « refais ton scan des moteurs et redis
  /// ton status ». C'est ce qui évite un redémarrage après un login ou une
  /// installation sur la machine de l'agent.
  public static let commandType = "fr.correspondance.agent.command"
  /// Ce qu'est un salon natif du Relais — event **d'état** posé par l'app à la
  /// création. `kind: agent` : un tête-à-tête avec un agent, où il répond à
  /// tout message d'un propriétaire, sans mention. Sans ce marqueur, un salon
  /// natif n'est rien pour l'app, et l'agent y exige sa mention : ni la note
  /// à soi ni un salon de gestion ne deviennent un tête-à-tête par accident.
  public static let conversationType = "fr.correspondance.conversation"
  /// Un **aparté** : ce qu'un propriétaire dit à un agent devant des humains.
  /// L'app l'envoie à la place d'un `m.room.message` dès qu'un message d'un
  /// fil bridgé nomme un agent présent (`@cc résume`, `dis à @claude…`) : les
  /// ponts mautrix ne relaient que `m.room.message`, donc le correspondant ne
  /// le voit jamais — ni la question, ni le brouillon qui lui répond. Le
  /// contenu a la forme d'un message texte (`msgtype`, `body`, `m.relates_to`),
  /// plus `agents` : les noms des agents nommés, pour que le fil dise avec qui
  /// l'aparté a eu lieu.
  public static let asideType = "fr.correspondance.agent.aside"
  /// Ce que l'agent dit **de lui-même**, à ses propriétaires seuls : un tour
  /// qui a échoué et pourquoi, un délai dépassé, un moteur absent. Les ponts
  /// ne le relaient pas ; l'app le rend en ligne système, avec la cause et un
  /// geste (`action`). Une panne qui ne se voit pas passe pour de la lenteur.
  public static let noticeType = "fr.correspondance.agent.notice"
  /// Un message envoyé **par l'agent au nom du propriétaire**, en mode
  /// « répond seul » : posé sur l'event `m.room.message`, pour que l'app le
  /// marque (« Envoyé par cc pour vous ») et que l'agent ne se réponde pas.
  public static let pilotedKey = "fr.correspondance.agent.piloted"

  public enum NoticeKey {
    public static let agent = "agent"
    public static let body = "body"
    /// `engine_missing`, `engine_offline`, `timeout`, `error`, `handover`.
    public static let reason = "reason"
    /// Le geste proposé : `rescan` (relancer), `retry` (réessayer), ou rien.
    public static let action = "action"
  }

  /// Les clés d'une proposition, au-delà de `body` et `agent`.
  public enum ProposalKey {
    /// `reply` (défaut, un brouillon demandé), `suggest` (proposé sans qu'on
    /// demande, rendu en bandeau au-dessus de la saisie), `summary` (un résumé
    /// ou le point du matin), `handover` (l'agent passe la main : hors cadre).
    public static let kind = "kind"
    /// Pour `handover` : pourquoi l'agent n'a pas répondu seul.
    public static let reason = "reason"
  }

  public enum ProposalKind {
    public static let reply = "reply"
    public static let suggest = "suggest"
    public static let summary = "summary"
    public static let handover = "handover"
  }

  /// Les valeurs de `rooms.<id>.suggest`.
  public enum Suggest {
    public static let off = "off"
    public static let always = "always"
    public static let keywords = "keywords"
  }

  public enum ConversationKey {
    public static let kind = "kind"
    /// L'agent **à qui est** ce fil, par son nom court (`claude`). Quand un
    /// second agent y est invité, c'est lui qui répond à ce qui ne nomme
    /// personne — l'autre attend qu'on l'appelle. Absent sur les fils d'avant :
    /// le nom du salon, que l'app pose au nom de l'agent, en tient lieu.
    public static let agent = "agent"
  }

  public enum AsideKey {
    public static let agents = "agents"
  }

  /// Un agent qui répond parce qu'un autre agent l'a chargé le dit dans son
  /// message : un agent qui lit ce drapeau ne répond jamais à ce message-là.
  /// C'est la profondeur 1 de la délégation, portée par l'event lui-même.
  public static let delegatedKey = "fr.correspondance.agent.delegated"

  // MARK: - Mentions

  /// Le nom sous lequel on appelle un agent dans un message : `@` et son nom court.
  public static func trigger(forAgent name: String) -> String {
    name.hasPrefix("@") ? name : "@\(name)"
  }

  /// Les agents, parmi `agents` (noms courts), que ce texte nomme — n'importe
  /// où, en mot entier : `@cc` dans « dis à @cc de voir » compte, `@ccc` non.
  /// Pure et partagée : l'app s'en sert pour décider qu'un message part en
  /// aparté, l'agent pour savoir s'il est nommé — une seule règle, pas deux.
  public static func agentsMentioned(in text: String, among agents: [String]) -> [String] {
    let texte = text.lowercased()
    return agents.filter { agent in
      let mot = trigger(forAgent: agent).lowercased()
      var recherche = texte.startIndex
      while let plage = texte.range(of: mot, range: recherche..<texte.endIndex) {
        let apres = plage.upperBound
        let suivantOK = apres == texte.endIndex || !(texte[apres].isLetter || texte[apres].isNumber || texte[apres] == "_")
        let avantOK = plage.lowerBound == texte.startIndex || !(texte[texte.index(before: plage.lowerBound)].isLetter || texte[texte.index(before: plage.lowerBound)].isNumber)
        if suivantOK && avantOK { return true }
        recherche = apres
      }
      return false
    }
  }

  /// Les agents **à qui s'adresse** ce message. Ceux qui ouvrent la phrase
  /// (`@claude @cc vous allez bien ?`) sont les destinataires, et eux seuls :
  /// « @cc dis à @claude de… » parle **à** cc **de** claude. Sans agent en
  /// tête, tous ceux qui sont nommés sont appelés (« hey @cc et @claude »).
  /// Vide : personne n'est nommé.
  public static func agentsAddressed(in text: String, among agents: [String]) -> [String] {
    var reste = Substring(text).drop { $0.isWhitespace }
    var enTete: [String] = []
    boucle: while reste.first == "@" {
      let mot = reste.prefix { !($0.isWhitespace || $0 == "," || $0 == ":") }
      guard let agent = agents.first(where: { trigger(forAgent: $0).caseInsensitiveCompare(String(mot)) == .orderedSame }) else { break boucle }
      if !enTete.contains(agent) { enTete.append(agent) }
      reste = reste.dropFirst(mot.count).drop { $0.isWhitespace || $0 == "," || $0 == ":" }
    }
    if !enTete.isEmpty { return enTete }
    return agentsMentioned(in: text, among: agents)
  }

  public enum ConversationKind {
    public static let agent = "agent"
  }

  public enum CommandKey {
    public static let agent = "agent"
    public static let command = "command"
  }

  public enum Command {
    public static let rescan = "rescan"
  }

  // MARK: - Champs

  /// Les clés de `fr.correspondance.agent.config`. La version du schéma est
  /// dans `version` : un agent plus vieux que l'event refuse de le lire plutôt
  /// que d'en deviner la moitié.
  public enum ConfigKey {
    public static let version = "version"
    public static let agent = "agent"
    public static let owners = "owners"
    public static let trigger = "trigger"
    public static let hourlyCap = "hourlyCap"
    public static let defaultMode = "defaultMode"
    public static let backend = "backend"
    public static let toolPreset = "toolPreset"
    public static let model = "model"
    public static let systemPrompt = "systemPrompt"
    public static let rooms = "rooms"
    public static let acpCommand = "acpCommand"
    /// Les arguments de l'adaptateur : `gemini --acp`, `grok agent stdio`,
    /// `goose acp` — le binaire seul ouvre une interface interactive, pas un
    /// serveur ACP. Absent : l'agent applique ce qu'il sait de la commande.
    public static let acpArguments = "acpArguments"
    /// Les autres agents du Relais, par leur MXID. C'est ce qui fait d'un salon
    /// un **atelier** : la mention devient obligatoire, et un agent ne relance
    /// pas un agent.
    public static let peers = "peers"
    /// Dans chaque entrée de `rooms`.
    public static let roomCwd = "cwd"
    public static let roomMode = "mode"
    /// « Faut-il m'appeler par mon nom dans ce salon ? » `false` : tout message
    /// d'un propriétaire est une demande.
    public static let roomMention = "mention"
    /// Le nombre de messages du fil donnés à l'agent à chaque tour, par
    /// défaut (`context`, au premier niveau) ou par salon (`rooms.<id>.context`).
    /// `0` coupe : l'agent ne voit que ce qui lui est adressé.
    public static let context = "context"
    public static let roomContext = "context"
    /// `off` | `always` | `keywords` : l'agent propose-t-il une réponse à chaque
    /// message d'un tiers, sans qu'on le nomme ? Toujours en brouillon.
    public static let roomSuggest = "suggest"
    /// Les mots qui réveillent l'agent quand `suggest` vaut `keywords`.
    public static let roomKeywords = "keywords"
    /// Le cadre du mode `pilot` : une phrase, ce que l'agent a le droit de
    /// faire seul dans ce salon. Hors cadre, il passe la main.
    public static let roomFrame = "frame"
    /// L'heure du point du matin (`"08:00"`), ou absent.
    public static let heartbeat = "heartbeat"
  }

  /// Les valeurs de `mode` (`defaultMode`, `rooms.<id>.mode`).
  public enum Mode {
    public static let direct = "direct"
    public static let draft = "draft"
    /// L'agent répond seul, dans le cadre du salon, en marquant ses messages.
    public static let pilot = "pilot"
  }

  /// Les clés de `fr.correspondance.agent.status`, au-delà du texte lisible.
  /// La machine et le pid sont ce qui permet de refuser un second agent sur le
  /// même compte — deux agents, ce sont deux réponses à chaque message.
  public enum StatusKey {
    public static let host = "host"
    public static let pid = "pid"
    /// L'adresse par laquelle on joint cette machine — celle du tailnet quand
    /// il y en a une (`100.x.y.z`), sinon la première adresse IPv4 qui n'est
    /// pas la boucle locale. C'est ce que les réglages montrent à côté du nom
    /// d'un hôte distant : un nom seul ne dit pas où coller une commande SSH.
    public static let address = "address"
  }

  /// Le nom court de cette machine : `umbrel`, pas `umbrel.local`.
  public static var hostName: String {
    let nom = ProcessInfo.processInfo.hostName
    return nom.split(separator: ".").first.map(String.init) ?? nom
  }

  /// L'adresse de cette machine, lue sur ses interfaces : Tailscale d'abord
  /// (plage `100.64.0.0/10`), sinon la première IPv4 hors boucle locale.
  /// `nil` quand la machine n'a aucune adresse — et on ne l'invente pas.
  public static var hostAddress: String? {
    let adresses = ipv4Addresses()
    return adresses.first(where: { estTailscale($0) }) ?? adresses.first
  }

  /// `100.64.0.0/10` : de `100.64.0.0` à `100.127.255.255`.
  public static func estTailscale(_ adresse: String) -> Bool {
    let parts = adresse.split(separator: ".").compactMap { Int($0) }
    guard parts.count == 4, parts[0] == 100 else { return false }
    return (64...127).contains(parts[1])
  }

  static func ipv4Addresses() -> [String] {
    var resultat: [String] = []
    var liste: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&liste) == 0, let debut = liste else { return [] }
    defer { freeifaddrs(liste) }
    var courant: UnsafeMutablePointer<ifaddrs>? = debut
    while let entree = courant {
      defer { courant = entree.pointee.ifa_next }
      guard let sockaddr = entree.pointee.ifa_addr, sockaddr.pointee.sa_family == UInt8(AF_INET) else { continue }
      // `IFF_UP` est un `Int32` sur Darwin et un `Int` sur Linux : on ramène tout en `Int`.
      let flags = Int(entree.pointee.ifa_flags)
      guard flags & Int(IFF_UP) != 0, flags & Int(IFF_LOOPBACK) == 0 else { continue }
      var tampon = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      #if os(Linux)
      let longueur = socklen_t(MemoryLayout<sockaddr_in>.size)
      #else
      let longueur = socklen_t(sockaddr.pointee.sa_len)
      #endif
      guard getnameinfo(sockaddr, longueur, &tampon, socklen_t(tampon.count),
                        nil, 0, NI_NUMERICHOST) == 0
      else { continue }
      let adresse = String(cString: tampon)
      if !adresse.isEmpty { resultat.append(adresse) }
    }
    return resultat
  }

  /// Les clés de `fr.correspondance.agent.journal`.
  public enum JournalKey {
    public static let agent = "agent"
    public static let room = "room"
    public static let sender = "sender"
    public static let prompt = "prompt"
    public static let tools = "tools"
    /// La durée du tour, en **millisecondes entières**. Jamais des secondes
    /// décimales : Matrix refuse les flottants, et c'est ce qui a empêché le
    /// journal de s'écrire pendant tout ce temps. Les millisecondes gardent la
    /// précision d'un tour court sans jamais produire de virgule.
    public static let durationMs = "duration_ms"
    public static let tokens = "tokens"
  }

  /// La version courante du schéma de configuration.
  public static let configVersion = 1
}
