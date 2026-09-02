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

  public init(
    roomID: String,
    eventID: String,
    sender: String,
    prompt: String,
    sentAt: Date,
    attachments: [AgentAttachment] = []
  ) {
    self.roomID = roomID
    self.eventID = eventID
    self.sender = sender
    self.prompt = prompt
    self.sentAt = sentAt
    self.attachments = attachments
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
    guard event.type == "m.room.message",
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

  /// Le repli `> <@qui> …` que les clients posent avant une réponse citée.
  static func stripReplyFallback(_ body: String) -> String {
    guard body.hasPrefix("> ") else { return body }
    var lines = body.split(separator: "\n", omittingEmptySubsequences: false)[...]
    while let first = lines.first, first.hasPrefix("> ") { lines = lines.dropFirst() }
    while let first = lines.first, first.isEmpty { lines = lines.dropFirst() }
    return lines.joined(separator: "\n")
  }
}
