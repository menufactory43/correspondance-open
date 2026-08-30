import AppKit
import Foundation
import UserNotifications

/// Notifications système + pastille du Dock.
///
/// macOS ne demande **aucune** clé d'usage dans `Info.plist` pour `UserNotifications` :
/// l'autorisation se demande à l'exécution (`requestAuthorization`). La seule condition
/// est que l'app soit empaquetée et signée — c'est le cas (Team ID stable dans `project.yml`).
@MainActor
final class NotificationService: NSObject {
  static let shared = NotificationService()

  /// Appelé quand l'utilisateur clique une notification : sélectionne le fil.
  var onOpenConversation: ((String) -> Void)?

  /// Réponse écrite dans la notification elle-même : le message part sans que
  /// rien ne s'ouvre à l'écran.
  var onQuickReply: ((String, String) -> Void)?

  /// « Ouvrir en réponse rapide » : le panneau paraît sur ce fil.
  var onOpenQuickReply: ((String) -> Void)?

  private(set) var authorizationStatusFR = "Notifications : état inconnu."
  private(set) var isAuthorized = false
  /// `false` tant que l'app n'est pas empaquetée (aperçus SwiftUI, tests) : on ne touche
  /// pas à `UNUserNotificationCenter`, qui lève une exception Objective-C hors bundle.
  private let isAvailable: Bool

  nonisolated private static let conversationIDKey = "conversationID"
  /// Une seule catégorie : « un message est arrivé », avec ses deux gestes.
  nonisolated static let messageCategory = "correspondance.message"
  nonisolated static let replyAction = "correspondance.reply"
  nonisolated static let quickReplyAction = "correspondance.quickReply"

  private override init() {
    isAvailable = Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    super.init()
    guard isAvailable else { return }
    UNUserNotificationCenter.current().delegate = self
  }

  // MARK: - Autorisation

  /// Demande l'autorisation si elle n'a jamais été posée ; rafraîchit l'état sinon.
  /// Sans effet (hors mise à jour du libellé) si l'utilisateur a déjà refusé.
  func requestAuthorization() async {
    guard isAvailable else {
      authorizationStatusFR = "Notifications : indisponibles hors app empaquetée."
      return
    }
    let center = UNUserNotificationCenter.current()
    registerCategories(on: center)
    let settings = await center.notificationSettings()
    switch settings.authorizationStatus {
    case .notDetermined:
      let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
      isAuthorized = granted
      authorizationStatusFR = granted
        ? "Notifications autorisées."
        : "Notifications refusées — autorise Correspondance dans Réglages Système → Notifications."
    case .denied:
      isAuthorized = false
      authorizationStatusFR = "Notifications refusées — autorise Correspondance dans Réglages Système → Notifications."
    case .authorized, .provisional, .ephemeral:
      isAuthorized = true
      authorizationStatusFR = "Notifications autorisées."
    @unknown default:
      isAuthorized = false
      authorizationStatusFR = "Notifications : état inconnu."
    }
  }

  /// Répondre depuis la bannière, ou l'ouvrir en réponse rapide. Deux gestes,
  /// pas un de plus : une notification n'est pas une fenêtre.
  private func registerCategories(on center: UNUserNotificationCenter) {
    let reply = UNTextInputNotificationAction(
      identifier: Self.replyAction,
      title: "Répondre",
      options: [],
      textInputButtonTitle: "Envoyer",
      textInputPlaceholder: "Répondre…"
    )
    let quick = UNNotificationAction(
      identifier: Self.quickReplyAction,
      title: "Ouvrir en réponse rapide",
      options: []
    )
    let category = UNNotificationCategory(
      identifier: Self.messageCategory,
      actions: [reply, quick],
      intentIdentifiers: [],
      options: []
    )
    center.setNotificationCategories([category])
  }

  func openNotificationSettings() {
    let urls = [
      "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
      "x-apple.systempreferences:com.apple.preference.notifications",
    ]
    for raw in urls {
      if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
    }
  }

  // MARK: - Émission

  /// Une notification par message entrant. `conversationID` sert d'identifiant de thread :
  /// macOS empile les notifications d'un même fil au lieu d'en accumuler dix.
  func postIncoming(conversationID: String, title: String, networkLabel: String, body: String) {
    guard isAvailable, isAuthorized else { return }
    let content = UNMutableNotificationContent()
    content.title = title
    content.subtitle = networkLabel
    content.body = body
    content.sound = .default
    content.threadIdentifier = conversationID
    content.categoryIdentifier = Self.messageCategory
    content.userInfo = [Self.conversationIDKey: conversationID]

    let request = UNNotificationRequest(
      identifier: "\(conversationID)#\(UUID().uuidString)",
      content: content,
      trigger: nil
    )
    UNUserNotificationCenter.current().add(request)
  }

  // MARK: - Pastille du Dock

  /// `count <= 0` efface la pastille (jamais « 0 » affiché).
  func updateDockBadge(count: Int) {
    // `NSApp` est un `NSApplication!` encore nil très tôt au lancement (le store hydrate
    // son cache avant que l'app ne soit installée) : `.shared` l'instancie sans risque.
    NSApplication.shared.dockTile.badgeLabel = count > 0 ? String(count) : nil
  }
}

extension NotificationService: UNUserNotificationCenterDelegate {
  /// Clic sur une notification → fenêtre au premier plan et fil sélectionné.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse
  ) async {
    let userInfo = response.notification.request.content.userInfo
    guard let conversationID = userInfo[NotificationService.conversationIDKey] as? String else { return }
    // Répondre depuis la bannière : rien ne s'ouvre, le message part.
    if let textResponse = response as? UNTextInputNotificationResponse {
      let text = textResponse.userText
      await MainActor.run {
        NotificationService.shared.onQuickReply?(conversationID, text)
      }
      return
    }
    if response.actionIdentifier == NotificationService.quickReplyAction {
      await MainActor.run {
        NotificationService.shared.onOpenQuickReply?(conversationID)
      }
      return
    }
    await MainActor.run {
      NSApplication.shared.activate(ignoringOtherApps: true)
      NSApplication.shared.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
      NotificationService.shared.onOpenConversation?(conversationID)
    }
  }

  /// L'app au premier plan ne notifie pas ce que l'utilisateur regarde déjà :
  /// on laisse quand même la bannière si la fenêtre n'est pas active.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    let isActive = await MainActor.run { NSApplication.shared.isActive }
    return isActive ? [] : [.banner, .sound]
  }
}
