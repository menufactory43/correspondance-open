import Foundation

public struct MessageAttachment: Identifiable, Hashable, Codable, Sendable {
  public var id: String
  public var contentType: String
  public var filename: String?
  /// Chemin local une fois le média téléchargé.
  public var localPath: String?
  /// Renseigné quand le réseau annonce un **message vocal** (et pas un simple
  /// fichier audio joint) : durée et forme d'onde de l'expéditeur.
  public var voice: VoiceNote?

  public var isImage: Bool {
    if contentType.hasPrefix("image/") { return true }
    let ext = (filename.map { URL(fileURLWithPath: $0).pathExtension }
      ?? localPath.map { URL(fileURLWithPath: $0).pathExtension }
      ?? id.split(separator: ".").last.map(String.init)
      ?? "").lowercased()
    return ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp"].contains(ext)
  }

  public var isVideo: Bool {
    if contentType.hasPrefix("video/") { return true }
    let ext = (filename.map { URL(fileURLWithPath: $0).pathExtension }
      ?? localPath.map { URL(fileURLWithPath: $0).pathExtension }
      ?? "").lowercased()
    return ["mp4", "mov", "m4v"].contains(ext)
  }

  /// Message audio : iMessage les dépose en `.caf` (`audio/x-caf`), les autres
  /// réseaux en `.ogg`, `.m4a` ou `.mp3`. Le fil les joue sur place.
  public var isAudio: Bool {
    if contentType.hasPrefix("audio/") { return true }
    let ext = (filename.map { URL(fileURLWithPath: $0).pathExtension }
      ?? localPath.map { URL(fileURLWithPath: $0).pathExtension }
      ?? "").lowercased()
    return ["caf", "m4a", "mp3", "aac", "wav", "ogg", "opus", "amr"].contains(ext)
  }

  public var resolvedFileURL: URL? {
    guard let localPath, !localPath.isEmpty else { return nil }
    let url = URL(fileURLWithPath: localPath)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }

  /// Un message vocal, pas une pièce jointe qu'on ouvre.
  public var isVoiceNote: Bool { voice != nil }

  public init(
    id: String,
    contentType: String,
    filename: String? = nil,
    localPath: String? = nil,
    voice: VoiceNote? = nil
  ) {
    self.id = id
    self.contentType = contentType
    self.filename = filename
    self.localPath = localPath
    self.voice = voice
  }
}

/// Une réaction agrégée sur un message : un emoji, et qui l'a posé.
/// Les trois réseaux la modélisent pareil (un emoji par personne et par message).
public struct MessageReaction: Identifiable, Hashable, Codable, Sendable {
  public var emoji: String
  /// Noms (ou identifiants) des personnes ayant posé cet emoji, dédupliqués et triés.
  public var senders: [String]
  /// L'une de ces personnes, c'est moi — la pastille se montre alors « active ».
  public var isMine: Bool

  public var id: String { emoji }
  public var count: Int { max(senders.count, 1) }

  public init(emoji: String, senders: [String] = [], isMine: Bool = false) {
    self.emoji = emoji
    self.senders = senders
    self.isMine = isMine
  }

