import Foundation

/// Persiste les conversations bridgées + le `next_batch` : au redémarrage l'inbox
/// s'affiche immédiatement et le sync reprend là où il s'était arrêté.
public enum MatrixConversationCache {
  private static var fileURL: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    let dir = base.appendingPathComponent("Correspondance", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("matrix-conversations.json")
  }

  public struct Snapshot: Codable, Sendable {
    public var nextBatch: String?
    public var conversations: [CachedConversation]
    public var messages: [String: [CachedMessage]]
  }

  public struct CachedConversation: Codable, Sendable {
    public var id: String
    public var network: MessageNetwork
    public var address: String
    public var title: String
    public var preview: String
    public var lastMessageAt: Date
    public var unreadCount: Int
    public var transportKey: String
    public var isGroup: Bool
    /// Absent des caches écrits avant les avatars de portail — d'où l'optionnel.
    public var remoteAvatarID: String?
    /// Idem pour la mosaïque des membres : un cache plus ancien n'en sait rien.
    public var memberAvatarIDs: [String]?
  }

  public struct CachedMessage: Codable, Sendable {
    public var id: String
    public var conversationID: String
    public var network: MessageNetwork
    public var text: String
    public var sentAt: Date
    public var isFromMe: Bool
    public var attachments: [MessageAttachment]
    /// Absent des caches écrits avant les réactions — d'où le repli sur `[]`.
    public var reactions: [MessageReaction]?
    /// Auteur du message et son nom lisible, pour regrouper les bulles et
    /// nommer l'expéditeur dans un groupe. Absents des caches plus anciens.
    public var senderID: String?
    public var senderName: String?
    /// Citation et aperçu de lien, absents des caches plus anciens. Une citation
    /// encore muette (cible inconnue) se garde aussi : c'est ce qui permet de
    /// la résoudre à un lancement suivant.
    public var replyTo: QuotedMessage?
    public var linkPreview: BridgedLinkPreview?
  }

  public static func load() -> (nextBatch: String?, conversations: [Conversation], messages: [String: [ChatMessage]]) {
    guard let data = try? Data(contentsOf: fileURL),
          let snap = try? JSONDecoder().decode(Snapshot.self, from: data)
    else {
      return (nil, [], [:])
    }
    let conversations = snap.conversations.map { cached -> Conversation in
      var conversation = Conversation(
        id: cached.id,
        network: cached.network,
        address: cached.address,
        title: cached.title,
        preview: cached.preview,
        lastMessageAt: cached.lastMessageAt,
        unreadCount: cached.unreadCount,
        isArchived: false,
        transportKey: cached.transportKey,
        isGroup: cached.isGroup
      )
      conversation.remoteAvatarID = cached.remoteAvatarID
      conversation.memberAvatarIDs = cached.memberAvatarIDs ?? []
      return conversation
    }
    let messages = snap.messages.mapValues { list in list.map(Self.chatMessage(from:)) }
    return (snap.nextBatch, conversations, messages)
  }

  /// Les messages d'une conversation de l'instantané, retraduits. C'est par là
  /// que passe la reprise vers la base locale.
  public static func messages(in snapshot: Snapshot, conversationID: String) -> [ChatMessage] {
    (snapshot.messages[conversationID] ?? []).map(chatMessage(from:))
  }

  /// Un message du fichier tel que le reste de l'app l'attend. Les chemins des
  /// pièces jointes sont re-résolus : le cache disque a pu être vidé par le
  /// système alors que l'instantané, lui, était resté.
  static func chatMessage(from cached: CachedMessage) -> ChatMessage {
    let attachments = cached.attachments.map { attachment -> MessageAttachment in
      var copy = attachment
      if copy.resolvedFileURL == nil {
        copy.localPath = MatrixAttachmentStore.existingLocalPath(
          forMXC: attachment.id, contentType: attachment.contentType
        )
      }
      return copy
    }
    return ChatMessage(
      id: cached.id,
      conversationID: cached.conversationID,
      network: cached.network,
      text: cached.text,
      sentAt: cached.sentAt,
      isFromMe: cached.isFromMe,
      senderID: cached.senderID,
      senderName: cached.senderName,
      attachments: attachments,
      reactions: cached.reactions ?? [],
      replyTo: cached.replyTo,
      linkPreview: cached.linkPreview.map { preview in
        var copy = preview
        if let path = copy.imageLocalPath, !FileManager.default.fileExists(atPath: path) {
          copy.imageLocalPath = nil
        }
        return copy
      }
    )
  }

  public static func save(nextBatch: String?, conversations: [Conversation], messages: [String: [ChatMessage]]) {
    let bridged = conversations.filter { $0.network.livesOnRelay }
    let keep = Set(bridged.map(\.id))
    let snap = Snapshot(
      nextBatch: nextBatch,
      conversations: bridged.map {
        CachedConversation(
          id: $0.id,
          network: $0.network,
          address: $0.address,
          title: $0.title,
          preview: $0.preview,
          lastMessageAt: $0.lastMessageAt,
          unreadCount: $0.unreadCount,
          transportKey: $0.transportKey,
          isGroup: $0.isGroup,
          remoteAvatarID: $0.remoteAvatarID,
          memberAvatarIDs: $0.memberAvatarIDs
        )
      },
      messages: messages
        .filter { keep.contains($0.key) }
        .mapValues { list in
          list.map {
            CachedMessage(
              id: $0.id,
              conversationID: $0.conversationID,
              network: $0.network,
              text: $0.text,
              sentAt: $0.sentAt,
              isFromMe: $0.isFromMe,
              attachments: $0.attachments,
              reactions: $0.reactions,
              senderID: $0.senderID,
              senderName: $0.senderName,
              replyTo: $0.replyTo,
              linkPreview: $0.linkPreview
            )
          }
        }
    )
    guard let data = try? JSONEncoder().encode(snap) else { return }
    try? data.write(to: fileURL, options: [.atomic])
  }

  public static func clear() {
    try? FileManager.default.removeItem(at: fileURL)
  }
}
