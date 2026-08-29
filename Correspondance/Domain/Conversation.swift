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

  /// Titre encore technique / placeholder — à remplacer dès qu’on a un vrai nom.
  var hasPlaceholderTitle: Bool {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return true }
    if trimmed == id { return true }
    if trimmed == address { return true }
    if trimmed == transportKey { return true }
    if trimmed.hasPrefix("signal-group:") || trimmed.hasPrefix("signal:") || trimmed.hasPrefix("imessage:") {
      return true
    }
    if trimmed.hasPrefix("Groupe") && (trimmed == "Groupe" || trimmed.hasPrefix("Groupe (") || trimmed == "Groupe Signal") {
      return true
    }
    // UUID nu ou numéro seul : pas un libellé humain.
    if trimmed.range(of: #"^[0-9a-fA-F-]{36}$"#, options: .regularExpression) != nil {
      return true
    }
    let digitsOnly = trimmed.filter(\.isNumber)
    let nonDialable = trimmed.filter { !$0.isNumber && !$0.isWhitespace && $0 != "+" && $0 != "-" && $0 != "(" && $0 != ")" && $0 != "." }
    // « +33 6 12 34 56 78 », « 0612345678 » → placeholder à enrichir via Contacts.
    if nonDialable.isEmpty, digitsOnly.count >= 8, digitsOnly.count >= trimmed.filter({ !$0.isWhitespace }).count - 1 {
      return true
    }
    return false
  }

  /// Installe un titre humain si le courant est encore technique / placeholder.
  mutating func preferTitle(_ candidate: String) {
    let next = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !next.isEmpty else { return }
    var probe = self
    probe.title = next
    // Ne jamais installer un titre technique.
    guard !probe.hasPlaceholderTitle else { return }
    // Ne remplacer que si l’existant est mauvais (évite d’écraser un bon nom).
    if hasPlaceholderTitle {
      title = next
    }
  }
}
