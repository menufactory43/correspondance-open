import Foundation

/// Les messages : écrits un par un quand ils changent, relus par pages.
public extension LocalStore {
  /// Ce qu'un fil charge à l'ouverture. Au-delà, c'est du défilement, et ça se
  /// demande (`messages(roomID:before:)`).
  static let defaultPageSize = 300

  private static let messageColumns = """
  event_id, room_id, conversation_id, sent_at, sender_id, sender_name, text, \
  is_from_me, attachment_names, attachment_types, payload
  """

  /// Une page de fil, du plus ancien au plus récent — l'ordre d'affichage.
  ///
  /// - Parameter before: ne rend que ce qui précède cette date, pour remonter
  ///   plus haut dans le fil sans tout relire.
  func messages(roomID: String, limit: Int = defaultPageSize, before: Date? = nil) -> [ChatMessage] {
    read([]) {
      let clause = before == nil ? "" : "AND sent_at < ? "
      let statement = try database.prepare(
        "SELECT \(Self.messageColumns) FROM messages WHERE room_id = ? \(clause)"
          + "ORDER BY sent_at DESC LIMIT ?;"
      )
      var bindings: [SQLiteValue] = [.text(roomID)]
      if let before { bindings.append(.date(before)) }
      bindings.append(.int(Int64(limit)))
      try statement.bind(bindings)
      var result: [ChatMessage] = []
      try statement.forEachRow { row in
        if let message = Self.message(in: row) { result.append(message) }
      }
      return result.reversed()
    }
  }

  /// Le dernier message d'un salon — l'aperçu de la ligne d'inbox, et rien de
  /// plus : c'est ce que le lancement charge pour chaque fil.
  func lastMessages() -> [String: ChatMessage] {
    read([:]) {
      // Une jointure sur le maximum par salon : l'index `(room_id, sent_at DESC)`
      // la sert directement. Deux messages à la même seconde donnent deux
      // lignes — la dernière lue gagne, et elles disent la même chose.
      let statement = try database.prepare(
        """
        SELECT \(Self.messageColumns) FROM messages
        JOIN (SELECT room_id AS r, MAX(sent_at) AS t FROM messages GROUP BY room_id) AS derniers
          ON derniers.r = messages.room_id AND derniers.t = messages.sent_at;
        """
      )
      var result: [String: ChatMessage] = [:]
      try statement.forEachRow { row in
        if let message = Self.message(in: row) { result[row.string(1)] = message }
      }
      return result
    }
  }

  /// Des messages précis, par identifiant d'event. Sert aux marqueurs de
  /// lecture : sans le message pointé, on ne sait pas dire « Vu ».
  func messages(eventIDs: [String]) -> [ChatMessage] {
    guard !eventIDs.isEmpty else { return [] }
    return read([]) {
      let holes = Array(repeating: "?", count: eventIDs.count).joined(separator: ", ")
      let statement = try database
        .prepare("SELECT \(Self.messageColumns) FROM messages WHERE event_id IN (\(holes));")
        .bind(eventIDs.map { .text($0) })
      var result: [ChatMessage] = []
      try statement.forEachRow { row in
        if let message = Self.message(in: row) { result.append(message) }
      }
      return result
    }
  }

  func messageCount(roomID: String) -> Int {
    read(0) {
      Int(try database.scalarInt("SELECT COUNT(*) FROM messages WHERE room_id = ?;", [.text(roomID)]) ?? 0)
    }
  }

  /// Les réactions d'un salon, telles que le modèle les tient : par event de
  /// réaction, pour qu'une rédaction en retire une seule.
  func reactions(roomID: String) -> [String: MatrixRoomModel.ReactionEvent] {
    read([:]) {
      let statement = try database
        .prepare(
          "SELECT event_id, target_event_id, emoji, sender_id, sender_name, is_mine "
            + "FROM reactions WHERE room_id = ?;"
        )
        .bind([.text(roomID)])
      var result: [String: MatrixRoomModel.ReactionEvent] = [:]
      try statement.forEachRow { row in
        result[row.string(0)] = MatrixRoomModel.ReactionEvent(
          targetEventID: row.string(1),
          emoji: row.string(2),
          senderID: row.string(3),
          senderName: row.string(4),
          isMine: row.bool(5)
        )
      }
      return result
    }
  }

