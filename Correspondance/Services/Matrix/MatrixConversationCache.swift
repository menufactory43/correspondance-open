import Foundation

/// Persiste les conversations bridgées + le `next_batch` : au redémarrage l'inbox
/// s'affiche immédiatement et le sync reprend là où il s'était arrêté.
enum MatrixConversationCache {
  private static var fileURL: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    let dir = base.appendingPathComponent("Correspondance", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("matrix-conversations.json")
  }

  struct Snapshot: Codable, Sendable {
    var nextBatch: String?
    var conversations: [CachedConversation]
    var messages: [String: [CachedMessage]]
  }

  struct CachedConversation: Codable, Sendable {
    var id: String
    var network: MessageNetwork
    var address: String
    var title: String
    var preview: String
    var lastMessageAt: Date
    var unreadCount: Int
    var transportKey: String
    var isGroup: Bool
    /// Absent des caches écrits avant les avatars de portail — d'où l'optionnel.
    var remoteAvatarID: String?
    /// Idem pour la mosaïque des membres : un cache plus ancien n'en sait rien.
    var memberAvatarIDs: [String]?
  }

  struct CachedMessage: Codable, Sendable {
    var id: String
    var conversationID: String
    var network: MessageNetwork
    var text: String
    var sentAt: Date
    var isFromMe: Bool
    var attachments: [MessageAttachment]
    /// Absent des caches écrits avant les réactions — d'où le repli sur `[]`.
    var reactions: [MessageReaction]?
    /// Auteur du message et son nom lisible, pour regrouper les bulles et
    /// nommer l'expéditeur dans un groupe. Absents des caches plus anciens.
    var senderID: String?
    var senderName: String?
  }

  static func load() -> (nextBatch: String?, conversations: [Conversation], messages: [String: [ChatMessage]]) {
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
    let messages = snap.messages.mapValues { list in
      list.map { cached in
        // Re-résoudre les chemins : le cache disque peut avoir été vidé par macOS.
        let attachments = cached.attachments.map { att -> MessageAttachment in
          var copy = att
          if copy.resolvedFileURL == nil {
            copy.localPath = MatrixAttachmentStore.existingLocalPath(forMXC: att.id, contentType: att.contentType)
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
          reactions: cached.reactions ?? []
        )
      }
    }
    return (snap.nextBatch, conversations, messages)
  }

  static func save(nextBatch: String?, conversations: [Conversation], messages: [String: [ChatMessage]]) {
    let bridged = conversations.filter { $0.network.isMatrixBridged }
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
              senderName: $0.senderName
            )
          }
        }
    )
    guard let data = try? JSONEncoder().encode(snap) else { return }
    try? data.write(to: fileURL, options: [.atomic])
  }

  static func clear() {
    try? FileManager.default.removeItem(at: fileURL)
  }
}
