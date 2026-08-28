import Foundation
import SQLite3

enum IMessageAccessError: LocalizedError, Sendable {
  case authorizationDenied
  case openFailed(String)
  case queryFailed(String)

  var errorDescription: String? {
    switch self {
    case .authorizationDenied:
      "Accès refusé à Messages. Accorde « Accès complet au disque » à Correspondance (Réglages Système → Confidentialité)."
    case .openFailed(let detail):
      "Impossible d’ouvrir chat.db : \(detail)"
    case .queryFailed(let detail):
      "Lecture Messages impossible : \(detail)"
    }
  }
}

/// Lecture locale de `~/Library/Messages/chat.db` via **copie temporaire**
/// (évite les locks / freezes avec l’app Messages).
struct IMessageDatabase: Sendable {
  var databaseURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Messages/chat.db")
  }

  func fetchConversations(limit: Int = 80) throws -> [Conversation] {
    let snapshot = try makeSnapshot()
    defer { try? FileManager.default.removeItem(at: snapshot) }

    let db = try openReadOnly(at: snapshot)
    defer { sqlite3_close(db) }

    // Requête plate + dédup en Swift — évite le sous-select corrélé (très lent).
    let sql = """
    SELECT
      c.ROWID,
      c.guid,
      c.chat_identifier,
      IFNULL(c.display_name, ''),
      IFNULL(c.service_name, ''),
      IFNULL(m.text, ''),
      IFNULL(m.date, 0)
    FROM message m
    JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
    JOIN chat c ON c.ROWID = cmj.chat_id
    WHERE m.text IS NOT NULL AND m.text != ''
    ORDER BY m.date DESC
    LIMIT 800;
    """

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      throw IMessageAccessError.queryFailed(String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(statement) }

    var seen = Set<String>()
    var results: [Conversation] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      let rowID = sqlite3_column_int64(statement, 0)
      let guid = stringColumn(statement, 1)
      if seen.contains(guid) { continue }
      seen.insert(guid)

      let identifier = stringColumn(statement, 2)
      let displayName = stringColumn(statement, 3)
      _ = stringColumn(statement, 4)
      let text = stringColumn(statement, 5)
      let rawDate = sqlite3_column_int64(statement, 6)

      let title = displayName.isEmpty ? prettyHandle(identifier) : displayName
      results.append(
        Conversation(
          id: "imessage:\(guid)",
          network: .iMessage,
          address: identifier,
          title: title,
          preview: text,
          lastMessageAt: Self.dateFromApple(rawDate),
          unreadCount: 0,
          isArchived: false,
          transportKey: "\(rowID)|\(guid)|\(identifier)",
          isGroup: identifier.hasPrefix("chat")
        )
      )
      if results.count >= limit { break }
    }
    return results
  }

  func fetchMessages(chatGUID: String, limit: Int = 120) throws -> [ChatMessage] {
    let snapshot = try makeSnapshot()
    defer { try? FileManager.default.removeItem(at: snapshot) }

    let db = try openReadOnly(at: snapshot)
    defer { sqlite3_close(db) }

    let sql = """
    SELECT
      m.ROWID,
      IFNULL(m.guid, ''),
      IFNULL(m.text, ''),
      IFNULL(m.date, 0),
      IFNULL(m.is_from_me, 0),
      c.guid
    FROM message m
    JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
    JOIN chat c ON c.ROWID = cmj.chat_id
    WHERE c.guid = ?
      AND m.text IS NOT NULL
      AND m.text != ''
    ORDER BY m.date DESC
    LIMIT ?;
    """

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      throw IMessageAccessError.queryFailed(String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(statement) }

    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    _ = chatGUID.withCString { cString in
      sqlite3_bind_text(statement, 1, cString, -1, transient)
    }
    sqlite3_bind_int(statement, 2, Int32(limit))

    var rows: [ChatMessage] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      let rowID = sqlite3_column_int64(statement, 0)
      let guid = stringColumn(statement, 1)
      let text = stringColumn(statement, 2)
      let rawDate = sqlite3_column_int64(statement, 3)
      let fromMe = sqlite3_column_int(statement, 4) != 0
      let conversationID = "imessage:\(stringColumn(statement, 5))"

      rows.append(
        ChatMessage(
          id: guid.isEmpty ? "imessage-msg-\(rowID)" : guid,
          conversationID: conversationID,
          network: .iMessage,
          text: text,
          sentAt: Self.dateFromApple(rawDate),
          isFromMe: fromMe
        )
      )
    }
    return rows.reversed()
  }

  // MARK: - Private

  /// Copie chat.db (+ wal/shm si présents) pour ne pas bloquer Messages.
  private func makeSnapshot() throws -> URL {
    let fm = FileManager.default
    guard fm.isReadableFile(atPath: databaseURL.path) else {
      throw IMessageAccessError.authorizationDenied
    }

    let dir = fm.temporaryDirectory.appendingPathComponent("correspondance-imessage-\(UUID().uuidString)", isDirectory: true)
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
      if Self.isPermissionError(error) {
        throw IMessageAccessError.authorizationDenied
      }
      throw IMessageAccessError.openFailed(error.localizedDescription)
    }
    return dest
  }

  private func openReadOnly(at url: URL) throws -> OpaquePointer {
    var db: OpaquePointer?
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
    let status = sqlite3_open_v2(url.path, &db, flags, nil)
    if status == SQLITE_AUTH || status == SQLITE_CANTOPEN || status == SQLITE_PERM {
      if let db { sqlite3_close(db) }
      throw IMessageAccessError.authorizationDenied
    }
    guard status == SQLITE_OK, let db else {
      let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
      if let db { sqlite3_close(db) }
      if message.localizedCaseInsensitiveContains("authorization")
        || message.localizedCaseInsensitiveContains("denied")
      {
        throw IMessageAccessError.authorizationDenied
      }
      throw IMessageAccessError.openFailed(message)
    }
    sqlite3_busy_timeout(db, 2_000)
    return db
  }

  private func stringColumn(_ statement: OpaquePointer?, _ index: Int32) -> String {
    guard let cString = sqlite3_column_text(statement, index) else { return "" }
    return String(cString: cString)
  }

  private func prettyHandle(_ identifier: String) -> String {
    if identifier.hasPrefix("chat") { return "Groupe" }
    return identifier
  }

  static func dateFromApple(_ raw: Int64) -> Date {
    if raw > 10_000_000_000 {
      return Date(timeIntervalSinceReferenceDate: Double(raw) / 1_000_000_000)
    }
    return Date(timeIntervalSinceReferenceDate: Double(raw))
  }

  static func guid(fromConversationID id: String) -> String? {
    guard id.hasPrefix("imessage:") else { return nil }
    return String(id.dropFirst("imessage:".count))
  }

  private static func isPermissionError(_ error: Error) -> Bool {
    let ns = error as NSError
    // NSFileReadNoPermissionError = 257 ; POSIX EPERM/EACCES often surface as Cocoa/NSPOSIX.
    if ns.domain == NSPOSIXErrorDomain && (ns.code == Int(EPERM) || ns.code == Int(EACCES)) {
      return true
    }
    if ns.domain == NSCocoaErrorDomain && (ns.code == NSFileReadNoPermissionError || ns.code == 257 || ns.code == 513) {
      return true
    }
    let text = error.localizedDescription.lowercased()
    return text.contains("permission")
      || text.contains("denied")
      || text.contains("not permitted")
      || text.contains("autoris")
  }
}
