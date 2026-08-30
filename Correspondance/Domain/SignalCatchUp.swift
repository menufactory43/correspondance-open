import Foundation

/// Recompte les non-lus Signal au rattrapage, sans effet de bord.
///
/// `signal-cli receive` ne descend les messages que quand l'app tourne : ceux
/// arrivés Mac endormi n'apparaissent qu'au lancement suivant, et le catalogue
/// du bridge les rend toujours avec `unreadCount: 0`. On ne peut pas non plus
/// se contenter d'un delta « nombre de messages avant / après » : au premier
/// lancement le cache mémoire est vide avant l'appel et plein après, ce qui
/// compterait tout l'historique comme non-lu, et un non-lu existant serait
/// perdu à chaque redémarrage.
///
/// D'où un **recompte absolu** contre un marqueur « dernier message vu » par
/// conversation, persisté côté `InboxStore` : le calcul est idempotent (deux
/// Actualiser d'affilée ne doublent pas le badge) et le non-lu survit à la
/// fermeture de l'app.
enum SignalCatchUp {
  /// Non-lus par conversation, à la date du marqueur.
  ///
  /// - Parameters:
  ///   - messagesByConversation: l'instantané du cache mémoire du bridge.
  ///   - lastSeenAt: le marqueur persisté. `nil` = rien n'a jamais été enregistré
  ///     (première exécution après ce correctif, ou toute première sync) : on ne
  ///     fabrique alors aucun non-lu, c'est à l'appelant d'amorcer le marqueur.
  ///     Même philosophie que le `previous == nil` de `NotificationPolicy`.
  static func unreadCounts(
    messagesByConversation: [String: [ChatMessage]],
    lastSeenAt: [String: Date]?
  ) -> [String: Int] {
    guard let lastSeenAt else { return [:] }

    var counts: [String: Int] = [:]
    for (conversationID, messages) in messagesByConversation {
      // Un fil absent du marqueur est un fil apparu depuis le dernier passage
      // (nouveau groupe) : tous ses entrants comptent.
      let seen = lastSeenAt[conversationID] ?? .distantPast
      // Comparaison stricte, comme `NotificationPolicy` : le message qui a servi
      // à poser le marqueur est, par définition, déjà vu.
      let unread = messages.reduce(into: 0) { total, message in
        guard !message.isFromMe, message.sentAt > seen else { return }
        total += 1
      }
      if unread > 0 { counts[conversationID] = unread }
    }
    return counts
  }

  /// Marqueur d'amorçage : tout ce qui est déjà là est réputé vu.
  ///
  /// On prend le dernier message quel qu'en soit l'auteur — un message de moi
  /// marque le fil comme lu tout autant qu'un message reçu.
  static func seededLastSeen(
    messagesByConversation: [String: [ChatMessage]]
  ) -> [String: Date] {
    var seeds: [String: Date] = [:]
    for (conversationID, messages) in messagesByConversation {
      guard let newest = messages.map(\.sentAt).max() else { continue }
      seeds[conversationID] = newest
    }
    return seeds
  }
}
