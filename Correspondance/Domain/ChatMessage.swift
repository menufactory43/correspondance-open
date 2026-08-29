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

  /// Message audio : iMessage les dépose en `.caf` (`audio/x-caf`), les autres
  /// réseaux en `.ogg`, `.m4a` ou `.mp3`. Le fil les joue sur place.
  var isAudio: Bool {
    if contentType.hasPrefix("audio/") { return true }
    let ext = (filename.map { URL(fileURLWithPath: $0).pathExtension }
      ?? localPath.map { URL(fileURLWithPath: $0).pathExtension }
      ?? "").lowercased()
    return ["caf", "m4a", "mp3", "aac", "wav", "ogg", "opus", "amr"].contains(ext)
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

/// Le message cité au-dessus d'une réponse. On n'en garde que de quoi afficher
/// une citation compacte : le fil complet est déjà là si l'on veut y remonter.
struct QuotedMessage: Hashable, Codable, Sendable {
  /// Identifiant de la cible dans notre modèle, quand on a pu la retrouver.
  var messageID: String?
  var senderName: String
  var text: String

  /// Une citation vide n'a rien à montrer.
  var isEmpty: Bool {
    senderName.trimmingCharacters(in: .whitespaces).isEmpty
      && text.trimmingCharacters(in: .whitespaces).isEmpty
  }

  /// Retire le repli de citation Matrix : les lignes `> …` puis la ligne vide.
  /// Sans ça, chaque réponse WhatsApp s'afficherait avec le message d'origine recopié.
  static func strippingReplyFallback(_ body: String) -> String {
    var lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard lines.first?.hasPrefix("> ") == true else { return body }
    while lines.first?.hasPrefix("> ") == true { lines.removeFirst() }
    while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
    return lines.joined(separator: "\n")
  }
}

struct ChatMessage: Identifiable, Hashable, Sendable {
  let id: String
  let conversationID: String
  let network: MessageNetwork
  var text: String
  let sentAt: Date
  let isFromMe: Bool
  /// Auteur du message côté réseau (numéro Signal, MXID Matrix, handle iMessage).
  /// Indispensable pour réagir ou citer : Signal désigne sa cible par (auteur, timestamp).
  var senderID: String?
  /// Nom lisible de l'auteur, quand le réseau le donne (les groupes surtout).
  /// Il n'est PAS collé dans `text` : le fil l'écrit une fois par groupe de
  /// messages, la liste s'en sert pour son aperçu « Nom : … ».
  var senderName: String?
  var isPending: Bool
  var attachments: [MessageAttachment]
  /// Réactions reçues sur ce message, déjà agrégées par emoji.
  var reactions: [MessageReaction]
  /// Message auquel celui-ci répond, si c'en est une.
  var replyTo: QuotedMessage?
  /// Date de la dernière modification, quand l'auteur a modifié son message
  /// (iMessage, 15 minutes). La bulle porte alors la mention « Modifié ».
  var editedAt: Date?
  /// Versions antérieures du texte, de la plus ancienne à la plus récente.
  /// Elles se lisent au survol de la mention « Modifié ».
  var editHistory: [String]
  /// L'auteur a annulé l'envoi : la bulle reste, vidée, en italique.
  var isRetracted: Bool
  /// Effet d'envoi reçu (`expressive_send_style_id`), déjà traduit — « Confettis ».
  var expressiveEffectName: String?
  /// Événement de conversation (« X a ajouté Y ») plutôt qu'un message :
  /// le fil l'affiche en séparateur discret, sans bulle ni auteur.
  var systemEventText: String?

  /// Un événement de conversation, pas une prise de parole.
  var isSystemEvent: Bool { systemEventText != nil }

  init(
    id: String,
    conversationID: String,
    network: MessageNetwork,
    text: String,
    sentAt: Date,
    isFromMe: Bool,
    senderID: String? = nil,
    senderName: String? = nil,
    isPending: Bool = false,
    attachments: [MessageAttachment] = [],
    reactions: [MessageReaction] = [],
    replyTo: QuotedMessage? = nil,
    editedAt: Date? = nil,
    editHistory: [String] = [],
    isRetracted: Bool = false,
    expressiveEffectName: String? = nil,
    systemEventText: String? = nil
  ) {
    self.id = id
    self.conversationID = conversationID
    self.network = network
    self.text = text
    self.sentAt = sentAt
    self.isFromMe = isFromMe
    self.senderID = senderID
    self.senderName = senderName
    self.isPending = isPending
    self.attachments = attachments
    self.reactions = reactions
    self.replyTo = replyTo
    self.editedAt = editedAt
    self.editHistory = editHistory
    self.isRetracted = isRetracted
    self.expressiveEffectName = expressiveEffectName
    self.systemEventText = systemEventText
  }

  var sidebarPreviewText: String {
    if let systemEventText { return systemEventText }
    if isRetracted { return "Message annulé" }
    if !text.isEmpty { return text }
    if attachments.contains(where: \.isImage) { return "📷 Photo" }
    if attachments.contains(where: \.isAudio) { return "🎤 Message audio" }
    if !attachments.isEmpty { return "Pièce jointe" }
    return text
  }

  /// Aperçu pour la liste des fils. En groupe il annonce qui parle — c'est là
  /// qu'on en a besoin, le fil, lui, écrit le nom une fois par groupe de bulles.
  func listPreview(isGroup: Bool) -> String {
    SenderPrefix.previewLine(
      sidebarPreviewText,
      senderName: isFromMe ? nil : senderName,
      isGroup: isGroup
    )
  }

  var hasVisibleBody: Bool {
    !text.isEmpty || !attachments.isEmpty || isRetracted || isSystemEvent
  }

  /// L'emoji que j'ai déjà posé sur ce message, s'il y en a un.
  /// Les trois réseaux n'en autorisent qu'un par personne : le menu bascule dessus.
  var myReactionEmoji: String? {
    reactions.first(where: \.isMine)?.emoji
  }
}
