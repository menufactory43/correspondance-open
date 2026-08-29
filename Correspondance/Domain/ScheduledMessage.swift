import Foundation

/// Un message écrit maintenant, qui partira plus tard — tant que l'app tourne.
///
/// Modèle calqué sur le « Send Later » de Beeper : une date d'envoi, et
/// l'option « seulement s'il n'a pas répondu d'ici là », qui fait du message
/// une relance qui s'efface d'elle-même si l'autre a parlé entre-temps.
struct ScheduledMessage: Codable, Identifiable, Sendable, Equatable {
  let id: String
  let conversationID: String
  var text: String
  var attachmentPaths: [String]
  /// Citation (⌘R) posée au moment de programmer — résolue à l'envoi si le
  /// message est encore dans le fil.
  var replyToMessageID: String?
  var sendAt: Date
  /// Relance conditionnelle : à l'échéance, on n'envoie que si aucun message
  /// entrant n'est arrivé dans ce fil depuis la programmation.
  var onlyIfNoReply: Bool
  let createdAt: Date
  /// Échec du dernier envoi à l'échéance — le message reste, avec sa raison.
  var lastError: String?

  init(
    id: String = UUID().uuidString,
    conversationID: String,
    text: String,
    attachmentPaths: [String] = [],
    replyToMessageID: String? = nil,
    sendAt: Date,
    onlyIfNoReply: Bool = false,
    createdAt: Date = Date(),
    lastError: String? = nil
  ) {
    self.id = id
    self.conversationID = conversationID
    self.text = text
    self.attachmentPaths = attachmentPaths
    self.replyToMessageID = replyToMessageID
    self.sendAt = sendAt
    self.onlyIfNoReply = onlyIfNoReply
    self.createdAt = createdAt
    self.lastError = lastError
  }

  func isDue(at now: Date) -> Bool { sendAt <= now }

  /// Texte affiché dans le fil et la liste (une photo seule a droit à un mot).
  var displayText: String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty, !attachmentPaths.isEmpty { return "📷 Photo" }
    return trimmed
  }
}

/// Réglage « envoyer plus tard » attaché au composer, avant que le message
/// n'existe : l'équivalent du `sendLaterConfig` de Beeper.
struct SendLaterConfig: Equatable, Sendable {
  var sendAt: Date
  var onlyIfNoReply: Bool = false
}

/// Ce que le sélecteur « Quand ? » vise : le brouillon, ou un message à déplacer.
enum SendLaterPickerTarget: Equatable, Sendable {
  case compose
  case reschedule(String)
}
