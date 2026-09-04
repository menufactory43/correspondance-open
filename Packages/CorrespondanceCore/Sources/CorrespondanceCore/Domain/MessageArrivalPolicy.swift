import Foundation

/// Quand un message mérite le geste d'arrivée (l'encre, la plume).
///
/// Un message qui vient d'être écrit arrive ; un message d'hier découvert en
/// ouvrant le fil est déjà vu, il paraît posé. La coupure se fait sur l'heure
/// d'envoi : le fil n'a pas à se souvenir de tout ce qu'il a montré, et un
/// chargement qui complète un fil ne réveille rien.
public enum MessageArrivalPolicy {
  /// Passé ce délai après l'envoi, un message n'est plus « nouveau ».
  public static let freshWindow: TimeInterval = 120

  public static func isNewArrival(sentAt: Date, now: Date = Date()) -> Bool {
    let age = now.timeIntervalSince(sentAt)
    // Une horloge en avance (message daté dans le futur) compte comme « à l'instant ».
    return age < freshWindow
  }
}

/// Ce qui a déjà pris l'encre — par empreinte, pas par identifiant.
///
/// Un envoi paraît d'abord en bulle optimiste (`local-…`), puis la copie du
/// Relais ou de `chat.db` la remplace sous son vrai identifiant. Pour l'œil,
/// c'est le même message ; pour le fil, c'est une rangée qui renaît — et qui
/// se ré-encrait, parfois au milieu du premier geste. Le registre retient
/// les messages qui ont joué et reconnaît leur double : même auteur, même
/// texte (ou même nombre de pièces jointes), envoyé à quelques secondes près.
public final class MessageArrivalLedger {
  private var inked: [ChatMessage] = []

  public init() {}

  /// Ce message, ou son double sous un autre identifiant, a déjà pris l'encre.
  public func hasInked(_ message: ChatMessage, now: Date = Date()) -> Bool {
    prune(now: now)
    return inked.contains { Self.isSameArrival($0, message) }
  }

  /// Le geste joue sur ce message : son double n'aura pas à le rejouer.
  public func remember(_ message: ChatMessage, now: Date = Date()) {
    prune(now: now)
    guard !inked.contains(where: { $0.id == message.id }) else { return }
    inked.append(message)
  }

  public func reset() { inked.removeAll() }

  /// Deux bulles sont le même message si elles ont le même identifiant — ou,
  /// pour un envoi de moi seulement, le même contenu daté à moins de deux
  /// minutes d'écart : la bulle optimiste prend l'heure de l'appareil, sa
  /// copie celle du serveur. Ce qui vient des autres n'a pas de double : un
  /// second « ok » de la même personne est un second message, et il s'encre.
  public static func isSameArrival(_ a: ChatMessage, _ b: ChatMessage) -> Bool {
    if a.id == b.id { return true }
    guard a.isFromMe, b.isFromMe, a.conversationID == b.conversationID else { return false }
    guard abs(a.sentAt.timeIntervalSince(b.sentAt)) < MessageArrivalPolicy.freshWindow else { return false }
    let ta = a.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let tb = b.text.trimmingCharacters(in: .whitespacesAndNewlines)
    if !ta.isEmpty, ta == tb { return true }
    return !a.attachments.isEmpty && a.attachments.count == b.attachments.count
  }

  /// Passé la fenêtre de fraîcheur, un double ne peut plus paraître.
  private func prune(now: Date) {
    inked.removeAll { now.timeIntervalSince($0.sentAt) >= MessageArrivalPolicy.freshWindow }
  }
}
