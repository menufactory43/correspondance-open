import Foundation
import SQLite3

/// Le juge de paix de l'automatisation : **rien** n'est déclaré réussi tant que
/// `chat.db` ne montre pas la ligne correspondante.
///
/// Il ouvre `chat.db` en lecture seule directement (le `-shm` existe tant que
/// Messages tourne, donc le WAL est visible) ; si l'ouverture échoue, il retombe
/// sur une copie temporaire comme `IMessageDatabase`. Il vit dans son propre
/// fichier pour ne rien déplacer dans `IMessageDatabase.swift`.
struct IMessageAutomationVerifier: Sendable {
  /// Un tapback posé : 2000…2005. Retiré : 3000…3005.
  static let tapbackAddedRange: ClosedRange<Int> = 2000...2005
  static let tapbackRemovedRange: ClosedRange<Int> = 3000...3005

  /// Stocké (et non calculé) pour que les tests puissent viser une fixture.
  var databaseURL: URL

  init(databaseURL: URL? = nil) {
    self.databaseURL = databaseURL ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Messages/chat.db")
  }

  /// Repère d'avant-action : au-delà de ce ROWID, tout est nouveau.
  func latestMessageRowID() throws -> Int64 {
    try withDatabase { db in
      Int64(Self.firstInt(db, "SELECT IFNULL(MAX(ROWID), 0) FROM message;") ?? 0)
    }
  }

  /// Une pièce jointe de moi est-elle partie dans ce fil depuis ce ROWID ?
  ///
  /// `transfer_state` dit tout : `6` est l'échec — Messages n'a pas pu lire le
  /// fichier — et c'est exactement ce qu'on voyait avec `send POSIX file`. Une
  /// ligne d'échec ne compte donc pas pour un envoi.
  func hasSentAttachment(inChatGUID chatGUID: String, sinceRowID: Int64) throws -> Bool {
    try withDatabase { db in
      let count = Self.firstInt(
        db,
        """
        SELECT COUNT(*) FROM message m
        JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        JOIN chat c ON c.ROWID = cmj.chat_id
        JOIN message_attachment_join maj ON maj.message_id = m.ROWID
        JOIN attachment a ON a.ROWID = maj.attachment_id
        WHERE c.guid = ? AND m.ROWID > ? AND m.is_from_me = 1 AND a.transfer_state <> 6;
        """,
        [chatGUID, sinceRowID]
      )
      return (count ?? 0) > 0
    }
  }

  /// Le fil existe-t-il, et si oui quel est son `chat_identifier` ?
  func chatIdentifier(forChatGUID guid: String) throws -> String? {
    try withDatabase { db in
      Self.firstString(db, "SELECT chat_identifier FROM chat WHERE guid = ? LIMIT 1;", [guid])
    }
  }

  /// Le message existe-t-il dans ce fil ? Renvoie son texte et son sens.
  func message(guid: String, inChatGUID chatGUID: String) throws -> (rowID: Int64, text: String, isFromMe: Bool)? {
    try withDatabase { db in
      let sql = """
      SELECT m.ROWID, IFNULL(m.text, ''), m.is_from_me
      FROM message m
      JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
      JOIN chat c ON c.ROWID = cmj.chat_id
      WHERE c.guid = ? AND m.guid = ?
      LIMIT 1;
      """
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
      defer { sqlite3_finalize(statement) }
      Self.bind(statement, [chatGUID, guid])
      guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
      return (
        sqlite3_column_int64(statement, 0),
        Self.text(statement, 1),
        sqlite3_column_int(statement, 2) == 1
      )
    }
  }

  /// Un tapback **de moi** est-il apparu sur ce message depuis `sinceRowID` ?
  /// `removal` cherche un retrait (3000…3005) plutôt qu'une pose.
  func hasTapback(targetGUID: String, sinceRowID: Int64, removal: Bool) throws -> Bool {
    let range = removal ? Self.tapbackRemovedRange : Self.tapbackAddedRange
    let sql = """
    SELECT COUNT(*) FROM message
    WHERE is_from_me = 1
      AND ROWID > ?
      AND associated_message_type BETWEEN \(range.lowerBound) AND \(range.upperBound)
      AND associated_message_guid LIKE ?;
    """
    return try withDatabase { db in
      (Self.firstInt(db, sql, [sinceRowID, "%\(targetGUID)"]) ?? 0) > 0
    }
  }

  /// Une réponse citée **de moi** visant ce message est-elle apparue ?
  func hasReply(toGUID targetGUID: String, sinceRowID: Int64) throws -> Bool {
    let sql = """
    SELECT COUNT(*) FROM message
    WHERE is_from_me = 1
      AND ROWID > ?
      AND thread_originator_guid LIKE ?;
    """
    return try withDatabase { db in
      (Self.firstInt(db, sql, [sinceRowID, "%\(targetGUID)"]) ?? 0) > 0
    }
  }

