import CorrespondanceMatrixClient
import Foundation

/// Un message qui réveille l'agent : de qui, où, ce qu'il demande.
public struct AgentRequest: Sendable, Equatable {
  public var roomID: String
  public var eventID: String
  public var sender: String
  /// Le texte sans le déclencheur. Vide si le propriétaire n'a écrit que `@cc`,
  /// ou s'il n'a envoyé qu'une photo — une image sans légende est une demande.
  public var prompt: String
  public var sentAt: Date
  /// Ce que le message portait en plus du texte. Téléchargé au moment du tour,
  /// jamais ici : reconnaître une demande reste pur, et testable sans réseau.
  public var attachments: [AgentAttachment]
  /// Ce tour vient d'un autre agent, chargé par un propriétaire : la réponse
  /// portera le drapeau `AgentWire.delegatedKey`, et personne n'y répondra.
  public var delegated: Bool
  /// Pourquoi ce tour existe — et donc où va sa réponse.
  public var kind: Kind

  /// Les genres de tour. Le genre décide de la sortie, pas le mode du salon :
  /// une suggestion ne parle jamais, un tour piloté parle au nom du propriétaire.
  public enum Kind: String, Sendable {
    /// On a parlé à l'agent : la réponse suit le mode du salon.
    case reply
    /// Un tiers a écrit, et le salon est réglé sur *Propose* : la réponse est
    /// **toujours** une proposition (`ProposalKind.suggest`), après 3 s sans
    /// que le propriétaire n'ait répondu lui-même.
    case suggest
    /// Un tiers a écrit, et le salon est en `pilot` : l'agent répond seul, dans
    /// le cadre, ou passe la main (`<hors-cadre>` → proposition `handover`).
    case pilot
    /// Le point du matin : une proposition `summary` dans le fil de l'agent.
    case summary
  }

  public init(
    roomID: String,
    eventID: String,
    sender: String,
    prompt: String,
    sentAt: Date,
    attachments: [AgentAttachment] = [],
    delegated: Bool = false,
    kind: Kind = .reply
  ) {
    self.roomID = roomID
    self.eventID = eventID
    self.sender = sender
    self.prompt = prompt
    self.sentAt = sentAt
    self.attachments = attachments
    self.delegated = delegated
    self.kind = kind
  }
}

/// Faut-il nommer l'agent pour lui parler dans ce salon ?
///
/// Pur, parce que c'est une règle et qu'une règle se teste : la friction du
/// « @cc » à chaque ligne n'a de sens que là où d'autres conversations
/// existent. Dans un salon qui est *à lui* — un tête-à-tête ouvert par l'app,
/// sa console — elle n'en a aucun.
public enum MentionPolicy {
  /// - `binding` : ce que la config dit de ce salon, si elle en dit quelque
  ///   chose. Elle a le dernier mot, dans un sens comme dans l'autre.
  /// - `isTeteATete` : le salon porte le marqueur de l'app (`kind: agent`).
  /// - `isConsole` : c'est la console de cet agent.
  ///
  /// Partout ailleurs — la note à soi où l'agent est invité, un fil bridgé —
  /// la mention reste **obligatoire** : sans elle, chaque message qu'un
  /// propriétaire écrit à quelqu'un d'autre réveillerait l'agent.
  public static func requiresTrigger(
    binding: AgentConfig.RoomBinding?,
    isTeteATete: Bool,
    isConsole: Bool
  ) -> Bool {
    if let choix = binding?.mention { return choix }
    return !isTeteATete && !isConsole
  }
}

