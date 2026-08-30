import AppKit
import Foundation

/// Ce qu'une fenêtre détachée retient d'une fois sur l'autre : où elle était
/// posée, et si elle flottait au-dessus du reste.
///
/// Un cadre par fil : rouvrir une conversation la retrouve à sa place, pas au
/// centre de l'écran. Rien n'est deviné — un cadre illisible est un cadre
/// absent, et la fenêtre reprend sa taille par défaut.
enum DetachedWindowState {
  static func frameKey(for conversationID: String) -> String {
    "detached.frame.\(conversationID)"
  }

  static func pinnedKey(for conversationID: String) -> String {
    "detached.pinned.\(conversationID)"
  }

  /// Réglage global : une notification cliquée ouvre-t-elle une fenêtre
  /// détachée plutôt que l'inbox ? Éteint par défaut.
  static let notificationsOpenDetachedKey = "detached.notifications.openDetached"

  // MARK: - Cadres

  static func saveFrame(_ frame: NSRect, for conversationID: String, in defaults: UserDefaults = .standard) {
    // Une fenêtre sans surface n'est pas une position : ne rien retenir vaut
    // mieux que retenir un point.
    guard frame.width >= 1, frame.height >= 1 else { return }
    defaults.set(NSStringFromRect(frame), forKey: frameKey(for: conversationID))
  }

  static func frame(for conversationID: String, in defaults: UserDefaults = .standard) -> NSRect? {
    guard let raw = defaults.string(forKey: frameKey(for: conversationID)) else { return nil }
    let rect = NSRectFromString(raw)
    guard rect.width >= 1, rect.height >= 1 else { return nil }
    return rect
  }

  static func forgetFrame(for conversationID: String, in defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: frameKey(for: conversationID))
  }

  // MARK: - Épingle

  static func isPinned(_ conversationID: String, in defaults: UserDefaults = .standard) -> Bool {
    defaults.bool(forKey: pinnedKey(for: conversationID))
  }

  static func setPinned(_ pinned: Bool, for conversationID: String, in defaults: UserDefaults = .standard) {
    if pinned {
      defaults.set(true, forKey: pinnedKey(for: conversationID))
    } else {
      defaults.removeObject(forKey: pinnedKey(for: conversationID))
    }
  }

  // MARK: - Notifications

  static func notificationsOpenDetached(in defaults: UserDefaults = .standard) -> Bool {
    defaults.bool(forKey: notificationsOpenDetachedKey)
  }

  static func setNotificationsOpenDetached(_ value: Bool, in defaults: UserDefaults = .standard) {
    defaults.set(value, forKey: notificationsOpenDetachedKey)
  }
}
