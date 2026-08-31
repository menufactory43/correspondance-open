import Foundation

/// L'ancien instantané JSON — `matrix-conversations.json` — qui tenait lieu de
/// mémoire avant la base locale : un fichier global, relu en entier au
/// lancement et réécrit en entier à chaque passe de `/sync`.
///
/// Il ne sert plus qu'à **le relire une fois**, le temps de la reprise
/// (`LocalStore.importLegacySnapshotIfNeeded`). Plus rien ne l'écrit. Le jour
/// où plus personne n'aura d'ancien fichier sur son disque, ce type disparaît.
public enum MatrixConversationCache {
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
    /// Absent des fichiers écrits avant les avatars de portail — d'où l'optionnel.
    /// C'est exactement ce que la base a supprimé : une forme par âge du cache.
    public var remoteAvatarID: String?
    /// Idem pour la mosaïque des membres : un fichier plus ancien n'en sait rien.
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
    /// Absent des fichiers écrits avant les réactions — d'où le repli sur `[]`.
    public var reactions: [MessageReaction]?
    public var senderID: String?
    public var senderName: String?
    public var replyTo: QuotedMessage?
    public var linkPreview: BridgedLinkPreview?
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
}
