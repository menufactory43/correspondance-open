import Foundation

struct MessageAttachment: Identifiable, Hashable, Codable, Sendable {
  var id: String
  var contentType: String
  var filename: String?
  /// Chemin local une fois téléchargé par signal-cli.
  var localPath: String?

  var isImage: Bool {
    if contentType.hasPrefix("image/") { return true }
    let ext = (filename.map { URL(fileURLWithPath: $0).pathExtension }
      ?? localPath.map { URL(fileURLWithPath: $0).pathExtension }
      ?? id.split(separator: ".").last.map(String.init)
      ?? "").lowercased()
    return ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp"].contains(ext)
  }

  var isVideo: Bool {
    if contentType.hasPrefix("video/") { return true }
    let ext = (filename.map { URL(fileURLWithPath: $0).pathExtension }
      ?? localPath.map { URL(fileURLWithPath: $0).pathExtension }
      ?? "").lowercased()
    return ["mp4", "mov", "m4v"].contains(ext)
  }

  var resolvedFileURL: URL? {
    guard let localPath, !localPath.isEmpty else { return nil }
    let url = URL(fileURLWithPath: localPath)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }
}

/// Une réaction agrégée sur un message : un emoji, et qui l'a posé.
/// Les trois réseaux la modélisent pareil (un emoji par personne et par message).
struct MessageReaction: Identifiable, Hashable, Codable, Sendable {
  var emoji: String
  /// Noms (ou identifiants) des personnes ayant posé cet emoji, dédupliqués et triés.
  var senders: [String]
  /// L'une de ces personnes, c'est moi — la pastille se montre alors « active ».
  var isMine: Bool

  var id: String { emoji }
  var count: Int { max(senders.count, 1) }

  init(emoji: String, senders: [String] = [], isMine: Bool = false) {
    self.emoji = emoji
    self.senders = senders
    self.isMine = isMine
  }

  /// Agrège des couples (emoji, expéditeur) en pastilles ordonnées.
  /// L'ordre est stable : d'abord les plus posées, puis l'emoji, pour que l'UI ne danse pas.
  static func aggregate(_ raw: [(emoji: String, sender: String, isMine: Bool)]) -> [MessageReaction] {
    var byEmoji: [String: MessageReaction] = [:]
    for item in raw where !item.emoji.isEmpty {
      var reaction = byEmoji[item.emoji] ?? MessageReaction(emoji: item.emoji)
      if !item.sender.isEmpty, !reaction.senders.contains(item.sender) {
        reaction.senders.append(item.sender)
      }
      reaction.isMine = reaction.isMine || item.isMine
      byEmoji[item.emoji] = reaction
    }
    return byEmoji.values
      .map { var r = $0; r.senders.sort(); return r }
      .sorted { lhs, rhs in
        if lhs.count != rhs.count { return lhs.count > rhs.count }
        return lhs.emoji < rhs.emoji
      }
  }
}

struct ChatMessage: Identifiable, Hashable, Sendable {
  let id: String
  let conversationID: String
  let network: MessageNetwork
  let text: String
  let sentAt: Date
  let isFromMe: Bool
  /// Auteur du message côté réseau (numéro Signal, MXID Matrix, handle iMessage).
  /// Indispensable pour réagir ou citer : Signal désigne sa cible par (auteur, timestamp).
  var senderID: String?
  var isPending: Bool
  var attachments: [MessageAttachment]
  /// Réactions reçues sur ce message, déjà agrégées par emoji.
  var reactions: [MessageReaction]

  init(
    id: String,
    conversationID: String,
    network: MessageNetwork,
    text: String,
    sentAt: Date,
    isFromMe: Bool,
    senderID: String? = nil,
    isPending: Bool = false,
    attachments: [MessageAttachment] = [],
    reactions: [MessageReaction] = []
  ) {
    self.id = id
    self.conversationID = conversationID
    self.network = network
    self.text = text
    self.sentAt = sentAt
    self.isFromMe = isFromMe
    self.senderID = senderID
    self.isPending = isPending
    self.attachments = attachments
    self.reactions = reactions
  }

  var sidebarPreviewText: String {
    if !text.isEmpty { return text }
    if attachments.contains(where: \.isImage) { return "📷 Photo" }
    if !attachments.isEmpty { return "Pièce jointe" }
    return text
  }

  var hasVisibleBody: Bool {
    !text.isEmpty || !attachments.isEmpty
  }

  /// L'emoji que j'ai déjà posé sur ce message, s'il y en a un.
  /// Les trois réseaux n'en autorisent qu'un par personne : le menu bascule dessus.
  var myReactionEmoji: String? {
    reactions.first(where: \.isMine)?.emoji
  }
}
