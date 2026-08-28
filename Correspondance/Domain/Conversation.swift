import Foundation

struct Conversation: Identifiable, Hashable, Sendable {
  let id: String
  let network: MessageNetwork
  /// Identifiant réseau (handle, chat guid, group id…).
  let address: String
  var title: String
  var preview: String
  var lastMessageAt: Date
  var unreadCount: Int
  var isArchived: Bool
  /// Clé chat.db / bridge pour l’envoi.
  var transportKey: String
  /// Groupe Signal (envoi via `-g`).
  var isGroup: Bool

  var hasUnread: Bool { unreadCount > 0 }

  var rowSystemImage: String {
    if network == .signal && isGroup { return "person.3.fill" }
    return network.systemImage
  }

  /// Preview « catalogue » sans vrai message reçu.
  var hasLivePreview: Bool {
    let placeholders: Set<String> = [
      "Groupe Signal",
      "Écrire sur Signal…",
      "Signal",
    ]
    return !placeholders.contains(preview)
  }
}
