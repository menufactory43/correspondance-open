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

    // Requête plate + dédup en Swift — texte OU pièce jointe (photos sans légende).
    let sql = """
    SELECT
      c.ROWID,
      c.guid,
      c.chat_identifier,
      IFNULL(c.display_name, ''),
      IFNULL(c.service_name, ''),
      IFNULL(m.text, ''),
      IFNULL(m.date, 0),
      CASE WHEN EXISTS (
        SELECT 1 FROM message_attachment_join maj
        WHERE maj.message_id = m.ROWID
      ) THEN 1 ELSE 0 END,
      IFNULL(m.is_from_me, 0),
      IFNULL(m.is_delivered, 0),
      IFNULL(m.is_read, 0)
    FROM message m
    JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
    JOIN chat c ON c.ROWID = cmj.chat_id
    WHERE
      (m.text IS NOT NULL AND m.text != '')
      OR EXISTS (
        SELECT 1 FROM message_attachment_join maj
        WHERE maj.message_id = m.ROWID
      )
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
      var text = stringColumn(statement, 5)
      let rawDate = sqlite3_column_int64(statement, 6)
      let hasAttachment = sqlite3_column_int(statement, 7) != 0
      let lastFromMe = sqlite3_column_int(statement, 8) != 0
      let lastDelivered = sqlite3_column_int(statement, 9) != 0
      let lastRead = sqlite3_column_int(statement, 10) != 0

      if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, hasAttachment {
        // Détail mime résolu à l’ouverture du fil — aperçu générique ici.
        text = "📷 Photo"
      }

      let isGroup = identifier.hasPrefix("chat")
      // Toujours récupérer les handles (1:1 = peer ; groupe = participants).
      let participantHandles = fetchHandles(chatRowID: rowID, db: db)
      let peerHandle = participantHandles.first ?? identifier
      let title: String = {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if isGroup {
          if participantHandles.isEmpty { return "Groupe" }
          // Libellé provisoire — ContactDirectory enrichira avec les vrais noms.
          return participantHandles.prefix(3).map(prettyHandle).joined(separator: ", ")
            + (participantHandles.count > 3 ? "…" : "")
        }
        return prettyHandle(peerHandle)
      }()

      // address = identifiant chat (envoi). transportKey embarque les handles Contacts.
      let handlesForLookup = isGroup ? participantHandles : (participantHandles.isEmpty ? [peerHandle] : participantHandles)
      let handleSuffix = handlesForLookup.isEmpty ? "" : "|\(handlesForLookup.joined(separator: ","))"
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
          transportKey: "\(rowID)|\(guid)|\(identifier)\(handleSuffix)",
          isGroup: isGroup,
          lastDelivery: Self.delivery(fromMe: lastFromMe, delivered: lastDelivered, read: lastRead),
          lastMessageIsFromMe: lastFromMe
        )
      )
      if results.count >= limit { break }
    }
    return results
  }

  /// Index de recherche : le corps des messages récents, par conversation.
  ///
  /// Une seule passe SQL sur la copie de `chat.db`, bornée : la recherche de l'inbox
  /// doit rester instantanée et tenir en mémoire. Au-delà de `limit` messages, les
  /// plus anciens ne sont pas indexés — comme Beeper, qui ne cherche que ce qu'il a chargé.
  func fetchSearchIndex(limit: Int = 6_000) throws -> [String: String] {
    let snapshot = try makeSnapshot()
    defer { try? FileManager.default.removeItem(at: snapshot) }

    let db = try openReadOnly(at: snapshot)
    defer { sqlite3_close(db) }

    let sql = """
    SELECT c.guid, m.text
    FROM message m
    JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
    JOIN chat c ON c.ROWID = cmj.chat_id
    WHERE m.text IS NOT NULL AND m.text != ''
    ORDER BY m.date DESC
    LIMIT ?;
    """

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      throw IMessageAccessError.queryFailed(String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_int(statement, 1, Int32(limit))

    var parts: [String: [String]] = [:]
    while sqlite3_step(statement) == SQLITE_ROW {
      let guid = stringColumn(statement, 0)
      guard !guid.isEmpty else { continue }
      parts["imessage:\(guid)", default: []].append(stringColumn(statement, 1))
    }
    return parts.mapValues { ConversationSearch.fold($0.joined(separator: "\n")) }
  }

  /// Coche « livré / vu » du dernier message : seulement s'il est sortant.
  private static func delivery(fromMe: Bool, delivered: Bool, read: Bool) -> MessageDelivery? {
    guard fromMe else { return nil }
    if read { return .read }
    if delivered { return .delivered }
    return .sent
  }

  func fetchMessages(chatGUID: String, limit: Int = 120) throws -> [ChatMessage] {
    let snapshot = try makeSnapshot()
    defer { try? FileManager.default.removeItem(at: snapshot) }

    let db = try openReadOnly(at: snapshot)
    defer { sqlite3_close(db) }

    // Inclut les messages texte ET les messages image-only (sans texte).
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
      AND (
        (m.text IS NOT NULL AND m.text != '')
        OR EXISTS (
          SELECT 1 FROM message_attachment_join maj
          WHERE maj.message_id = m.ROWID
        )
      )
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

    var drafts: [(rowID: Int64, message: ChatMessage)] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      let rowID = sqlite3_column_int64(statement, 0)
      let guid = stringColumn(statement, 1)
      let text = stringColumn(statement, 2)
      let rawDate = sqlite3_column_int64(statement, 3)
      let fromMe = sqlite3_column_int(statement, 4) != 0
      let conversationID = "imessage:\(stringColumn(statement, 5))"

      drafts.append(
        (
          rowID,
          ChatMessage(
            id: guid.isEmpty ? "imessage-msg-\(rowID)" : guid,
            conversationID: conversationID,
            network: .iMessage,
            text: text,
            sentAt: Self.dateFromApple(rawDate),
            isFromMe: fromMe
          )
        )
      )
    }

    let attachmentsByRow = fetchAttachments(
      messageRowIDs: drafts.map(\.rowID),
      db: db
    )

    var rows: [ChatMessage] = []
    rows.reserveCapacity(drafts.count)
    for draft in drafts {
      var message = draft.message
      message.attachments = attachmentsByRow[draft.rowID] ?? []
      if message.text.isEmpty, message.attachments.contains(where: \.isImage) {
        message = ChatMessage(
          id: message.id,
          conversationID: message.conversationID,
          network: message.network,
          text: "📷 Photo",
          sentAt: message.sentAt,
          isFromMe: message.isFromMe,
          attachments: message.attachments
        )
      } else if message.text.isEmpty, !message.attachments.isEmpty {
        message = ChatMessage(
          id: message.id,
          conversationID: message.conversationID,
          network: message.network,
          text: "Pièce jointe",
          sentAt: message.sentAt,
          isFromMe: message.isFromMe,
          attachments: message.attachments
        )
      }
      rows.append(message)
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

  private func fetchAttachments(
    messageRowIDs: [Int64],
    db: OpaquePointer
  ) -> [Int64: [MessageAttachment]] {
    guard !messageRowIDs.isEmpty else { return [:] }

    // Chunk pour rester sous la limite SQLite de variables liées.
    var result: [Int64: [MessageAttachment]] = [:]
    let chunkSize = 200
    var start = 0
    while start < messageRowIDs.count {
      let end = min(start + chunkSize, messageRowIDs.count)
      let chunk = Array(messageRowIDs[start..<end])
      start = end

      let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
      let sql = """
      SELECT
        maj.message_id,
        a.ROWID,
        IFNULL(a.guid, ''),
        IFNULL(a.filename, ''),
        IFNULL(a.mime_type, ''),
        IFNULL(a.transfer_name, ''),
        IFNULL(a.uti, '')
      FROM message_attachment_join maj
      JOIN attachment a ON a.ROWID = maj.attachment_id
      WHERE maj.message_id IN (\(placeholders));
      """

      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { continue }
      defer { sqlite3_finalize(statement) }

      for (index, rowID) in chunk.enumerated() {
        sqlite3_bind_int64(statement, Int32(index + 1), rowID)
      }

      while sqlite3_step(statement) == SQLITE_ROW {
        let messageID = sqlite3_column_int64(statement, 0)
        let attachmentRow = sqlite3_column_int64(statement, 1)
        let guid = stringColumn(statement, 2)
        let filename = stringColumn(statement, 3)
        let mime = stringColumn(statement, 4)
        let transferName = stringColumn(statement, 5)
        let uti = stringColumn(statement, 6)

        let contentType = resolvedContentType(mime: mime, uti: uti, path: filename)
        let localPath = resolveAttachmentFilesystemPath(filename)
        let displayName = transferName.isEmpty
          ? (localPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "fichier")
          : transferName

        let attachment = MessageAttachment(
          id: guid.isEmpty ? "imsg-att-\(attachmentRow)" : guid,
          contentType: contentType,
          filename: displayName,
          localPath: localPath
        )
        result[messageID, default: []].append(attachment)
      }
    }
    return result
  }

  /// `attachment.filename` est souvent `~/Library/Messages/Attachments/...`.
  private func resolveAttachmentFilesystemPath(_ stored: String) -> String? {
    let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let expanded: String
    if trimmed.hasPrefix("~/") {
      expanded = FileManager.default.homeDirectoryForCurrentUser.path
        + String(trimmed.dropFirst())
    } else if trimmed.hasPrefix("/") {
      expanded = trimmed
    } else {
      expanded = FileManager.default.homeDirectoryForCurrentUser.path
        + "/Library/Messages/" + trimmed
    }

    if FileManager.default.fileExists(atPath: expanded) {
      return expanded
    }
    return nil
  }

  private func resolvedContentType(mime: String, uti: String, path: String) -> String {
    if !mime.isEmpty { return mime }
    let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
    switch ext {
    case "jpg", "jpeg": return "image/jpeg"
    case "png": return "image/png"
    case "gif": return "image/gif"
    case "heic", "heif": return "image/heic"
    case "webp": return "image/webp"
    case "tif", "tiff": return "image/tiff"
    case "mp4", "mov", "m4v": return "video/mp4"
    default:
      if uti.contains("image") { return "image/jpeg" }
      if uti.contains("movie") || uti.contains("video") { return "video/mp4" }
      return "application/octet-stream"
    }
  }

  private func fetchHandles(chatRowID: Int64, db: OpaquePointer) -> [String] {
    let sql = """
    SELECT IFNULL(h.id, ''), IFNULL(h.uncanonicalized_id, '')
    FROM chat_handle_join chj
    JOIN handle h ON h.ROWID = chj.handle_id
    WHERE chj.chat_id = ?
    ORDER BY h.ROWID ASC
    LIMIT 8;
    """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_int64(statement, 1, chatRowID)

    var handles: [String] = []
    var seen = Set<String>()
    while sqlite3_step(statement) == SQLITE_ROW {
      for index: Int32 in [0, 1] {
        let handle = stringColumn(statement, index)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !handle.isEmpty, !seen.contains(handle) else { continue }
        seen.insert(handle)
        handles.append(handle)
      }
    }
    return handles
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
