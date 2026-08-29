import Foundation

/// Décide, sans effet de bord, si un changement de conversation mérite une notification.
/// Pur et `Sendable` : c'est la couche que les tests exercent.
enum NotificationPolicy {
  /// - Parameters:
  ///   - current: l'état après fusion.
  ///   - previous: l'état d'avant. `nil` = fil apparu de nulle part (première sync,
  ///     backfill, changement de filtre) — on ne sonne jamais pour ça.
  ///   - isMuted: le fil est dans `mutedIDs`.
  ///   - isSelected: le fil est celui que l'utilisateur lit à l'instant.
  ///   - alreadyNotifiedAt: dernier `lastMessageAt` déjà notifié pour ce fil.
  static func shouldNotify(
    current: Conversation,
    previous: Conversation?,
    isMuted: Bool,
    isSelected: Bool,
    alreadyNotifiedAt: Date?
  ) -> Bool {
    guard !current.isArchived else { return false }
    // Un message que j'ai envoyé moi-même ne me prévient pas.
    guard !current.lastMessageIsFromMe else { return false }
    guard !isMuted else { return false }
    guard !isSelected else { return false }
    // Un aperçu « catalogue » (« Écrire sur Signal… ») n'est pas un message reçu.
    guard current.hasLivePreview, !current.preview.isEmpty else { return false }
    guard let previous else { return false }
    guard current.lastMessageAt > previous.lastMessageAt else { return false }
    if let alreadyNotifiedAt, current.lastMessageAt <= alreadyNotifiedAt { return false }
    return true
  }
}
