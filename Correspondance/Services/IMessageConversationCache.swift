import Foundation
import CorrespondanceCore

/// Cache local iMessage — démarrage instantané comme Messages, sync chat.db ensuite.
enum IMessageConversationCache {
  private static var fileURL: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    let dir = base.appendingPathComponent("Correspondance", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("imessage-conversations.json")
  }

  struct Snapshot: Codable, Sendable {
    var conversations: [CachedConversation]
    var savedAt: Date
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

  static func load() -> [Conversation] {
    guard let data = try? Data(contentsOf: fileURL),
          let snap = try? JSONDecoder().decode(Snapshot.self, from: data)
    else { return [] }

    return snap.conversations.map {
      Conversation(
        id: $0.id,
        network: .iMessage,
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
  }

  static func save(_ conversations: [Conversation]) {
    let iMessageOnly = conversations.filter { $0.network == .iMessage }
    let snap = Snapshot(
      conversations: iMessageOnly.map {
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
      savedAt: Date()
    )
    guard let data = try? JSONEncoder().encode(snap) else { return }
    try? data.write(to: fileURL, options: [.atomic])
  }
}
