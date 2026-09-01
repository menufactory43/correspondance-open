import CorrespondanceCore
import Foundation
import UIKit
import UserNotifications

/// Les notifications LOCALES de l'iPhone — celles que l'app pose elle-même,
/// depuis sa boucle `/sync`.
///
/// Elles ne remplacent pas le push : le push est ce qui réveille un téléphone
/// éteint, et il passe par le Relais (pusher → Sygnal → APNs). Elles couvrent
/// ce que le push ne couvre pas — l'app ouverte sur un autre fil, ou revenue
/// au premier plan il y a trente secondes — et elles couvrent surtout le cas
/// où la passerelle du Relais ne répond pas : mieux vaut une notification que
/// l'app pose en tournant que pas de notification du tout.
///
/// La politique est CELLE DU MAC, aux mêmes fonctions pures près :
/// `NotificationPolicy` (muet, fil ouvert, message sortant), puis
/// `NotificationGrouping` (une rafale = une notification) avec l'exception
/// `OneTimeCode`. Rien n'est réécrit ici, tout est réutilisé.
@MainActor
extension RelayStore {
  /// À appeler après chaque `/sync` : ce qui vient d'arriver sonne, le reste non.
  func postLocalNotificationsForNewMessages() {
    guard !isDemo else { return }
    openPendingNotificationIfPossible()
    let baseline = notificationBaseline
    defer {
      notificationBaseline = Dictionary(conversations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }
    // Le premier passage POSE la ligne de flottaison sans rien annoncer : un
    // rattrapage de trente messages au lancement n'est pas trente arrivées.
    guard isNotificationPrimed else {
      isNotificationPrimed = true
      for conversation in conversations {
        lastNotifiedAt[conversation.id] = conversation.lastMessageAt
      }
      return
    }

    for conversation in conversations {
      guard NotificationPolicy.shouldNotify(
        current: conversation,
        previous: baseline[conversation.id],
        isMuted: isMuted(conversation.id),
        isSelected: isOnScreen(conversation.id),
        alreadyNotifiedAt: lastNotifiedAt[conversation.id]
      ) else { continue }
      lastNotifiedAt[conversation.id] = conversation.lastMessageAt
      notificationSequence += 1
      let burst = NotificationGrouping.extend(
        notificationBursts[conversation.id],
        conversationID: conversation.id,
        at: Date(),
        isUrgent: OneTimeCode.looksLikeCode(conversation.preview),
        sequence: notificationSequence
      )
      notificationBursts[conversation.id] = burst
      post(conversation: conversation, burst: burst)
    }
  }

  /// Ce fil est-il sous les yeux ? Un message qu'on regarde arriver n'a pas
  /// besoin d'une bannière par-dessus lui.
  private func isOnScreen(_ conversationID: String) -> Bool {
    guard UIApplication.shared.applicationState == .active else { return false }
    return selectedConversationID == conversationID || focusConversationID == conversationID
  }

  private func post(conversation: Conversation, burst: NotificationBurst) {
    let shown = PushNotification.presentation(
      senderName: nil,
      conversationTitle: conversation.title,
      network: conversation.network,
      text: NotificationGrouping.bodyFR(latest: conversation.preview, count: burst.count)
    )
    let content = UNMutableNotificationContent()
    content.title = shown.title
    content.body = shown.body
    content.sound = .default
    content.threadIdentifier = conversation.id
    content.userInfo = [RelayStore.notificationConversationKey: conversation.id]
    // La MÊME identité pendant toute la rafale : la notification qui arrive
    // remplace la précédente au lieu d'en empiler une deuxième.
    UNUserNotificationCenter.current().add(
      UNNotificationRequest(identifier: burst.key, content: content, trigger: nil)
    )
  }

  /// La clé qui porte le fil dans une notification locale. `nonisolated` : le
  /// délégué de `UserNotifications` la lit hors du processus principal.
  nonisolated static let notificationConversationKey = "conversationID"

  /// Le fil d'un salon, tel qu'une notification distante le nomme. Le push ne
  /// connaît que `!abc:relais` ; nous parlons en `whatsapp:!abc:relais`.
  func conversationID(ofRoom roomID: String) -> String? {
    conversations.first { Self.relayRoomID(ofConversation: $0.id) == roomID }?.id
  }

  /// Ouvre le fil qu'une notification désigne — au retour dans l'app.
  func openConversationFromNotification(_ conversationID: String) {
    scope = .inbox
    selectedConversationID = conversationID
    Task { await open(conversationID: conversationID) }
  }

  /// Une notification touchée à froid arrive avant le premier `/sync` : le
  /// salon qu'elle nomme n'est encore dans aucune liste. Il attend ici, et
  /// chaque passage de synchronisation retente jusqu'à le trouver.
  func openPendingNotificationIfPossible() {
    guard let roomID = NotificationHandler.pendingRoomID,
          let conversationID = conversationID(ofRoom: roomID)
    else { return }
    NotificationHandler.pendingRoomID = nil
    openConversationFromNotification(conversationID)
  }
}
