import Foundation

/// Les salons : lecture d'un bloc au lancement (l'inbox n'a besoin de rien
/// d'autre), écriture salon par salon.
public extension LocalStore {
  private static let roomColumns = """
  room_id, conversation_id, network, title, preview, last_message_at, unread_count, \
  transport_key, is_group, avatar_mxc, member_avatar_ids, state
  """

  /// Tous les salons, du plus récent au plus ancien. C'est **tout** ce que le
  /// lancement lit : les messages attendent qu'on ouvre un fil.
  func rooms() -> [StoredRoom] {
    read([]) {
      let statement = try database.prepare(
        "SELECT \(Self.roomColumns) FROM rooms ORDER BY last_message_at DESC;"
      )
      var result: [StoredRoom] = []
      try statement.forEachRow { row in
        if let room = Self.room(in: row) { result.append(room) }
      }
      return result
    }
  }

  func room(roomID: String) -> StoredRoom? {
    read(nil) {
      let statement = try database
        .prepare("SELECT \(Self.roomColumns) FROM rooms WHERE room_id = ?;")
        .bind([.text(roomID)])
      guard try statement.step() else { return nil }
      return Self.room(in: statement)
    }
  }

  func roomCount() -> Int {
    read(0) { Int(try database.scalarInt("SELECT COUNT(*) FROM rooms;") ?? 0) }
  }

  /// Les salons déjà connus de la base — ce qui permet de repérer, au
  /// lancement, un salon rejoint dont on n'a jamais rien vu passer.
  func knownRoomIDs() -> Set<String> {
    read([]) {
      let statement = try database.prepare("SELECT room_id FROM rooms;")
      var ids: Set<String> = []
      try statement.forEachRow { ids.insert($0.string(0)) }
      return ids
    }
  }

  func upsert(rooms list: [StoredRoom]) {
    guard !list.isEmpty else { return }
    attempt {
      try database.transaction {
        for room in list { try Self.write(room, into: database) }
      }
    }
  }

  /// Un salon quitté sort de l'inbox — et de la base, messages compris.
  func deleteRooms(_ roomIDs: [String]) {
    guard !roomIDs.isEmpty else { return }
    attempt {
      try database.transaction {
        for roomID in roomIDs {
          try database.run("DELETE FROM messages WHERE room_id = ?;", [.text(roomID)])
          try database.run("DELETE FROM reactions WHERE room_id = ?;", [.text(roomID)])
          try database.run("DELETE FROM rooms WHERE room_id = ?;", [.text(roomID)])
        }
      }
    }
  }

  // MARK: - Privé

  internal static func write(_ room: StoredRoom, into database: SQLiteDatabase) throws {
    let state = (try? JSONEncoder().encode(room.state)) ?? Data()
    let avatars = (try? JSONEncoder().encode(room.memberAvatarIDs)) ?? Data("[]".utf8)
    try database.run(
      """
      INSERT INTO rooms (\(roomColumns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(room_id) DO UPDATE SET
        conversation_id = excluded.conversation_id,
        network = excluded.network,
        title = excluded.title,
        preview = excluded.preview,
        last_message_at = excluded.last_message_at,
        unread_count = excluded.unread_count,
        transport_key = excluded.transport_key,
        is_group = excluded.is_group,
        avatar_mxc = excluded.avatar_mxc,
        member_avatar_ids = excluded.member_avatar_ids,
        state = excluded.state;
      """,
      [
        .text(room.roomID),
        .text(room.conversationID),
        .optionalText(room.network?.rawValue),
        .text(room.title),
        .text(room.preview),
        .date(room.lastMessageAt),
        .int(Int64(room.unreadCount)),
        .text(room.transportKey),
        .bool(room.isGroup),
        .optionalText(room.avatarMXC),
        .text(String(data: avatars, encoding: .utf8) ?? "[]"),
        .blob(state),
      ]
    )
  }

  private static func room(in row: SQLiteStatement) -> StoredRoom? {
    let avatarData = Data(row.string(10).utf8)
    return StoredRoom(
      roomID: row.string(0),
      conversationID: row.string(1),
      network: row.optionalString(2).flatMap(MessageNetwork.init(rawValue:)),
      title: row.string(3),
      preview: row.string(4),
      lastMessageAt: row.date(5),
      unreadCount: Int(row.int(6)),
      transportKey: row.string(7),
      isGroup: row.bool(8),
      avatarMXC: row.optionalString(9),
      memberAvatarIDs: (try? JSONDecoder().decode([String].self, from: avatarData)) ?? [],
      state: (try? JSONDecoder().decode(StoredRoom.State.self, from: row.data(11)))
        ?? StoredRoom.State()
    )
  }
}
