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

  /// Notre propre numéro Signal, si `listAccounts` a déjà répondu.
  func accountNumber() -> String? { lastAccountLabel }

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
    let messages = cachedMessages[conversationID] ?? []
    return await ensureLocalAttachments(messages, conversationID: conversationID)
  }

  /// Télécharge les pièces jointes manquantes via `signal-cli getAttachment`.
  func ensureLocalAttachments(
    _ messages: [ChatMessage],
    conversationID: String
  ) async -> [ChatMessage] {
    guard let cli = resolvedCLI() else { return messages }
    let isGroup = conversationID.hasPrefix("signal-group:")
    let address = conversationID
      .replacingOccurrences(of: "signal-group:", with: "")
      .replacingOccurrences(of: "signal:", with: "")

    var updated = messages
    var didChange = false

    for index in updated.indices {
      guard !updated[index].attachments.isEmpty else { continue }
      var atts = updated[index].attachments
      var attChanged = false

      for attIndex in atts.indices {
        if atts[attIndex].resolvedFileURL != nil { continue }
        if let existing = SignalAttachmentStore.localPath(forAttachmentID: atts[attIndex].id) {
          atts[attIndex].localPath = existing
          attChanged = true
          continue
        }

        var arguments = ["getAttachment", "--id", atts[attIndex].id]
        if isGroup {
          arguments += ["-g", address]
        } else {
          // Recipient = expéditeur. Pour messages from me, getAttachment peut échouer —
          // on tente quand même avec l’adresse du fil.
          arguments += ["--recipient", address]
        }

        do {
          let result = try await ProcessRunner.run(
            executable: cli,
            arguments: arguments,
            timeoutSeconds: 60
          )
          if result.exitCode == 0,
             let path = SignalAttachmentStore.localPath(forAttachmentID: atts[attIndex].id)
          {
            atts[attIndex].localPath = path
            attChanged = true
          }
        } catch {
          // Silencieux — l’UI montrera un placeholder.
        }
      }

      if attChanged {
        updated[index].attachments = atts
        didChange = true
      }
    }

    if didChange {
      cachedMessages[conversationID] = updated
      var (stored, msgs) = SignalConversationCache.load()
      msgs[conversationID] = updated
      SignalConversationCache.save(conversations: stored, messages: msgs)
    }
    return updated
  }

  func messageCounts() async -> [String: Int] {
    Dictionary(uniqueKeysWithValues: cachedMessages.map { ($0.key, $0.value.count) })
  }

  /// Instantané brut du cache mémoire, pour recompter les non-lus au rattrapage.
  /// Contrairement à `fetchMessages`, ne déclenche aucun `getAttachment` : on ne
  /// veut que des dates et des auteurs, pas des fichiers.
  func cachedMessagesSnapshot() -> [String: [ChatMessage]] { cachedMessages }

  /// Dernier message connu par conversation (pour resync sidebar). On rend le
  /// message et non son aperçu : seul l'appelant sait si le fil est un groupe,
  /// donc s'il faut annoncer qui parle.
  func lastMessageMap() async -> [String: ChatMessage] {
    var map: [String: ChatMessage] = [:]
    for (id, list) in cachedMessages {
      guard let last = list.last else { continue }
      map[id] = last
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
      conversation.preview = last.listPreview(isGroup: conversation.isGroup)
      conversation.lastMessageAt = max(conversation.lastMessageAt, last.sentAt)
      conversation.lastMessageIsFromMe = last.isFromMe
      conversations[id] = conversation
    }
  }

  /// Citation à joindre à un envoi Signal (`--quote-*`).
  struct OutgoingQuote: Sendable {
    var timestamp: Int64
    var author: String
    var text: String
  }

  func send(
    text: String,
    conversation: Conversation,
    attachmentPaths: [String] = [],
    quote: OutgoingQuote? = nil
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
    if let quote {
      arguments += [
        "--quote-timestamp", "\(quote.timestamp)",
        "--quote-author", quote.author,
        "--quote-message", quote.text,
      ]
    }
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
    // `signal-cli send` répond par le timestamp du message : c'est l'identifiant que
    // la partie d'en face citera pour réagir. Sans lui, une réaction à *nos* messages
    // n'aurait aucune cible à qui se rattacher.
    let sentTimestamp = Self.sentTimestamp(in: result.stdout)
      ?? Int64(Date().timeIntervalSince1970 * 1000)
    list.append(
      ChatMessage(
        id: "signal-\(sentTimestamp)-me",
        conversationID: conversation.id,
        network: .signal,
        text: body,
        sentAt: Date(),
        isFromMe: true,
        attachments: outgoingAttachments,
        replyTo: quote.map {
          QuotedMessage(messageID: "signal-\($0.timestamp)-", senderName: $0.author, text: $0.text)
        }
      )
    )
    cachedMessages[conversation.id] = list

    var (stored, msgs) = SignalConversationCache.load()
    msgs[conversation.id] = list
    if let idx = stored.firstIndex(where: { $0.id == conversation.id }) {
      stored[idx].preview = list.last?.listPreview(isGroup: stored[idx].isGroup) ?? body
      stored[idx].lastMessageAt = Date()
    }
    SignalConversationCache.save(conversations: stored, messages: msgs)
  }

  /// Efface l’historique local d’un fil (signal-cli ne garde pas l’historique serveur).
  func clearLocalHistory(conversationID: String) {
    ensureMemoryCacheLoaded()
    cachedMessages[conversationID] = []
    var (stored, msgs) = SignalConversationCache.load()
    msgs[conversationID] = []
    if let idx = stored.firstIndex(where: { $0.id == conversationID }) {
      stored[idx].preview = stored[idx].isGroup ? "Groupe Signal" : "Écrire sur Signal…"
    }
    SignalConversationCache.save(conversations: stored, messages: msgs)
  }

  /// Quitte un groupe Signal (`quitGroup`).
  func quitGroup(conversation: Conversation, deleteLocal: Bool = true) async throws {
    guard let cli = resolvedCLI() else { throw SignalBridgeError.cliMissing }
    guard conversation.isGroup || conversation.id.hasPrefix("signal-group:") else {
      throw SignalBridgeError.commandFailed("Ce fil n’est pas un groupe.")
    }

    var arguments = ["quitGroup", "-g", conversation.transportKey]
    if deleteLocal { arguments.append("--delete") }

    let result = try await ProcessRunner.run(
      executable: cli,
      arguments: arguments,
      timeoutSeconds: 90
    )
    guard result.exitCode == 0 else {
      throw SignalBridgeError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
    }

    cachedMessages.removeValue(forKey: conversation.id)
    var (stored, msgs) = SignalConversationCache.load()
    stored.removeAll { $0.id == conversation.id }
    msgs.removeValue(forKey: conversation.id)
    SignalConversationCache.save(conversations: stored, messages: msgs)
  }

  /// Messages éphémères : `updateGroup -e` / `updateContact -e` (secondes, 0 = off).
  func setDisappearingMessages(conversation: Conversation, expirationSeconds: Int) async throws {
    guard let cli = resolvedCLI() else { throw SignalBridgeError.cliMissing }
    let seconds = max(0, expirationSeconds)

    let arguments: [String]
    if conversation.isGroup || conversation.id.hasPrefix("signal-group:") {
      arguments = ["updateGroup", "-g", conversation.transportKey, "-e", "\(seconds)"]
    } else {
      arguments = ["updateContact", "-e", "\(seconds)", conversation.address]
    }

    let result = try await ProcessRunner.run(
      executable: cli,
      arguments: arguments,
      timeoutSeconds: 90
    )
    guard result.exitCode == 0 else {
      throw SignalBridgeError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
    }
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

      // Les numéros des membres : c'est ce qui nourrit le menu « @ » du composer.
      let memberHandles = members.compactMap {
        (($0["number"] as? String) ?? ($0["uuid"] as? String))?
          .trimmingCharacters(in: .whitespacesAndNewlines)
      }.filter { !$0.isEmpty }

      let id = "signal-group:\(groupID)"
      if var existing = conversations[id] {
        // Toujours réparer un titre technique / placeholder avec le vrai nom.
        existing.preferTitle(title)
        if existing.participantHandles.isEmpty { existing.participantHandles = memberHandles }
        conversations[id] = existing
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
        isGroup: true,
        participantHandles: memberHandles
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

      let (stored, _) = SignalConversationCache.load()
      var byID = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0) })
      // Seed minimal pour parseReceive — jamais avec title = id (écrase les noms).
      for (id, _) in cachedMessages where byID[id] == nil {
        let address = id
          .replacingOccurrences(of: "signal-group:", with: "")
          .replacingOccurrences(of: "signal:", with: "")
        let isGroup = id.hasPrefix("signal-group:")
        byID[id] = Conversation(
          id: id,
          network: .signal,
          address: address,
          title: isGroup ? "Groupe Signal" : address,
          preview: "",
          lastMessageAt: Date(),
          unreadCount: 0,
          isArchived: false,
          transportKey: address,
          isGroup: isGroup
        )
      }
      var messagesByID = cachedMessages
      Self.parseReceive(receiveResult.stdout, conversations: &byID, messages: &messagesByID)
      cachedMessages = messagesByID
      Self.syncPreviews(from: messagesByID, into: &byID)

      var merged = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0) })
      for (_, c) in byID {
        if var existing = merged[c.id] {
          if c.hasLivePreview {
            existing.preview = c.preview
            existing.lastMessageAt = max(existing.lastMessageAt, c.lastMessageAt)
          }
          existing.preferTitle(c.title)
          // Aussi si on a des messages en cache pour cet id.
          if let last = messagesByID[c.id]?.last {
            existing.preview = last.listPreview(isGroup: existing.isGroup)
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

  /// Accusé de lecture Signal (`signal-cli sendReceipt --type read`).
  ///
  /// Ne vaut que pour les DM : `sendReceipt` prend un destinataire, pas un groupe.
  /// Silencieux en cas d'échec — un accusé perdu ne bloque pas l'ouverture d'un fil.
  func sendReadReceipt(conversation: Conversation) async {
    guard !conversation.isGroup, !conversation.id.hasPrefix("signal-group:") else { return }
    guard let cli = resolvedCLI() else { return }
    ensureMemoryCacheLoaded()
    // Le dernier message *reçu* : marquer les nôtres n'apprend rien à personne.
    guard let last = cachedMessages[conversation.id]?.last(where: { !$0.isFromMe }),
          let timestamp = Self.timestamp(inMessageID: last.id)
    else { return }

    _ = try? await ProcessRunner.run(
      executable: cli,
      arguments: ["sendReceipt", "--type", "read", "-t", "\(timestamp)", conversation.address],
      timeoutSeconds: 60
    )
  }

  /// Pose ou retire une réaction (`signal-cli sendReaction`).
  /// Signal identifie sa cible par (auteur, timestamp d'envoi) : les deux se lisent
  /// dans notre identifiant de message, `signal-<timestamp>-…`.
  func sendReaction(
    conversation: Conversation,
    messageID: String,
    emoji: String,
    targetAuthor: String,
    remove: Bool
  ) async throws {
    guard let cli = resolvedCLI() else { throw SignalBridgeError.cliMissing }
    guard let timestamp = Self.timestamp(inMessageID: messageID) else {
      throw SignalBridgeError.commandFailed("Message Signal sans horodatage — réaction impossible.")
    }

    var arguments = ["sendReaction", "-e", emoji, "-a", targetAuthor, "-t", "\(timestamp)"]
    if remove { arguments.append("-r") }
    let isGroup = conversation.isGroup || conversation.id.hasPrefix("signal-group:")
    if isGroup {
      arguments += ["-g", conversation.transportKey]
    } else {
      arguments.append(conversation.address)
    }

    let result = try await ProcessRunner.run(executable: cli, arguments: arguments, timeoutSeconds: 90)
    guard result.exitCode == 0 else {
      throw SignalBridgeError.sendFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
    }

    // Reflet local immédiat : le `receive` suivant ne nous renvoie pas nos propres réactions.
    ensureMemoryCacheLoaded()
    guard var list = cachedMessages[conversation.id],
          let index = list.firstIndex(where: { $0.id == messageID })
    else { return }
    var raw = list[index].reactions.flatMap { existing in
      existing.senders.map { (emoji: existing.emoji, sender: $0, isMine: existing.isMine) }
    }
    raw.removeAll(where: \.isMine)
    if !remove { raw.append((emoji: emoji, sender: "Moi", isMine: true)) }
    list[index].reactions = MessageReaction.aggregate(raw)
    cachedMessages[conversation.id] = list

    var (stored, msgs) = SignalConversationCache.load()
    msgs[conversation.id] = list
    SignalConversationCache.save(conversations: stored, messages: msgs)
    stored.removeAll()
  }

  /// Timestamp porté par un identifiant `signal-<timestamp>-…`.
  static func timestamp(inMessageID id: String) -> Int64? {
    guard id.hasPrefix("signal-") else { return nil }
    let rest = id.dropFirst("signal-".count)
    let digits = rest.prefix { $0.isNumber }
    return Int64(digits)
  }

  /// Timestamp renvoyé par `signal-cli send` (un entier nu, parfois précédé de logs).
  static func sentTimestamp(in stdout: String) -> Int64? {
    for line in stdout.split(whereSeparator: \.isNewline).reversed() {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard trimmed.allSatisfy(\.isNumber), trimmed.count >= 13, let value = Int64(trimmed) else {
        continue
      }
      return value
    }
    return nil
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

    var pendingReactions: [String: [PendingReaction]] = [:]

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

      // Une réaction n'est PAS un message : on la met de côté pour l'attacher à sa
      // cible une fois tous les messages du lot analysés (l'ordre n'est pas garanti).
      if let reaction = dataMessage?["reaction"] as? [String: Any],
         let emoji = reaction["emoji"] as? String,
         let targetTimestamp = Self.int64(reaction["targetSentTimestamp"])
      {
        pendingReactions[conversationKey, default: []].append(
          PendingReaction(
            targetTimestamp: targetTimestamp,
            emoji: emoji,
            sender: sourceName?.isEmpty == false ? sourceName! : (sourceNumber ?? sourceUuid ?? "?"),
            isRemove: (reaction["isRemove"] as? Bool) ?? false
          )
        )
        // L'aperçu du fil ne bouge pas : une réaction ne remplace pas le dernier
        // vrai message, alors que l'ancien code en fabriquait un faux.
        continue
      }

      // `dataMessage.quote` : Signal désigne le message cité par (auteur, timestamp).
      var replyTo: QuotedMessage?
      if let quote = dataMessage?["quote"] as? [String: Any] {
        let quotedText = (quote["text"] as? String) ?? ""
        let quotedAuthor = (quote["authorName"] as? String)
          ?? (quote["author"] as? String)
          ?? (quote["authorNumber"] as? String)
          ?? ""
        let quotedID = Self.int64(quote["id"]).map { "signal-\($0)-" }
        let candidate = QuotedMessage(messageID: quotedID, senderName: quotedAuthor, text: quotedText)
        if !candidate.isEmpty { replyTo = candidate }
      }

      // Le nom de l'auteur ne se colle PLUS dans le corps du message : le fil
      // l'écrit une fois par groupe de bulles (cf. `MessageGrouping`). Il reste
      // en revanche dans l'APERÇU de la liste, où l'on veut savoir qui parle
      // sans ouvrir le fil.
      let senderName: String? = sourceName?.isEmpty == false ? sourceName : nil

      let displayText: String = {
        if !body.isEmpty { return body }
        if attachments.contains(where: \.isImage) { return "📷 Photo" }
        if !attachments.isEmpty { return "Pièce jointe" }
        return ""
      }()

      let previewText = SenderPrefix.previewLine(displayText, senderName: senderName, isGroup: isGroup)

      let tsMs = Self.int64(dataMessage?["timestamp"])
        ?? Self.int64(envelope["timestamp"])
        ?? Int64(Date().timeIntervalSince1970 * 1000)
      let sentAt = Date(timeIntervalSince1970: Double(tsMs) / 1000)

      var conversation = conversations[conversationKey] ?? Conversation(
        id: conversationKey,
        network: .signal,
        address: address,
        title: title,
        preview: previewText.isEmpty ? (isGroup ? "Groupe Signal" : "Signal") : previewText,
        lastMessageAt: sentAt,
        unreadCount: 0,
        isArchived: false,
        transportKey: address,
        isGroup: isGroup
      )
      conversation.isGroup = isGroup
      if !displayText.isEmpty {
        conversation.preview = previewText
        conversation.lastMessageAt = max(conversation.lastMessageAt, sentAt)
        conversation.lastMessageIsFromMe = false
      }
      if let groupName, !groupName.isEmpty {
        conversation.preferTitle(groupName)
      } else if !isGroup, let sourceName, !sourceName.isEmpty {
        conversation.preferTitle(sourceName)
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
          senderID: sourceNumber ?? sourceUuid,
          senderName: senderName,
          attachments: attachments,
          replyTo: replyTo
        )
        messages[conversationKey, default: []].append(msg)
      }
    }

    for key in messages.keys {
      messages[key]?.sort { $0.sentAt < $1.sentAt }
    }

    applyReactions(pendingReactions, to: &messages)
  }

  /// Réaction Signal reçue, en attente de sa cible.
  struct PendingReaction: Sendable {
    var targetTimestamp: Int64
    var emoji: String
    var sender: String
    var isRemove: Bool
  }

  /// Rattache les réactions à leur message. Signal désigne sa cible par
  /// `targetSentTimestamp` : nos identifiants commencent tous par `signal-<timestamp>-`,
  /// y compris ceux de nos propres envois, ce qui suffit à la retrouver.
  static func applyReactions(
    _ pending: [String: [PendingReaction]],
    to messages: inout [String: [ChatMessage]]
  ) {
    for (conversationKey, reactions) in pending {
      guard var list = messages[conversationKey] else { continue }
      for reaction in reactions {
        let prefix = "signal-\(reaction.targetTimestamp)-"
        guard let index = list.firstIndex(where: { $0.id.hasPrefix(prefix) }) else { continue }
        var raw = list[index].reactions.flatMap { existing in
          existing.senders.map { (emoji: existing.emoji, sender: $0, isMine: existing.isMine) }
        }
        raw.removeAll { $0.sender == reaction.sender }
        // Signal n'autorise qu'un emoji par personne : retirer, c'est ne rien remettre.
        if !reaction.isRemove {
          raw.append((emoji: reaction.emoji, sender: reaction.sender, isMine: false))
        }
        list[index].reactions = MessageReaction.aggregate(raw)
      }
      messages[conversationKey] = list
    }
  }

  /// `Int64` tolérant : signal-cli sérialise les timestamps tantôt en `Int`, tantôt en `Double`.
  static func int64(_ value: Any?) -> Int64? {
    if let v = value as? Int64 { return v }
    if let v = value as? Int { return Int64(v) }
    if let v = value as? Double { return Int64(v) }
    if let v = value as? NSNumber { return v.int64Value }
    if let v = value as? String { return Int64(v) }
    return nil
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