/// Reconnaît un déclencheur dans un event de timeline. Pur : c'est ce que les tests exercent.
public enum Trigger {
  /// `@cc résume` → `résume`. `@CC, résume` → `résume`. `bonjour @cc` → `nil` :
  /// le déclencheur ouvre le message, sinon on ne réagit pas — un `@cc` cité
  /// au milieu d'une phrase n'est pas un ordre.
  public static func prompt(in body: String, trigger: String) -> String? {
    let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.count >= trigger.count else { return nil }
    let head = String(text.prefix(trigger.count))
    guard head.compare(trigger, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame else { return nil }
    var rest = Substring(text.dropFirst(trigger.count))
    // Le déclencheur doit être un mot entier : `@ccc` n'est pas `@cc`.
    if let first = rest.first, !(first.isWhitespace || first == "," || first == ":" || first == "\n") {
      return nil
    }
    while let first = rest.first, first.isWhitespace || first == "," || first == ":" {
      rest = rest.dropFirst()
    }
    return String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Les fantômes des ponts : `@whatsapp_33…`, `@signalbot`, `@instagram_…`.
  /// Ils ne déclenchent **jamais**, même inscrits par erreur dans `owners` —
  /// sinon un correspondant distant piloterait l'agent depuis son réseau, avec
  /// tous ses outils. C'est une des trois choses qui bornent le risque depuis
  /// qu'on donne la pleine permission (cf. `docs/PLAN-relais-agents.md`).
  static let bridgePrefixes = [
    "whatsapp", "signal", "telegram", "instagram", "messenger", "facebook", "meta",
    "discord", "slack", "twitter", "gmessages", "imessage", "linkedin",
  ]

  public static func isBridgeGhost(_ userID: String) -> Bool {
    let localpart = userID.hasPrefix("@") ? String(userID.dropFirst()) : userID
    let name = localpart.split(separator: ":").first.map(String.init)?.lowercased() ?? ""
    return bridgePrefixes.contains { prefix in
      name == prefix || name == "\(prefix)bot" || name.hasPrefix("\(prefix)_")
    }
  }

  /// L'event est-il un ordre pour l'agent ? Il faut un `m.room.message` texte,
  /// d'un propriétaire, postérieur au démarrage (pas de rejouage de l'historique
  /// au premier `/sync`), qui commence par le déclencheur.
  ///
  /// `requiresTrigger: false` : un tête-à-tête marqué par l'app
  /// (`AgentWire.conversationType`, `kind: agent`) — tout message d'un
  /// propriétaire est une demande, et un déclencheur en tête, s'il y est, se
  /// retire. Le reste ne change pas : ni fantôme, ni tiers, ni historique.
  public static func request(
    from event: MatrixEvent,
    roomID: String,
    config: AgentConfig,
    notBefore: Date,
    requiresTrigger: Bool = true
  ) -> AgentRequest? {
    guard Self.carriesText(event),
          let eventID = event.eventID,
          let sender = event.sender,
          !isBridgeGhost(sender),
          config.owners.contains(sender),
          event.sentAt >= notBefore
    else { return nil }
    // Une modification (`m.replace`) ou une réponse citée : on lit le vrai corps.
    // Une photo, un vocal, un PDF : le corps est la **légende** (MSC2530), et
    // c'est là que se trouve le déclencheur. Refuser ces msgtypes revenait à
    // ne pas se réveiller du tout — pas même pour dire qu'on ne sait pas lire.
    let msgtype = event.content?.string(at: "msgtype") ?? "m.text"
    let media = AgentAttachment.mediaTypes.contains(msgtype)
    guard msgtype == "m.text" || msgtype == "m.notice" || media else { return nil }
    let attachments = [AgentAttachment.read(from: event.content, msgtype: msgtype)].compactMap { $0 }
    guard !media || !attachments.isEmpty else { return nil }
    let body = media
      ? AgentAttachment.caption(from: event.content, msgtype: msgtype)
      : event.content?.string(at: "m.new_content.body")
        ?? Trigger.stripReplyFallback(event.content?.string(at: "body") ?? "")
    let prompt: String
    if let mentionne = Self.prompt(in: body, trigger: config.trigger) {
      prompt = mentionne
    } else if !requiresTrigger {
      prompt = body.trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
      return nil
    }
    // Une pièce jointe tient lieu de demande : « regarde » est dans le geste.
    guard !prompt.isEmpty || !attachments.isEmpty else { return nil }
    return AgentRequest(
      roomID: roomID, eventID: eventID, sender: sender, prompt: prompt,
      sentAt: event.sentAt, attachments: attachments
    )
  }

  /// Un message ordinaire, ou un **aparté** (`AgentWire.asideType`) : ce que
  /// l'app envoie à la place d'un message quand on nomme un agent devant des
  /// humains. Même corps, même déclencheur — seul le type change, pour que
  /// les ponts ne le relaient pas. Pour l'agent, les deux sont des ordres.
  public static func carriesText(_ event: MatrixEvent) -> Bool {
    event.type == "m.room.message" || event.type == AgentWire.asideType
  }

  // MARK: - Proposer sans qu'on demande, répondre seul

  /// L'instruction d'une suggestion. Fixe : ce que le tiers a écrit vient
  /// **après**, cité, comme une donnée.
  public static let promptDeSuggestion =
    "Propose, en une ou deux phrases, la réponse que le propriétaire enverrait à ce dernier message, "
      + "dans son ton. Réponds uniquement par le texte à envoyer."

  /// Ce qu'un tour piloté répond quand le message sort du cadre — suivi d'une
  /// phrase qui dit pourquoi. `Pilotage.lire` relit ce protocole.
  public static let horsCadre = "<hors-cadre>"

  /// L'instruction d'un tour piloté : répondre dans le cadre, ou dire
  /// exactement `<hors-cadre>` et pourquoi.
  public static func promptDePilotage(frame: String?) -> String {
    let cadre = frame?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let cadreDit = cadre.isEmpty ? "aucun cadre n'a été donné : tout message est hors cadre" : cadre
    return "Tu réponds au nom du propriétaire, dans ce cadre, et seulement dans ce cadre : « \(cadreDit) ». "
      + "Si le message sort du cadre, réponds exactement `\(horsCadre)` suivi d'une phrase qui dit pourquoi. "
      + "Sinon réponds uniquement par le texte à envoyer."
  }

  /// Un message **d'un tiers** qui déclenche un tour sans qu'on nomme l'agent :
  /// dans un salon réglé sur *Propose* (`suggest: always`, ou `keywords` et un
  /// des mots est dans le corps), une suggestion ; dans un salon en `pilot`,
  /// un tour piloté. `nil` partout ailleurs.
  ///
  /// Le tiers, ici, c'est **le fantôme de pont** : c'est lui qui écrit depuis
  /// WhatsApp, et c'est à lui qu'on répond. Ce qu'on ne prend jamais pour un
  /// tiers : un propriétaire (il parle à quelqu'un, pas à l'agent), l'agent
  /// lui-même, un autre agent (`peers`) — et un message déjà piloté, d'où
  /// qu'il vienne : deux agents en `pilot` se répondraient sans fin.
  public static func suggestion(
    from event: MatrixEvent,
    roomID: String,
    config: AgentConfig,
    notBefore: Date
  ) -> AgentRequest? {
    guard event.type == "m.room.message",
          let eventID = event.eventID,
          let sender = event.sender,
          event.sentAt >= notBefore,
          !config.owners.contains(sender),
          sender != config.botUserID,
          !config.peers.contains(sender),
          !AgentEvents.isPiloted(event.content),
          let binding = config.rooms[roomID]
    else { return nil }
    let msgtype = event.content?.string(at: "msgtype") ?? "m.text"
    guard msgtype == "m.text" else { return nil }
    let body = (event.content?.string(at: "m.new_content.body")
      ?? stripReplyFallback(event.content?.string(at: "body") ?? ""))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else { return nil }

    let kind: AgentRequest.Kind
    let instruction: String
    if binding.mode == .pilot {
      kind = .pilot
      instruction = promptDePilotage(frame: binding.frame)
    } else {
      switch binding.suggest {
      case AgentWire.Suggest.always:
        kind = .suggest
      case AgentWire.Suggest.keywords:
        guard containsKeyword(body, among: binding.keywords ?? []) else { return nil }
        kind = .suggest
      default:
        return nil
      }
      instruction = promptDeSuggestion
    }
    let prompt = instruction + "\n\nDernier message, de \(sender) : « \(body) »"
    return AgentRequest(
      roomID: roomID, eventID: eventID, sender: sender, prompt: prompt,
      sentAt: event.sentAt, kind: kind
    )
  }

  /// Un des mots est-il dans le corps — **mot entier**, sans égard à la casse ?
  /// « devis » compte dans « ton devis est prêt », pas dans « devise ».
  public static func containsKeyword(_ body: String, among keywords: [String]) -> Bool {
    let mots = tokens(body)
    guard !mots.isEmpty else { return false }
    let texte = " " + mots.joined(separator: " ") + " "
    return keywords.contains { mot in
      let cle = tokens(mot).joined(separator: " ")
      return !cle.isEmpty && texte.contains(" " + cle + " ")
    }
  }

  private static func tokens(_ texte: String) -> [String] {
    texte.lowercased()
      .split { !($0.isLetter || $0.isNumber) }
      .map(String.init)
  }

  /// Une suggestion est **dépassée** si le propriétaire a écrit dans le salon
  /// depuis le message du tiers : il a répondu lui-même, l'agent se tait.
  public static func suggestionDepassee(_ request: AgentRequest, derniereActiviteProprietaire: Date?) -> Bool {
    guard let derniere = derniereActiviteProprietaire else { return false }
    return derniere > request.sentAt
  }

  /// Le repli `> <@qui> …` que les clients posent avant une réponse citée.
  static func stripReplyFallback(_ body: String) -> String {
    guard body.hasPrefix("> ") else { return body }
    var lines = body.split(separator: "\n", omittingEmptySubsequences: false)[...]
    while let first = lines.first, first.hasPrefix("> ") { lines = lines.dropFirst() }
    while let first = lines.first, first.isEmpty { lines = lines.dropFirst() }
    return lines.joined(separator: "\n")
  }
}
