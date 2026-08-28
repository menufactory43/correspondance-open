import Foundation

/// Persiste les conversations Signal entre deux refresh (receive consomme les messages).
enum SignalConversationCache {
  private static var fileURL: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    let dir = base.appendingPathComponent("Correspondance", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("signal-conversations.json")
  }

  struct Snapshot: Codable, Sendable {
    var conversations: [CachedConversation]
    var messages: [String: [CachedMessage]]
  }

  struct CachedConversation: Codable, Sendable {
    var id: String
    var address: String
    var title: String
    var preview: String
    var lastMessageAt: Date
    var unreadCount: Int
    var isArchived: Bool
    var transportKey: String
    var isGroup: Bool
  }

  struct CachedMessage: Codable, Sendable {
    var id: String
    var conversationID: String
    var text: String
    var sentAt: Date
    var isFromMe: Bool
    var attachments: [MessageAttachment]

    init(
      id: String,
      conversationID: String,
      text: String,
      sentAt: Date,
      isFromMe: Bool,
      attachments: [MessageAttachment]
    ) {
      self.id = id
      self.conversationID = conversationID
      self.text = text
      self.sentAt = sentAt
      self.isFromMe = isFromMe
      self.attachments = attachments
    }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      id = try c.decode(String.self, forKey: .id)
      conversationID = try c.decode(String.self, forKey: .conversationID)
      text = try c.decode(String.self, forKey: .text)
      sentAt = try c.decode(Date.self, forKey: .sentAt)
      isFromMe = try c.decode(Bool.self, forKey: .isFromMe)
      attachments = try c.decodeIfPresent([MessageAttachment].self, forKey: .attachments) ?? []
    }
  }

  static func load() -> ([Conversation], [String: [ChatMessage]]) {
    guard let data = try? Data(contentsOf: fileURL),
          let snap = try? JSONDecoder().decode(Snapshot.self, from: data)
    else {
      return ([], [:])
    }

    let conversations = snap.conversations.map {
      Conversation(
        id: $0.id,
        network: .signal,
        address: $0.address,
        title: $0.title,
        preview: $0.preview,
        lastMessageAt: $0.lastMessageAt,
        unreadCount: $0.unreadCount,
        isArchived: $0.isArchived,
        transportKey: $0.transportKey,
        isGroup: $0.isGroup
      )
    }

    var messages: [String: [ChatMessage]] = [:]
    for (key, list) in snap.messages {
      messages[key] = list.map { cached in
        var attachments = cached.attachments
        // Re-résoudre les chemins locaux (signal-cli attachments/).
        attachments = attachments.map { att in
          var copy = att
          if copy.resolvedFileURL == nil, let path = SignalAttachmentStore.localPath(forAttachmentID: att.id) {
            copy.localPath = path
          }
          return copy
        }
        return ChatMessage(
          id: cached.id,
          conversationID: cached.conversationID,
          network: .signal,
          text: cached.text,
          sentAt: cached.sentAt,
          isFromMe: cached.isFromMe,
          attachments: attachments
        )
      }
    }
    return (conversations, messages)
  }

  static func save(conversations: [Conversation], messages: [String: [ChatMessage]]) {
    let signalOnly = conversations.filter { $0.network == .signal }
    let snap = Snapshot(
      conversations: signalOnly.map {
        CachedConversation(
          id: $0.id,
          address: $0.address,
          title: $0.title,
          preview: $0.preview,
          lastMessageAt: $0.lastMessageAt,
          unreadCount: $0.unreadCount,
          isArchived: $0.isArchived,
          transportKey: $0.transportKey,
          isGroup: $0.isGroup
        )
      },
      messages: messages.mapValues { list in
        list.map {
          CachedMessage(
            id: $0.id,
            conversationID: $0.conversationID,
            text: $0.text,
            sentAt: $0.sentAt,
            isFromMe: $0.isFromMe,
            attachments: $0.attachments
          )
        }
      }
    )
    guard let data = try? JSONEncoder().encode(snap) else { return }
    try? data.write(to: fileURL, options: [.atomic])
  }
}