  /// Écrit un lot : les salons touchés, leurs messages et réactions changés,
  /// ce qui a été rédigé, puis le curseur — **le tout dans une transaction**.
  /// Le curseur n'avance donc jamais sans le lot qu'il referme.
  func commit(
    rooms: [StoredRoom],
    messages: [String: [ChatMessage]],
    reactions: [String: [String: MatrixRoomModel.ReactionEvent]],
    deletedEventIDs: [String] = [],
    deletedRoomIDs: [String] = [],
    cursor: String?? = nil
  ) {
    attempt {
      try database.transaction {
        for roomID in deletedRoomIDs {
          try database.run("DELETE FROM messages WHERE room_id = ?;", [.text(roomID)])
          try database.run("DELETE FROM reactions WHERE room_id = ?;", [.text(roomID)])
          try database.run("DELETE FROM rooms WHERE room_id = ?;", [.text(roomID)])
        }
        for eventID in deletedEventIDs {
          try database.run("DELETE FROM messages WHERE event_id = ?;", [.text(eventID)])
          try database.run("DELETE FROM reactions WHERE event_id = ?;", [.text(eventID)])
        }
        for room in rooms { try Self.write(room, into: database) }
        for (roomID, list) in messages {
          for message in list { try Self.write(message, roomID: roomID, into: database) }
        }
        for (roomID, list) in reactions {
          for (eventID, reaction) in list {
            try Self.write(reaction, eventID: eventID, roomID: roomID, into: database)
          }
        }
        if case .some(let value) = cursor {
          if let value {
            try database.run(
              "INSERT INTO sync_state (key, value) VALUES ('next_batch', ?) "
                + "ON CONFLICT(key) DO UPDATE SET value = excluded.value;",
              [.text(value)]
            )
          } else {
            try database.run("DELETE FROM sync_state WHERE key = 'next_batch';")
          }
        }
      }
    }
  }

  /// Une page remontée du Relais (`/messages`), écrite telle quelle : ce qui a
  /// été paginé une fois n'aura plus jamais à l'être.
  func upsert(messages list: [ChatMessage], roomID: String) {
    guard !list.isEmpty else { return }
    attempt {
      try database.transaction {
        for message in list { try Self.write(message, roomID: roomID, into: database) }
      }
    }
  }

  // MARK: - Privé

  internal static func write(_ message: ChatMessage, roomID: String, into database: SQLiteDatabase) throws {
    // Un envoi encore en vol n'existe pas côté serveur : il ne s'écrit pas.
    guard !message.isPending else { return }
    let payload = (try? JSONEncoder().encode(message)) ?? Data()
    let names = message.attachments.compactMap(\.filename).joined(separator: " ")
    let types = message.attachments.map(\.contentType).joined(separator: " ")
    try database.run(
      """
      INSERT INTO messages (\(messageColumns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(event_id) DO UPDATE SET
        room_id = excluded.room_id,
        conversation_id = excluded.conversation_id,
        sent_at = excluded.sent_at,
        sender_id = excluded.sender_id,
        sender_name = excluded.sender_name,
        text = excluded.text,
        is_from_me = excluded.is_from_me,
        attachment_names = excluded.attachment_names,
        attachment_types = excluded.attachment_types,
        payload = excluded.payload;
      """,
      [
        .text(message.id),
        .text(roomID),
        .text(message.conversationID),
        .date(message.sentAt),
        .optionalText(message.senderID),
        .optionalText(message.senderName),
        .text(message.text),
        .bool(message.isFromMe),
        .text(names),
        .text(types),
        .blob(payload),
      ]
    )
  }

  internal static func write(
    _ reaction: MatrixRoomModel.ReactionEvent,
    eventID: String,
    roomID: String,
    into database: SQLiteDatabase
  ) throws {
    try database.run(
      """
      INSERT INTO reactions (event_id, room_id, target_event_id, emoji, sender_id, sender_name, is_mine)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(event_id) DO UPDATE SET
        room_id = excluded.room_id,
        target_event_id = excluded.target_event_id,
        emoji = excluded.emoji,
        sender_id = excluded.sender_id,
        sender_name = excluded.sender_name,
        is_mine = excluded.is_mine;
      """,
      [
        .text(eventID),
        .text(roomID),
        .text(reaction.targetEventID),
        .text(reaction.emoji),
        .text(reaction.senderID),
        .text(reaction.senderName),
        .bool(reaction.isMine),
      ]
    )
  }

  internal static func message(in row: SQLiteStatement) -> ChatMessage? {
    guard var message = try? JSONDecoder().decode(ChatMessage.self, from: row.data(10)) else {
      return nil
    }
    // Re-résoudre les chemins : le cache disque des pièces jointes a pu être
    // vidé par le système, alors que la base, elle, est restée.
    message.attachments = message.attachments.map { attachment in
      var copy = attachment
      if copy.resolvedFileURL == nil {
        copy.localPath = MatrixAttachmentStore.existingLocalPath(
          forMXC: attachment.id,
          contentType: attachment.contentType
        )
      }
      return copy
    }
    if var preview = message.linkPreview,
       let path = preview.imageLocalPath,
       !FileManager.default.fileExists(atPath: path)
    {
      preview.imageLocalPath = nil
      message.linkPreview = preview
    }
    return message
  }
}
