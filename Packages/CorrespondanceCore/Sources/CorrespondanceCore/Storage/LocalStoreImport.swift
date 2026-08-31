import Foundation

/// La reprise de l'ancien instantané `matrix-conversations.json`, une fois.
///
/// Ce qui traverse : les conversations et tout leur historique. Ce qui ne
/// traverse pas : le curseur `next_batch`. L'ancien fichier ne gardait aucun
/// état de salon (ni membres, ni pont, ni marqueurs de lecture) — reprendre son
/// curseur laisserait des salons anonymes. On repart donc d'un sync initial,
/// une seule fois, et l'historique, lui, est déjà là.
///
/// Le fichier est ensuite renommé `.migrated` : gardé au cas où, plus jamais lu.
public extension LocalStore {
  /// Le nom du drapeau dans `sync_state`, pour ne migrer qu'une fois même si le
  /// fichier revenait (restauration Time Machine, synchro de dossier).
  static let jsonImportFlag = "import.matrix-conversations.json"

  /// Ce qu'une migration a fait — de quoi l'écrire dans un journal ou un test.
  struct ImportOutcome: Sendable, Equatable {
    public var rooms: Int = 0
    public var messages: Int = 0
    /// Rien à faire : pas de fichier, ou migration déjà jouée.
    public var didRun: Bool = false
  }

  static func legacySnapshotURL() -> URL {
    applicationSupportDirectory().appendingPathComponent("matrix-conversations.json")
  }

  @discardableResult
  func importLegacySnapshotIfNeeded(
    at url: URL = LocalStore.legacySnapshotURL(),
    selfUserID: String = ""
  ) -> ImportOutcome {
    guard flag(Self.jsonImportFlag) == nil else { return ImportOutcome() }
    guard FileManager.default.fileExists(atPath: url.path) else {
      // Rien à reprendre : on pose quand même le drapeau, il n'y aura jamais rien.
      setFlag(Self.jsonImportFlag, to: "aucun")
      return ImportOutcome()
    }
    let outcome = importLegacySnapshot(at: url, selfUserID: selfUserID)
    setFlag(Self.jsonImportFlag, to: "\(outcome.rooms) salon(s), \(outcome.messages) message(s)")
    // Renommé, pas supprimé : si la reprise s'était mal passée, le fichier est là.
    let archived = url.deletingPathExtension().appendingPathExtension("json.migrated")
    try? FileManager.default.removeItem(at: archived)
    try? FileManager.default.moveItem(at: url, to: archived)
    return outcome
  }

  /// La reprise elle-même, sans drapeau ni renommage — c'est ce que les tests
  /// exercent, sur une fixture de l'ancien format.
  func importLegacySnapshot(at url: URL, selfUserID: String = "") -> ImportOutcome {
    guard let data = try? Data(contentsOf: url),
          let snapshot = try? JSONDecoder().decode(MatrixConversationCache.Snapshot.self, from: data)
    else { return ImportOutcome(didRun: true) }

    var rooms: [StoredRoom] = []
    var messages: [String: [ChatMessage]] = [:]
    var total = 0
    for cached in snapshot.conversations {
      guard let roomID = MatrixSyncParser.roomID(inConversationID: cached.id) else { continue }
      var state = StoredRoom.State()
      // L'ancien cache ne gardait que le titre affiché : on le repose comme nom
      // explicite, le premier `/sync` remettra le vrai état par-dessus.
      state.explicitName = cached.title
      state.bridgeRoomType = cached.isGroup ? "group" : "dm"
      state.lastEventAt = cached.lastMessageAt
      rooms.append(
        StoredRoom(
          roomID: roomID,
          conversationID: cached.id,
          network: cached.network,
          title: cached.title,
          preview: cached.preview,
          lastMessageAt: cached.lastMessageAt,
          unreadCount: cached.unreadCount,
          transportKey: cached.transportKey,
          isGroup: cached.isGroup,
          avatarMXC: cached.remoteAvatarID,
          memberAvatarIDs: cached.memberAvatarIDs ?? [],
          state: state
        )
      )
      let list = MatrixConversationCache.messages(in: snapshot, conversationID: cached.id)
      if !list.isEmpty {
        messages[roomID] = list
        total += list.count
      }
    }
    guard !rooms.isEmpty else { return ImportOutcome(didRun: true) }
    commit(rooms: rooms, messages: messages, reactions: [:])
    return ImportOutcome(rooms: rooms.count, messages: total, didRun: true)
  }
}
