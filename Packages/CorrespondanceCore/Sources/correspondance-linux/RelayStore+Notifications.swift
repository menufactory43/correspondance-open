import CorrespondanceCore
import Foundation

/// Les notifications du bureau Linux — par `notify-send`, qui parle à n'importe
/// quel démon de notifications (GNOME, KDE, mako, dunst) sans qu'on se lie à
/// D-Bus depuis un binaire statique.
///
/// La politique est CELLE DU MAC ET DE L'IPHONE, aux mêmes fonctions pures
/// près : `NotificationPolicy` (muet, fil ouvert, message sortant), puis
/// `NotificationGrouping` (une rafale = une notification) avec l'exception
/// `OneTimeCode`. Rien n'est réécrit ici, tout est réutilisé.
@MainActor
extension RelayStore {
  /// À appeler après chaque `/sync` : ce qui vient d'arriver sonne, le reste non.
  func postLocalNotificationsForNewMessages() {
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
  /// besoin d'une bannière par-dessus lui. Le navigateur dit s'il est visible.
  private func isOnScreen(_ conversationID: String) -> Bool {
    guard isWindowVisible else { return false }
    return selectedConversationID == conversationID || focusConversationID == conversationID
  }

  private func post(conversation: Conversation, burst: NotificationBurst) {
    let shown = PushNotification.presentation(
      senderName: nil,
      conversationTitle: conversation.title,
      network: conversation.network,
      text: NotificationGrouping.bodyFR(latest: conversation.preview, count: burst.count)
    )
    var arguments = ["notify-send", "--app-name=Correspondance", "--category=im.received"]
    // La MÊME rafale remplace sa notification au lieu d'en empiler une autre.
    arguments.append("--hint=string:x-dunst-stack-tag:\(burst.key)")
    if let path = conversation.groupPhotoPath, FileManager.default.fileExists(atPath: path) {
      arguments.append("--icon=\(path)")
    }
    arguments.append(shown.title)
    arguments.append(shown.body)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
  }
}
