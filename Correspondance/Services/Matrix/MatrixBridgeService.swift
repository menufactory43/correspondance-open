import Foundation

/// Pont entre le homeserver et l'inbox : tient l'état des salons, la boucle `/sync`,
/// l'envoi et le flux de connexion WhatsApp. Un seul `MatrixClient` en dessous.
actor MatrixBridgeService {
  private let client: MatrixClient
  private var rooms: [String: MatrixRoomModel] = [:]
  private var nextBatch: String?
  private var selfUserID: String = ""
  private var didHydrate = false
  /// Salon de gestion du bot WhatsApp (commandes `login`, `pm`…).
  private var managementRoomID: String?
  /// Invitations de bridge déjà traitées (évite de marteler `/join`).
  private var attemptedInviteJoins: Set<String> = []
  /// Event de la dernière commande `login` envoyée : borne basse de lecture des réponses du bot.
  private var loginCommandEventID: String?
  /// `txnId` par message optimiste : un renvoi ne duplique rien.
  private var ledger = MatrixTransactionLedger()

  init(credentials: MatrixCredentials? = MatrixCredentialStore.load()) {
    client = MatrixClient(credentials: credentials)
    if let credentials { selfUserID = credentials.userID }
  }

  // MARK: - Session

  var isConnected: Bool { !selfUserID.isEmpty }

  var currentUserID: String { selfUserID }

  func statusMessageFR() async -> String {
    guard let creds = await client.currentCredentials else {
      return "Matrix : non connecté."
    }
    do {
      let userID = try await client.whoami()
      selfUserID = userID
      let bridged = conversations().count
      return "Matrix connecté (\(userID)) · \(bridged) fils WhatsApp."
    } catch {
      return "Matrix (\(creds.homeserver.host ?? "?")) : \(error.localizedDescription)"
    }
  }

  /// Connexion par mot de passe, puis persistance dans le Trousseau.
  @discardableResult
  func connect(homeserver: URL, user: String, password: String) async throws -> MatrixCredentials {
    // Ping d'abord : un mot de passe envoyé à une mauvaise adresse ne sert personne.
    _ = try await client.serverVersions(homeserver: homeserver)
    let creds = try await client.login(homeserver: homeserver, user: user, password: password)
    MatrixCredentialStore.save(creds)
    selfUserID = creds.userID
    rooms = [:]
    nextBatch = nil
    managementRoomID = nil
    return creds
  }

  func disconnect() async {
    await client.logout()
    MatrixCredentialStore.clear()
    MatrixConversationCache.clear()
    rooms = [:]
    nextBatch = nil
    selfUserID = ""
    managementRoomID = nil
    loginCommandEventID = nil
  }

  // MARK: - Sync

  /// Reprend le curseur `next_batch` du cache et vérifie que la session tient encore.
  /// `false` = pas de credentials ou token périmé : l'appelant n'ouvre pas de boucle.
  func restoreCursorAndCheckSession() async -> Bool {
    if !didHydrate {
      didHydrate = true
      // Sync initial à chaque lancement (homeserver privé : c'est léger). Reprendre le
      // curseur du cache ferait perdre les invitations de portails reçues entre-temps :
      // Synapse ne les renvoie qu'une fois. Le cache sert à l'affichage immédiat, pas au curseur.
      nextBatch = nil
    }
    guard await client.isConfigured else { return false }
    do {
      selfUserID = try await client.whoami()
      return true
    } catch {
      return false
    }
  }

  /// Une passe de `/sync`. Long-poll : renvoie dès qu'il se passe quelque chose.
  @discardableResult
  func syncOnce(timeoutMilliseconds: Int = 30_000) async throws -> [Conversation] {
    guard await client.isConfigured else { throw MatrixError.notConfigured }
    if selfUserID.isEmpty { selfUserID = try await client.whoami() }
    let response = try await client.sync(since: nextBatch, timeoutMilliseconds: timeoutMilliseconds)
    let parser = MatrixSyncParser(selfUserID: selfUserID)
    parser.apply(response, to: &rooms)
    nextBatch = response.nextBatch
    detectManagementRoom()
    persist()
    await acceptBridgeInvites(response)
    return conversations()
  }

  /// Les portails (un par chat WhatsApp) arrivent sous forme d'invitations du bridge :
  /// sans double puppeting, c'est au client de les accepter. On ne rejoint que ce qui
  /// vient d'un bot ou d'un ghost de bridge — jamais une invitation humaine à l'aveugle.
  private func acceptBridgeInvites(_ response: MatrixSyncResponse) async {
    guard let invites = response.rooms?.invite else { return }
    for (roomID, payload) in invites where !attemptedInviteJoins.contains(roomID) {
      let events = payload["invite_state"]?["events"]?.arrayValue ?? []
      let fromBridge = events.contains { event in
        guard let sender = event["sender"]?.stringValue else { return false }
        return MatrixIdentity.isBridgeBot(sender) || MatrixIdentity.isGhost(sender)
      }
      guard fromBridge else { continue }
      attemptedInviteJoins.insert(roomID)
      do {
        try await client.join(roomID: roomID)
      } catch {
        // Réessayé au prochain sync si l'invitation est encore là (réseau, rate-limit).
        attemptedInviteJoins.remove(roomID)
      }
    }
  }

  func conversations() -> [Conversation] {
    rooms.values
      .compactMap { $0.conversation(selfUserID: selfUserID) }
      .sorted { $0.lastMessageAt > $1.lastMessageAt }
  }

  func messages(conversationID: String) -> [ChatMessage] {
    guard let model = rooms.values.first(where: { $0.conversationID == conversationID }) else { return [] }
    return model.sortedMessages
  }

  /// Complète l'historique d'un salon (ouverture d'un fil encore vide).
  func backfill(conversationID: String, limit: Int = 50) async -> [ChatMessage] {
    guard let roomID = roomID(forConversation: conversationID) else { return [] }
    do {
      let response = try await client.roomMessages(roomID: roomID, direction: "b", limit: limit)
      guard var model = rooms[roomID] else { return [] }
      MatrixSyncParser(selfUserID: selfUserID).applyMessages(response.chunk, roomID: roomID, to: &model)
      rooms[roomID] = model
      persist()
      return model.sortedMessages
    } catch {
      return rooms[roomID]?.sortedMessages ?? []
    }
  }

  /// Télécharge les pièces jointes manquantes et renvoie les messages avec chemins locaux.
  func ensureLocalAttachments(_ messages: [ChatMessage]) async -> [ChatMessage] {
    var result: [ChatMessage] = []
    for message in messages {
      guard !message.attachments.isEmpty else {
        result.append(message)
        continue
      }
      var updated = message
      for index in updated.attachments.indices {
        let attachment = updated.attachments[index]
        if attachment.resolvedFileURL != nil { continue }
        if let path = MatrixAttachmentStore.existingLocalPath(forMXC: attachment.id, contentType: attachment.contentType) {
          updated.attachments[index].localPath = path
          continue
        }
        guard let data = try? await client.downloadMedia(mxcURI: attachment.id) else { continue }
        updated.attachments[index].localPath = MatrixAttachmentStore.store(
          data: data,
          forMXC: attachment.id,
          contentType: attachment.contentType
        )
      }
      // Reporter les chemins dans le modèle pour éviter un re-téléchargement.
      // Sans les réactions : `messagesByID` est la vérité brute, l'agrégation se
      // refait à la lecture depuis `reactionsByEventID` (qu'une redaction peut vider).
      if let roomID = roomID(forConversation: message.conversationID) {
        var canonical = updated
        canonical.reactions = []
        rooms[roomID]?.messagesByID[message.id] = canonical
      }
      result.append(updated)
    }
    return result
  }

  // MARK: - Envoi

  func send(
    conversationID: String,
    text: String,
    attachmentPaths: [String],
    localID: String,
    replyToMessageID: String? = nil
  ) async throws {
    guard let roomID = roomID(forConversation: conversationID) else {
      throw MatrixError.decoding("salon introuvable pour \(conversationID)")
    }
    // Un identifiant stable par message optimiste : rejouer l'envoi ne duplique rien.
    let txnID = ledger.transactionID(forLocalID: localID)

    for (index, path) in attachmentPaths.enumerated() {
      try await client.sendAttachment(
        roomID: roomID,
        fileURL: URL(fileURLWithPath: path),
        transactionID: ledger.attachmentTransactionID(base: txnID, index: index)
      )
    }
    if !text.isEmpty {
      let quoted = replyToMessageID.flatMap { rooms[roomID]?.messagesByID[$0] }
      try await client.sendText(
        roomID: roomID,
        body: text,
        replyToEventID: replyToMessageID,
        replyFallback: quoted.map { (sender: $0.senderID ?? selfUserID, text: $0.sidebarPreviewText) },
        transactionID: txnID
      )
    }
  }

  /// Pose, remplace ou retire ma réaction sur un message.
  ///
  /// WhatsApp n'accepte **qu'un emoji par personne et par message**
  /// (`ReactionCount: 1` dans les capacités de mautrix-whatsapp) : reposer le même
  /// emoji le retire, en poser un autre remplace le précédent.
  func toggleReaction(conversationID: String, messageID: String, emoji: String) async throws {
    guard let roomID = roomID(forConversation: conversationID) else {
      throw MatrixError.decoding("salon introuvable pour \(conversationID)")
    }
    let mine = rooms[roomID]?.reactionsByEventID
      .first { $0.value.targetEventID == messageID && $0.value.isMine }

    if let mine {
      try await client.redact(roomID: roomID, eventID: mine.key)
      rooms[roomID]?.reactionsByEventID.removeValue(forKey: mine.key)
      // Reposer le même emoji = le retirer.
      if mine.value.emoji == emoji {
        persist()
        return
      }
    }

    guard let eventID = try await client.sendReaction(
      roomID: roomID,
      targetEventID: messageID,
      key: emoji
    ) else { return }

    // Reflet local immédiat : le `/sync` confirmera dans la seconde.
    rooms[roomID]?.reactionsByEventID[eventID] = MatrixRoomModel.ReactionEvent(
      targetEventID: messageID,
      emoji: emoji,
      senderID: selfUserID,
      senderName: "Moi",
      isMine: true
    )
    persist()
  }

  // MARK: - Connexion WhatsApp

  enum WhatsAppLoginStep: Sendable, Equatable {
    /// QR à scanner (PNG déjà téléchargé).
    case qrCode(Data)
    case pairingCode(String)
    case success(String)
    case failure(String)
    case waiting
  }

  /// Ouvre (ou retrouve) le salon de gestion et envoie la commande de connexion.
  func startWhatsAppLogin(usingPhoneNumber phoneNumber: String? = nil) async throws {
    let command = phoneNumber.map { "login phone \($0)" } ?? "login qr"
    // On retient l'event de la commande : tout ce qui la précède appartient à une
    // tentative passée (QR périmés, « login timed out »…) et ne doit pas être lu.
    loginCommandEventID = try await sendBotCommand(command)
  }

  /// Dernier état publié par le bot **depuis** notre commande de connexion.
  func whatsAppLoginStep() async throws -> WhatsAppLoginStep {
    let roomID = try await ensureManagementRoom()
    let response = try await client.roomMessages(roomID: roomID, direction: "b", limit: 20)
    for event in response.chunk {
      // `dir=b` : du plus récent au plus ancien. Arrivé à notre propre commande,
      // la suite est l'historique d'avant — on s'arrête là.
      if let loginCommandEventID, event.eventID == loginCommandEventID { break }
      guard event.type == "m.room.message",
            let content = event.content,
            let sender = event.sender,
            MatrixIdentity.isBridgeBot(sender)
      else { continue }
      let body = content.string(at: "body") ?? ""
      let lower = body.lowercased()
      if lower.contains("successfully logged in") || lower.contains("connexion réussie") {
        return .success(body)
      }
      if lower.contains("failed to log in") || lower.contains("login timed out") || lower.contains("timed out") {
        return .failure(body)
      }
      if content.string(at: "msgtype") == "m.image", let mxc = content.string(at: "url") {
        let data = try await client.downloadMedia(mxcURI: mxc)
        return .qrCode(data)
      }
      if let code = Self.pairingCode(in: body) {
        return .pairingCode(code)
      }
    }
    return .waiting
  }

  /// Ouvre un fil WhatsApp vers un numéro via la commande bot `pm`.
  func startWhatsAppConversation(phoneNumber: String) async throws {
    let digits = phoneNumber.filter { $0.isNumber }
    guard digits.count >= 8 else {
      throw MatrixError.decoding("numéro WhatsApp invalide")
    }
    _ = try await sendBotCommand("pm +\(digits)")
  }

  /// Salon de gestion : celui où le bot est présent et qui n'est pas un portail.
  @discardableResult
  private func ensureManagementRoom() async throws -> String {
    if let managementRoomID { return managementRoomID }
    detectManagementRoom()
    // Le sync peut encore porter un salon de gestion qu'on a quitté (ou où l'on n'est
    // qu'invité) : envoyer dedans donne « User not in room ». On vérifie, on rejoint,
    // sinon on repart sur un DM neuf avec le bot.
    if let candidate = managementRoomID {
      if try await client.joinedRooms().contains(candidate) { return candidate }
      if let joined = try? await client.join(roomID: candidate) {
        managementRoomID = joined
        return joined
      }
      rooms.removeValue(forKey: candidate)
      managementRoomID = nil
    }
    guard !selfUserID.isEmpty else { throw MatrixError.notConfigured }
    let serverName = String(selfUserID.split(separator: ":").last ?? "")
    let roomID = try await client.createDM(with: "@whatsappbot:\(serverName)")
    managementRoomID = roomID
    return roomID
  }

  /// Envoie une commande au bot ; si le salon retenu n'est plus valide (403), on le
  /// jette et on réessaie une fois avec un salon de gestion neuf.
  private func sendBotCommand(_ rawCommand: String) async throws -> String? {
    // Préfixe `!wa` : accepté par mautrix dans tous les salons. Sans lui, un DM
    // créé par nous (et non par le bot) n'est pas traité comme salon de gestion
    // et la commande est ignorée en silence.
    let command = rawCommand.hasPrefix("!") ? rawCommand : "!wa \(rawCommand)"
    let roomID = try await ensureManagementRoom()
    do {
      return try await client.sendText(roomID: roomID, body: command, transactionID: UUID().uuidString)
    } catch MatrixError.http(let status, _, _) where status == 403 {
      rooms.removeValue(forKey: roomID)
      managementRoomID = nil
      let fresh = try await ensureManagementRoom()
      return try await client.sendText(roomID: fresh, body: command, transactionID: UUID().uuidString)
    }
  }

  private func detectManagementRoom() {
    guard managementRoomID == nil else { return }
    managementRoomID = rooms.values
      .first { model in
        model.network == nil && model.members.keys.contains(where: { MatrixIdentity.isBridgeBot($0) })
      }?
      .roomID
  }

  static func pairingCode(in body: String) -> String? {
    // Le bot annonce « Input the pairing code ABCD-EFGH in the WhatsApp app »,
    // parfois entre accents graves. La casse n'est pas garantie d'une version à l'autre.
    guard body.lowercased().contains("pairing code") else { return nil }
    let pattern = #"\b[A-Za-z0-9]{4}-[A-Za-z0-9]{4}\b"#
    guard let range = body.range(of: pattern, options: [.regularExpression]) else { return nil }
    return String(body[range]).uppercased()
  }

  // MARK: - Privé

  private func roomID(forConversation conversationID: String) -> String? {
    rooms.values.first { $0.conversationID == conversationID }?.roomID
  }

  private func persist() {
    var messages: [String: [ChatMessage]] = [:]
    for model in rooms.values where model.network != nil {
      messages[model.conversationID] = model.sortedMessages
    }
    MatrixConversationCache.save(nextBatch: nextBatch, conversations: conversations(), messages: messages)
  }
}