  /// Nombre de messages reçus non lus dans ce fil (0 = fil lu).
  func unreadCount(chatGUID: String) throws -> Int {
    let sql = """
    SELECT COUNT(*) FROM message m
    JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
    JOIN chat c ON c.ROWID = cmj.chat_id
    WHERE c.guid = ? AND m.is_from_me = 0 AND m.is_read = 0 AND m.item_type = 0
      AND IFNULL(m.associated_message_type, 0) = 0;
    """
    return try withDatabase { db in
      Self.firstInt(db, sql, [chatGUID]) ?? 0
    }
  }

  /// `date_edited` non nul = Messages a bien enregistré la modification.
  func isEdited(messageGUID: String) throws -> Bool {
    try withDatabase { db in
      (Self.firstInt(db, "SELECT IFNULL(date_edited, 0) FROM message WHERE guid = ? LIMIT 1;", [messageGUID]) ?? 0) > 0
    }
  }

  /// `date_retracted` non nul = l'envoi a bien été annulé.
  func isRetracted(messageGUID: String) throws -> Bool {
    try withDatabase { db in
      (Self.firstInt(db, "SELECT IFNULL(date_retracted, 0) FROM message WHERE guid = ? LIMIT 1;", [messageGUID]) ?? 0) > 0
    }
  }

  // MARK: - Attente

  /// Rejoue `check` toutes les 250 ms jusqu'à `timeout` (3 s par défaut).
  /// Renvoie `true` dès que la condition est vraie, `false` à l'expiration.
  func waitUntil(
    timeout: Duration = .seconds(3),
    poll: Duration = .milliseconds(250),
    _ check: @Sendable @escaping () throws -> Bool
  ) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if Task.isCancelled { return false }
      if (try? check()) == true { return true }
      try? await Task.sleep(for: poll)
    }
    return (try? check()) == true
  }

  // MARK: - SQLite

  private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
    if let db = try? openLive() {
      defer { sqlite3_close(db) }
      return try body(db)
    }
    let snapshot = try makeSnapshot()
    defer { try? FileManager.default.removeItem(at: snapshot.deletingLastPathComponent()) }
    guard let db = try? open(path: snapshot.path) else {
      throw IMessageAccessError.authorizationDenied
    }
    defer { sqlite3_close(db) }
    return try body(db)
  }

  /// Lecture directe du fichier vivant : le `-shm` de Messages rend le WAL visible,
  /// ce qui est indispensable pour voir une ligne écrite il y a 200 ms.
  private func openLive() throws -> OpaquePointer {
    try open(path: databaseURL.path)
  }

  private func open(path: String) throws -> OpaquePointer {
    var db: OpaquePointer?
    let status = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
    guard status == SQLITE_OK, let db else {
      if let db { sqlite3_close(db) }
      throw IMessageAccessError.authorizationDenied
    }
    sqlite3_busy_timeout(db, 1_500)
    // Une requête témoin : un accès refusé ne se voit qu'à la première lecture.
    guard Self.firstInt(db, "SELECT 1 FROM message LIMIT 1;") != nil else {
      sqlite3_close(db)
      throw IMessageAccessError.authorizationDenied
    }
    return db
  }

  private func makeSnapshot() throws -> URL {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory
      .appendingPathComponent("correspondance-ax-verify-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let dest = dir.appendingPathComponent("chat.db")
    do {
      try fm.copyItem(at: databaseURL, to: dest)
      for suffix in ["-wal", "-shm"] {
        let side = URL(fileURLWithPath: databaseURL.path + suffix)
        if fm.fileExists(atPath: side.path) {
          try? fm.copyItem(at: side, to: URL(fileURLWithPath: dest.path + suffix))
        }
      }
    } catch {
      try? fm.removeItem(at: dir)
      throw IMessageAccessError.authorizationDenied
    }
    return dest
  }

  // MARK: - Petits utilitaires SQLite

  /// Valeurs liables : `String` ou `Int64`. Suffisant pour ces requêtes.
  private static func bind(_ statement: OpaquePointer?, _ values: [any Sendable]) {
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (index, value) in values.enumerated() {
      let position = Int32(index + 1)
      switch value {
      case let text as String:
        sqlite3_bind_text(statement, position, text, -1, transient)
      case let number as Int64:
        sqlite3_bind_int64(statement, position, number)
      case let number as Int:
        sqlite3_bind_int64(statement, position, Int64(number))
      default:
        sqlite3_bind_null(statement, position)
      }
    }
  }

  private static func text(_ statement: OpaquePointer?, _ index: Int32) -> String {
    guard let raw = sqlite3_column_text(statement, index) else { return "" }
    return String(cString: raw)
  }

  private static func firstInt(_ db: OpaquePointer, _ sql: String, _ values: [any Sendable] = []) -> Int? {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(statement) }
    bind(statement, values)
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    return Int(sqlite3_column_int64(statement, 0))
  }

  private static func firstString(_ db: OpaquePointer, _ sql: String, _ values: [any Sendable] = []) -> String? {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(statement) }
    bind(statement, values)
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    return text(statement, 0)
  }
}
