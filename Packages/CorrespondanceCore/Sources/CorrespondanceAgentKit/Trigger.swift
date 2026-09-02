import CorrespondanceMatrixClient
import Foundation

/// Un message qui réveille l'agent : de qui, où, ce qu'il demande.
public struct AgentRequest: Sendable, Equatable {
  public var roomID: String
  public var eventID: String
  public var sender: String
  /// Le texte sans le déclencheur. Vide si le propriétaire n'a écrit que `@cc`.
  public var prompt: String
  public var sentAt: Date

  public init(roomID: String, eventID: String, sender: String, prompt: String, sentAt: Date) {
    self.roomID = roomID
    self.eventID = eventID
    self.sender = sender
    self.prompt = prompt
    self.sentAt = sentAt
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
    let msgtype = event.content?.string(at: "msgtype") ?? "m.text"
    guard msgtype == "m.text" || msgtype == "m.notice" else { return nil }
    let body = event.content?.string(at: "m.new_content.body")
      ?? Trigger.stripReplyFallback(event.content?.string(at: "body") ?? "")
    let prompt: String
    if let mentionne = Self.prompt(in: body, trigger: config.trigger) {
      prompt = mentionne
    } else if !requiresTrigger {
      prompt = body.trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
      return nil
    }
    guard !prompt.isEmpty else { return nil }
    return AgentRequest(roomID: roomID, eventID: eventID, sender: sender, prompt: prompt, sentAt: event.sentAt)
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