  /// Agrège des couples (emoji, expéditeur) en pastilles ordonnées.
  /// L'ordre est stable : d'abord les plus posées, puis l'emoji, pour que l'UI ne danse pas.
  public static func aggregate(_ raw: [(emoji: String, sender: String, isMine: Bool)]) -> [MessageReaction] {
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
public struct QuotedMessage: Hashable, Codable, Sendable {
  /// Identifiant de la cible dans notre modèle, quand on a pu la retrouver.
  public var messageID: String?
  public var senderName: String
  public var text: String

  /// Une citation vide n'a rien à montrer.
  public var isEmpty: Bool {
    senderName.trimmingCharacters(in: .whitespaces).isEmpty
      && text.trimmingCharacters(in: .whitespaces).isEmpty
  }

  /// Retire le repli de citation Matrix : les lignes `> …` puis la ligne vide.
  /// Sans ça, chaque réponse WhatsApp s'afficherait avec le message d'origine recopié.
  public static func strippingReplyFallback(_ body: String) -> String {
    var lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard lines.first?.hasPrefix("> ") == true else { return body }
    while lines.first?.hasPrefix("> ") == true { lines.removeFirst() }
    while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
    return lines.joined(separator: "\n")
  }

  public init(messageID: String? = nil, senderName: String, text: String) {
    self.messageID = messageID
    self.senderName = senderName
    self.text = text
  }

  /// Une citation dont on connaît la cible sans l'avoir encore en main : le pont
  /// Signal ne met que l'`event_id` cité, aucun texte de repli. Elle reste
  /// muette jusqu'à ce que la cible arrive — par un trou comblé, ou en allant
  /// la chercher — et ne doit surtout pas être jetée entre-temps. Le critère
  /// est le texte seul : en tête-à-tête, le nom se déduit du fil sans la cible,
  /// alors qu'un message cité chargé a toujours quelque chose à dire (au moins
  /// « 📷 Photo »).
  public var awaitsTarget: Bool {
    messageID != nil && text.trimmingCharacters(in: .whitespaces).isEmpty
  }
}

/// L'aperçu d'un lien tel que le **réseau** l'a livré (`com.beeper.linkpreviews`) :
/// le téléphone de l'expéditeur a déjà interrogé la page, le pont nous passe le
/// titre, la description et la vignette (un `mxc://` du Relais). C'est l'aperçu
/// que voient les autres membres — bien plus fiable que d'aller nous-mêmes sur
/// une page qui refuse les robots.
public struct BridgedLinkPreview: Hashable, Codable, Sendable {
  public var url: String
  public var title: String?
  public var description: String?
  public var imageMXC: String?
  public var imageContentType: String?
  /// Chemin local de la vignette, une fois téléchargée du Relais.
  public var imageLocalPath: String?

  public init(
    url: String,
    title: String? = nil,
    description: String? = nil,
    imageMXC: String? = nil,
    imageContentType: String? = nil,
    imageLocalPath: String? = nil
  ) {
    self.url = url
    self.title = title
    self.description = description
    self.imageMXC = imageMXC
    self.imageContentType = imageContentType
    self.imageLocalPath = imageLocalPath
  }

  public var webURL: URL? {
    guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(),
          scheme == "http" || scheme == "https"
    else { return nil }
    return parsed
  }

  /// La carte qu'on peut en tirer, dans le même moule que celles qu'on cherche
  /// nous-mêmes. `nil` tant qu'il n'y a ni titre ni vignette : une carte sans
  /// rien dessus n'apprendrait rien.
  public var asLinkPreview: LinkPreview? {
    guard let webURL else { return nil }
    let preview = LinkPreview(title: title, domain: LinkPreview.domain(of: webURL), imagePath: imageLocalPath)
    return preview.hasSomethingToShow ? preview : nil
  }
}

public struct ChatMessage: Identifiable, Hashable, Sendable {
  public let id: String
  public let conversationID: String
  public let network: MessageNetwork
  public var text: String
  public let sentAt: Date
  public let isFromMe: Bool
  /// Auteur du message côté réseau (numéro Signal, MXID Matrix, handle iMessage).
  /// Indispensable pour réagir ou citer : Signal désigne sa cible par (auteur, timestamp).
  public var senderID: String?
  /// Nom lisible de l'auteur, quand le réseau le donne (les groupes surtout).
  /// Il n'est PAS collé dans `text` : le fil l'écrit une fois par groupe de
  /// messages, la liste s'en sert pour son aperçu « Nom : … ».
  public var senderName: String?
  public var isPending: Bool
  public var attachments: [MessageAttachment]
  /// Réactions reçues sur ce message, déjà agrégées par emoji.
  public var reactions: [MessageReaction]
  /// Message auquel celui-ci répond, si c'en est une.
  public var replyTo: QuotedMessage?
  /// Aperçu du premier lien, quand le réseau l'a fourni avec le message.
  public var linkPreview: BridgedLinkPreview?
  /// Date de la dernière modification, quand l'auteur a modifié son message
  /// (iMessage, 15 minutes). La bulle porte alors la mention « Modifié ».
  public var editedAt: Date?
  /// Versions antérieures du texte, de la plus ancienne à la plus récente.
  /// Elles se lisent au survol de la mention « Modifié ».
  public var editHistory: [String]
  /// L'auteur a annulé l'envoi : la bulle reste, vidée, en italique.
  public var isRetracted: Bool
  /// Effet d'envoi reçu (`expressive_send_style_id`), déjà traduit — « Confettis ».
  public var expressiveEffectName: String?
  /// Le sondage que ce message pose, dépouillé (MSC3381). La bulle montre
  /// alors la question et ses réponses, pas du texte.
  public var poll: Poll?
  /// Événement de conversation (« X a ajouté Y ») plutôt qu'un message :
  /// le fil l'affiche en séparateur discret, sans bulle ni auteur.
  public var systemEventText: String?

  /// Un événement de conversation, pas une prise de parole.
  public var isSystemEvent: Bool { systemEventText != nil }

  public init(
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
    linkPreview: BridgedLinkPreview? = nil,
    editedAt: Date? = nil,
    editHistory: [String] = [],
    isRetracted: Bool = false,
    expressiveEffectName: String? = nil,
    poll: Poll? = nil,
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
    self.linkPreview = linkPreview
    self.editedAt = editedAt
    self.editHistory = editHistory
    self.isRetracted = isRetracted
    self.expressiveEffectName = expressiveEffectName
    self.poll = poll
    self.systemEventText = systemEventText
  }

  public var sidebarPreviewText: String {
    if let systemEventText { return systemEventText }
    if isRetracted { return "Message annulé" }
    if let poll { return "📊 \(poll.question)" }
    if !text.isEmpty { return text }
    if attachments.contains(where: \.isImage) { return "📷 Photo" }
    if attachments.contains(where: \.isVoiceNote) { return "🎤 Message vocal" }
    if attachments.contains(where: \.isAudio) { return "🎤 Message audio" }
    if !attachments.isEmpty { return "Pièce jointe" }
    return text
  }

  /// Aperçu pour la liste des fils. En groupe il annonce qui parle — c'est là
  /// qu'on en a besoin, le fil, lui, écrit le nom une fois par groupe de bulles.
  public func listPreview(isGroup: Bool) -> String {
    SenderPrefix.previewLine(
      sidebarPreviewText,
      senderName: isFromMe ? nil : senderName,
      isGroup: isGroup
    )
  }

  public var hasVisibleBody: Bool {
    !text.isEmpty || !attachments.isEmpty || isRetracted || isSystemEvent || poll != nil
  }

  /// Ce message n'est qu'un geste : 1 à 3 emoji, rien d'autre.
  ///
  /// Ni pièce jointe (une photo légendée « 🎉 » reste une photo), ni citation
  /// (une réponse a un contexte à porter), ni annulation, ni événement de
  /// conversation. La bulle le montre alors nu et grand — cf. `MessageBubbleView`.
  public var isEmojiOnly: Bool {
    guard attachments.isEmpty, poll == nil else { return false }
    guard replyTo?.isEmpty != false else { return false }
    guard !isRetracted, !isSystemEvent else { return false }
    return EmojiText.isEmojiOnly(text)
  }

  /// Le nom d'expéditeur BON À MONTRER, ou rien.
  ///
  /// `senderName` peut manquer, ou n'être que du blanc ; `senderID` existe
  /// presque toujours mais c'est un identifiant de réseau, pas un nom. Cette
  /// propriété ne rend que ce qu'un humain reconnaîtrait — aux vues de choisir
  /// leur repli (titre du fil, « ce message »…).
  public var displayedSenderName: String? {
    guard let name = senderName?.trimmingCharacters(in: .whitespacesAndNewlines),
          !name.isEmpty
    else { return nil }
    return name
  }

  /// L'emoji que j'ai déjà posé sur ce message, s'il y en a un.
  /// Les trois réseaux n'en autorisent qu'un par personne : le menu bascule dessus.
  public var myReactionEmoji: String? {
    reactions.first(where: \.isMine)?.emoji
  }
}
