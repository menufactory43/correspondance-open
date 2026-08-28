import Foundation

/// Pont Signal via `signal-cli`. **Un seul process à la fois** (le datastore ne supporte pas le parallèle).
actor SignalBridge {
  var cliPath: String?

  private var cachedMessages: [String: [ChatMessage]] = [:]
  private var lastAccountLabel: String?
  private var didLoadDiskCache = false

  func resolvedCLI() -> String? {
    if let cliPath, FileManager.default.isExecutableFile(atPath: cliPath) {
      return cliPath
    }
    let homebrew = "/opt/homebrew/bin/signal-cli"
    if FileManager.default.isExecutableFile(atPath: homebrew) {
      return homebrew
    }
    return Self.which("signal-cli")
  }

  func statusMessageFR() async -> String {
    guard let cli = resolvedCLI() else {
      return "signal-cli absent. brew install signal-cli puis link."
    }
    do {
      let result = try await ProcessRunner.run(
        executable: cli,
        arguments: ["listAccounts"],
        timeoutSeconds: 40
      )
      if result.exitCode == 0, let number = Self.extractPhone(from: result.stdout) {
        lastAccountLabel = number
        return "Signal lié (\(number))."
      }
      if result.exitCode == 0 {
        return "signal-cli OK — pas encore lié ? signal-cli link -n Correspondance"
      }
      return "Signal : \(result.stderr.isEmpty ? result.stdout : result.stderr)"
    } catch {
      return "Signal ne répond pas : \(error.localizedDescription)"
    }
  }

  func fetchConversations() async throws -> [Conversation] {
    guard let cli = resolvedCLI() else { return [] }

    // Cache disque : un refresh ne doit pas effacer les groupes si listGroups/receive glitch.
    let (storedConversations, storedMessages) = SignalConversationCache.load()
    if !didLoadDiskCache {
      cachedMessages = storedMessages
      didLoadDiskCache = true
    }

    var byID: [String: Conversation] = [:]
    for c in storedConversations {
      byID[c.id] = c
    }
    var messagesByID = cachedMessages.isEmpty ? storedMessages : cachedMessages
    // Répare les previews « Groupe Signal » si des messages sont déjà en cache.
    Self.syncPreviews(from: messagesByID, into: &byID)

    var groupErrors: [String] = []

    // 1) Groupes d’abord (liste complète)
    do {
      let groupsResult = try await ProcessRunner.run(
        executable: cli,
        arguments: ["-o", "json", "listGroups"],
        timeoutSeconds: 90
      )
      if groupsResult.exitCode == 0 {
        let before = byID.values.filter(\.isGroup).count
        Self.mergeGroups(groupsResult.stdout, into: &byID)
        let after = byID.values.filter(\.isGroup).count
        if after == 0 {
          groupErrors.append("listGroups OK mais 0 membre")
        } else if after < before {
          // Ne devrait pas arriver — on merge, on n’efface pas.
        }
      } else {
        groupErrors.append(groupsResult.stderr.isEmpty ? "listGroups exit \(groupsResult.exitCode)" : groupsResult.stderr)
      }
    } catch {
      groupErrors.append(error.localizedDescription)
    }

    // 2) Receive — enrichit previews / messages (consomme le serveur)
    do {
      let receiveResult = try await ProcessRunner.run(
        executable: cli,
        arguments: [
          "-o", "json", "receive",
          "-t", "2",
          "--max-messages", "80",
          "--ignore-stories",
        ],
        timeoutSeconds: 90
      )
      if receiveResult.exitCode == 0 {
        Self.parseReceive(
          receiveResult.stdout,
          conversations: &byID,
          messages: &messagesByID
        )
      }
    } catch {
      groupErrors.append("receive: \(error.localizedDescription)")
    }

    // 3) Contacts DM
    do {
      let contactsResult = try await ProcessRunner.run(
        executable: cli,
        arguments: ["-o", "json", "listContacts"],
        timeoutSeconds: 90
      )
      if contactsResult.exitCode == 0 {
        Self.mergeContacts(contactsResult.stdout, into: &byID)
      } else if byID.isEmpty {
        throw SignalBridgeError.commandFailed(
          contactsResult.stderr.isEmpty ? contactsResult.stdout : contactsResult.stderr
        )
      }
    } catch {
      if byID.isEmpty { throw error }
      groupErrors.append("contacts: \(error.localizedDescription)")
    }

    cachedMessages = messagesByID
    Self.syncPreviews(from: messagesByID, into: &byID)
    let list = Array(byID.values).sorted { $0.lastMessageAt > $1.lastMessageAt }
    SignalConversationCache.save(conversations: list, messages: messagesByID)

    if !groupErrors.isEmpty, list.filter(\.isGroup).isEmpty {
      throw SignalBridgeError.commandFailed(groupErrors.joined(separator: " · "))
    }

    return list
  }

  func fetchMessages(conversationID: String) async -> [ChatMessage] {
    cachedMessages[conversationID] ?? []
  }

  func messageCounts() async -> [String: Int] {
    Dictionary(uniqueKeysWithValues: cachedMessages.map { ($0.key, $0.value.count) })
  }

  /// Dernier texte connu par conversation (pour resync sidebar).
  func previewMap() async -> [String: (text: String, date: Date)] {
    var map: [String: (String, Date)] = [:]
    for (id, list) in cachedMessages {
      guard let last = list.last else { continue }
      map[id] = (last.sidebarPreviewText, last.sentAt)
    }
    return map
  }

  /// Poll léger type app Signal : uniquement `receive` (pas listGroups/contacts).
  /// Retourne les conversations mises à jour (cache + nouveaux messages).
  @discardableResult
  func pollReceive(timeoutSeconds: Int = 12) async throws -> [Conversation] {
    guard let cli = resolvedCLI() else { return [] }

    if !didLoadDiskCache {
      let (stored, storedMessages) = SignalConversationCache.load()
      cachedMessages = storedMessages
      didLoadDiskCache = true
      _ = stored
    }

    let receiveResult = try await ProcessRunner.run(
      executable: cli,
      arguments: [
        "-o", "json", "receive",
        "-t", "\(timeoutSeconds)",
        "--max-messages", "150",
        "--ignore-stories",
      ],
      timeoutSeconds: TimeInterval(timeoutSeconds + 40)
    )

    var byID: [String: Conversation] = [:]
    let (stored, storedMessages) = SignalConversationCache.load()
    for c in stored { byID[c.id] = c }
    var messagesByID = cachedMessages.isEmpty ? storedMessages : cachedMessages

    if receiveResult.exitCode == 0, !receiveResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      Self.parseReceive(receiveResult.stdout, conversations: &byID, messages: &messagesByID)
    }

    cachedMessages = messagesByID
    Self.syncPreviews(from: messagesByID, into: &byID)
    let list = Array(byID.values).sorted { $0.lastMessageAt > $1.lastMessageAt }
    SignalConversationCache.save(conversations: list, messages: messagesByID)
    return list
  }

  func ensureMemoryCacheLoaded() {
    if !didLoadDiskCache {
      let (_, storedMessages) = SignalConversationCache.load()
      cachedMessages = storedMessages
      didLoadDiskCache = true
    }
  }

  /// Remet preview / date à partir du dernier message connu (sidebar).
  private static func syncPreviews(
    from messages: [String: [ChatMessage]],
    into conversations: inout [String: Conversation]
  ) {
    for (id, list) in messages {
      guard let last = list.last else { continue }
      guard var conversation = conversations[id] else { continue }
      conversation.preview = last.sidebarPreviewText
      conversation.lastMessageAt = max(conversation.lastMessageAt, last.sentAt)
      conversations[id] = conversation
    }
  }

  func send(
    text: String,
    conversation: Conversation,
    attachmentPaths: [String] = []
  ) async throws {
    guard let cli = resolvedCLI() else { throw SignalBridgeError.cliMissing }

    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let isGroup = conversation.isGroup || conversation.id.hasPrefix("signal-group:")
    if trimmed.isEmpty && attachmentPaths.isEmpty {
      throw SignalBridgeError.sendFailed("Message vide.")
    }

    var arguments: [String] = ["send"]
    if isGroup {
      arguments += ["-g", conversation.transportKey]
    }
    arguments += ["-m", trimmed]
    for path in attachmentPaths {
      arguments += ["-a", path]
    }
    if !isGroup {
      arguments.append(conversation.address)
    }

    let result = try await ProcessRunner.run(
      executable: cli,
      arguments: arguments,
      timeoutSeconds: 120
    )
    guard result.exitCode == 0 else {
      throw SignalBridgeError.sendFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
    }

    let outgoingAttachments: [MessageAttachment] = attachmentPaths.map { path in
      let url = URL(fileURLWithPath: path)
      let ext = url.pathExtension.lowercased()
      let type: String = {
        switch ext {
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic", "heif": return "image/heic"
        default: return "image/jpeg"
        }
      }()
      return MessageAttachment(
        id: url.lastPathComponent,
        contentType: type,
        filename: url.lastPathComponent,
        localPath: path
      )
    }

    var list = cachedMessages[conversation.id] ?? []
    let body = trimmed.isEmpty && !outgoingAttachments.isEmpty ? "📷 Photo" : trimmed
    list.append(
      ChatMessage(
        id: "local-\(UUID().uuidString)",
        conversationID: conversation.id,
        network: .signal,
        text: body,
        sentAt: Date(),
        isFromMe: true,
        attachments: outgoingAttachments
      )
    )
    cachedMessages[conversation.id] = list

    var (stored, msgs) = SignalConversationCache.load()
    msgs[conversation.id] = list
    if let idx = stored.firstIndex(where: { $0.id == conversation.id }) {
      stored[idx].preview = list.last?.sidebarPreviewText ?? body
      stored[idx].lastMessageAt = Date()
    }
    SignalConversationCache.save(conversations: stored, messages: msgs)
  }

  // MARK: - Merge helpers

  private static func mergeGroups(_ raw: String, into conversations: inout [String: Conversation]) {
    guard let data = raw.data(using: .utf8),
          let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { return }

    let now = Date()
    for item in array {
      guard let groupID = item["id"] as? String, !groupID.isEmpty else { continue }
      if let isMember = item["isMember"] as? Bool, !isMember { continue }
      if item["isBlocked"] as? Bool == true { continue }

      let name = (item["name"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let members = item["members"] as? [[String: Any]] ?? []
      let title = (name?.isEmpty == false)
        ? name!
        : "Groupe (\(max(members.count, 1)))"

      let id = "signal-group:\(groupID)"
      if var existing = conversations[id] {
        // Enrichir le titre si on n’avait qu’un placeholder.
        if existing.title.hasPrefix("Groupe"), let name, !name.isEmpty {
          existing.title = name
          conversations[id] = existing
        }
        continue
      }

      conversations[id] = Conversation(
        id: id,
        network: .signal,
        address: groupID,
        title: title,
        // Date neutre : le tri UI met les groupes dans leur section,
        // pas tout en bas à cause d’un -2 jours artificiel.
        preview: "Groupe Signal",
        lastMessageAt: now,
        unreadCount: 0,
        isArchived: false,
        transportKey: groupID,
        isGroup: true
      )
    }
  }

  /// Receive ciblé pour remplir un fil vide (historique serveur non stocké par signal-cli).
  func pullLatestMessages(for conversationID: String) async -> [ChatMessage] {
    guard let cli = resolvedCLI() else { return cachedMessages[conversationID] ?? [] }

    do {
      let receiveResult = try await ProcessRunner.run(
        executable: cli,
        arguments: [
          "-o", "json", "receive",
          "-t", "5",
          "--max-messages", "120",
          "--ignore-stories",
        ],
        timeoutSeconds: 90
      )
      guard receiveResult.exitCode == 0 else {
        return cachedMessages[conversationID] ?? []
      }

      var byID: [String: Conversation] = [:]
      for (id, _) in cachedMessages {
        byID[id] = Conversation(
          id: id,
          network: .signal,
          address: id.replacingOccurrences(of: "signal-group:", with: "")
            .replacingOccurrences(of: "signal:", with: ""),
          title: id,
          preview: "",
          lastMessageAt: Date(),
          unreadCount: 0,
          isArchived: false,
          transportKey: id.replacingOccurrences(of: "signal-group:", with: "")
            .replacingOccurrences(of: "signal:", with: ""),
          isGroup: id.hasPrefix("signal-group:")
        )
      }
      var messagesByID = cachedMessages
      Self.parseReceive(receiveResult.stdout, conversations: &byID, messages: &messagesByID)
      cachedMessages = messagesByID
      Self.syncPreviews(from: messagesByID, into: &byID)

      let (stored, _) = SignalConversationCache.load()
      var merged = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0) })
      for (_, c) in byID {
        if var existing = merged[c.id] {
          if c.hasLivePreview {
            existing.preview = c.preview
            existing.lastMessageAt = max(existing.lastMessageAt, c.lastMessageAt)
            existing.title = c.title
          }
          // Aussi si on a des messages en cache pour cet id.
          if let last = messagesByID[c.id]?.last {
            existing.preview = last.text
            existing.lastMessageAt = max(existing.lastMessageAt, last.sentAt)
          }
          merged[c.id] = existing
        } else if c.hasLivePreview || c.isGroup {
          merged[c.id] = c
        }
      }
      // Préviews depuis tous les messages connus.
      for (id, list) in messagesByID {
        guard let last = list.last, var existing = merged[id] else { continue }
        existing.preview = last.text
        existing.lastMessageAt = max(existing.lastMessageAt, last.sentAt)
        merged[id] = existing
      }
      SignalConversationCache.save(
        conversations: Array(merged.values),
        messages: messagesByID
      )
    } catch {
      // Garde le cache.
    }
    return cachedMessages[conversationID] ?? []
  }

  private static func mergeContacts(_ raw: String, into conversations: inout [String: Conversation]) {
    guard let data = raw.data(using: .utf8),
          let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { return }

    for item in array {
      let number = item["number"] as? String
      let uuid = item["uuid"] as? String
      guard let address = number ?? uuid, !address.isEmpty else { continue }
      if item["isArchived"] as? Bool == true { continue }

      let id = "signal:\(address)"
      if conversations[id] != nil { continue }

      let profile = item["profile"] as? [String: Any]
      let given = profile?["givenName"] as? String
      let family = profile?["familyName"] as? String
      let name = item["name"] as? String
      let title: String = {
        if let name, !name.isEmpty { return name }
        let parts = [given, family].compactMap { $0 }.filter { !$0.isEmpty }
        if !parts.isEmpty { return parts.joined(separator: " ") }
        return address
      }()

      conversations[id] = Conversation(
        id: id,
        network: .signal,
        address: address,
        title: title,
        preview: "Écrire sur Signal…",
        lastMessageAt: Date().addingTimeInterval(-86_400),
        unreadCount: 0,
        isArchived: false,
        transportKey: address,
        isGroup: false
      )
    }
  }

  private static func parseReceive(
    _ raw: String,
    conversations: inout [String: Conversation],
    messages: inout [String: [ChatMessage]]
  ) {
    let chunks = raw
      .split(whereSeparator: \.isNewline)
      .map(String.init)
      .filter { $0.contains("{") }

    for chunk in chunks {
      guard let data = chunk.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { continue }

      let envelope = root["envelope"] as? [String: Any] ?? root
      let dataMessage = envelope["dataMessage"] as? [String: Any]
      let body = (dataMessage?["message"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

      let groupInfo = dataMessage?["groupInfo"] as? [String: Any]
      let groupID = groupInfo?["groupId"] as? String
      let groupName = groupInfo?["groupName"] as? String

      let sourceNumber = envelope["sourceNumber"] as? String
      let sourceUuid = envelope["sourceUuid"] as? String ?? envelope["source"] as? String
      let sourceName = envelope["sourceName"] as? String

      let conversationKey: String
      let title: String
      let address: String
      let isGroup: Bool
      if let groupID {
        conversationKey = "signal-group:\(groupID)"
        title = groupName?.isEmpty == false ? groupName! : "Groupe Signal"
        address = groupID
        isGroup = true
      } else if let sourceNumber {
        conversationKey = "signal:\(sourceNumber)"
        title = (sourceName?.isEmpty == false ? sourceName! : sourceNumber)
        address = sourceNumber
        isGroup = false
      } else if let sourceUuid {
        conversationKey = "signal:\(sourceUuid)"
        title = (sourceName?.isEmpty == false ? sourceName! : sourceUuid)
        address = sourceUuid
        isGroup = false
      } else {
        continue
      }

      let attachments = dataMessage.map { SignalAttachmentStore.parseAttachments(from: $0) } ?? []
      let reaction = dataMessage?["reaction"] as? [String: Any]
      let reactionEmoji = reaction?["emoji"] as? String
      let displayText: String = {
        if !body.isEmpty {
          if isGroup, let sourceName, !sourceName.isEmpty {
            return "\(sourceName): \(body)"
          }
          return body
        }
        if let reactionEmoji {
          if isGroup, let sourceName, !sourceName.isEmpty {
            return "\(sourceName): \(reactionEmoji)"
          }
          return reactionEmoji
        }
        if attachments.contains(where: \.isImage) {
          if isGroup, let sourceName, !sourceName.isEmpty {
            return "\(sourceName): 📷 Photo"
          }
          return "📷 Photo"
        }
        if !attachments.isEmpty {
          return "Pièce jointe"
        }
        return ""
      }()

      let tsMs = (dataMessage?["timestamp"] as? Int64)
        ?? (envelope["timestamp"] as? Int64)
        ?? Int64(Date().timeIntervalSince1970 * 1000)
      let sentAt = Date(timeIntervalSince1970: Double(tsMs) / 1000)

      var conversation = conversations[conversationKey] ?? Conversation(
        id: conversationKey,
        network: .signal,
        address: address,
        title: title,
        preview: displayText.isEmpty ? (isGroup ? "Groupe Signal" : "Signal") : displayText,
        lastMessageAt: sentAt,
        unreadCount: 0,
        isArchived: false,
        transportKey: address,
        isGroup: isGroup
      )
      conversation.isGroup = isGroup
      if !displayText.isEmpty {
        conversation.preview = displayText
        conversation.lastMessageAt = max(conversation.lastMessageAt, sentAt)
        if let groupName, !groupName.isEmpty {
          conversation.title = groupName
        } else if !isGroup, let sourceName, !sourceName.isEmpty {
          conversation.title = sourceName
        }
      }
      conversations[conversationKey] = conversation

      // Texte et/ou pièce jointe (image) = message visible.
      guard !displayText.isEmpty || !attachments.isEmpty else { continue }

      let msgID = "signal-\(tsMs)-\(displayText.hashValue)-\(attachments.map(\.id).joined())"
      let already = messages[conversationKey]?.contains(where: { $0.id == msgID }) == true
      if !already {
        let msg = ChatMessage(
          id: msgID,
          conversationID: conversationKey,
          network: .signal,
          text: displayText,
          sentAt: sentAt,
          isFromMe: false,
          attachments: attachments
        )
        messages[conversationKey, default: []].append(msg)
      }
    }

    for key in messages.keys {
      messages[key]?.sort { $0.sentAt < $1.sentAt }
    }
  }

  private static func extractPhone(from stdout: String) -> String? {
    stdout
      .split(separator: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .first(where: { $0.contains("+") })?
      .replacingOccurrences(of: "Number:", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func which(_ command: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    process.arguments = [command]
    let out = Pipe()
    process.standardOutput = out
    do {
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else { return nil }
      let data = out.fileHandleForReading.readDataToEndOfFile()
      let path = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard let path, !path.isEmpty else { return nil }
      return path
    } catch {
      return nil
    }
  }
}

enum SignalBridgeError: LocalizedError, Sendable {
  case cliMissing
  case sendFailed(String)
  case commandFailed(String)

  var errorDescription: String? {
    switch self {
    case .cliMissing: "signal-cli n’est pas installé."
    case .sendFailed(let detail): "Envoi Signal échoué : \(detail)"
    case .commandFailed(let detail): "Signal : \(detail)"
    }
  }
}
