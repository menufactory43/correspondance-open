import Foundation

/// Décide, sans effet de bord, si un changement de conversation mérite une notification.
/// Pur et `Sendable` : c'est la couche que les tests exercent.
public enum NotificationPolicy {
  /// Au-delà, un message « entrant » est de l'historique. Dix minutes : assez
  /// pour un Relais qui rattrape un `/sync` en retard, trop peu pour un
  /// rapatriement, dont les messages datent d'heures ou de semaines.
  public static let maxAge: TimeInterval = 10 * 60

  /// - Parameters:
  ///   - current: l'état après fusion.
  ///   - previous: l'état d'avant. `nil` = fil apparu de nulle part (première sync,
  ///     backfill, changement de filtre) — on ne sonne jamais pour ça.
  ///   - isMuted: le fil est dans `mutedIDs`.
  ///   - isSelected: le fil est celui que l'utilisateur lit à l'instant.
  ///   - alreadyNotifiedAt: dernier `lastMessageAt` déjà notifié pour ce fil.
  ///   - now: l'heure qu'il est — injectable pour les tests.
  public static func shouldNotify(
    current: Conversation,
    previous: Conversation?,
    isMuted: Bool,
    isSelected: Bool,
    alreadyNotifiedAt: Date?,
    now: Date = Date()
  ) -> Bool {
    guard !current.isArchived else { return false }
    // Un message qui arrive vieux n'est pas un message qui arrive : c'est un
    // pont qui rapatrie l'historique d'un compte qu'on vient de connecter — un
    // salon, puis ses cinquante derniers messages, un par un, avec leur date
    // d'origine. Chacun faisait « bouger » le fil, donc une bannière, pour un
    // message de trois semaines. Il remplit le fil et compte dans les non-lus ;
    // il ne sonne pas. C'est la règle de Beeper aussi.
    guard now.timeIntervalSince(current.lastMessageAt) < maxAge else { return false }
    // Un message que j'ai envoyé moi-même ne me prévient pas.
    guard !current.lastMessageIsFromMe else { return false }
    // Muet veut dire « plus de notifications », pas « plus rien ». Être nommé,
    // ou se voir répondre, passe outre la sourdine — c'est la règle de Signal
    // et de Slack, et celle de Matrix, dont les règles de mention priment sur
    // la règle de salon qui porte la sourdine.
    guard !isMuted || current.lastMessageIsPersonal else { return false }
    guard !isSelected else { return false }
    // Un aperçu « catalogue » (« Écrire sur Signal… ») n'est pas un message reçu.
    guard current.hasLivePreview, !current.preview.isEmpty else { return false }
    guard let previous else { return false }
    guard current.lastMessageAt > previous.lastMessageAt else { return false }
    if let alreadyNotifiedAt, current.lastMessageAt <= alreadyNotifiedAt { return false }
    return true
  }
}
