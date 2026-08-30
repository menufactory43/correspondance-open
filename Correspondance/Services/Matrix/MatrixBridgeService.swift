import Foundation

/// Pont entre le homeserver et l'inbox : tient l'état des salons, la boucle `/sync`,
/// l'envoi et les flux de connexion des ponts. Un seul `MatrixClient` en dessous.
///
/// Un seul `/sync` pour tous les ponts — ils vivent sur le même homeserver — mais
/// **un salon de gestion par pont** : le bot WhatsApp et le bot Instagram ne se
/// parlent pas, et une commande envoyée au mauvais bot reste sans réponse.
actor MatrixBridgeService {
  private let client: MatrixClient
  private var rooms: [String: MatrixRoomModel] = [:]
  private var nextBatch: String?
  private var selfUserID: String = ""
  private var didHydrate = false
  /// Salon de gestion par réseau (commandes `login`, `pm`…).
  private var managementRoomIDs: [MessageNetwork: String] = [:]
  /// Invitations de bridge déjà traitées (évite de marteler `/join`).
  private var attemptedInviteJoins: Set<String> = []
  /// Event de la dernière commande `login` envoyée, par réseau : borne basse de lecture
  /// des réponses du bot (tout ce qui précède appartient à une tentative passée).
  private var loginCommandEventIDs: [MessageNetwork: String] = [:]
  /// Heure de la dernière commande `login`, par réseau : au-delà de quelques secondes
  /// sans que le bot ait rejoint le salon, ce n'est plus de la latence, c'est une panne.
  private var loginCommandSentAt: [MessageNetwork: Date] = [:]
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
      return "Matrix connecté (\(userID)) · \(Self.bridgedCountFR(conversations()))."
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
    managementRoomIDs = [:]
    return creds
  }

  func disconnect() async {
    await client.logout()
    MatrixCredentialStore.clear()
    MatrixConversationCache.clear()
    rooms = [:]
    nextBatch = nil
    selfUserID = ""
    managementRoomIDs = [:]
    loginCommandEventIDs = [:]
    loginCommandSentAt = [:]
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
    detectManagementRooms()
    persist()
    await acceptBridgeInvites(response)
    return conversations()
  }

  /// Les portails (un par chat distant) arrivent sous forme d'invitations du bridge :
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

  struct Member: Sendable, Hashable {
    let userID: String
    let displayName: String?
    let avatarMXC: String?
  }

  /// Les correspondants d'un salon — ni moi, ni le bot, ni mon propre ghost.
  func members(conversationID: String) -> [Member] {
    guard let model = rooms.values.first(where: { $0.conversationID == conversationID }) else { return [] }
    return model.remoteMembers(selfUserID: selfUserID).map {
      Member(userID: $0.userID, displayName: $0.member.displayName, avatarMXC: $0.member.avatarMXC)
    }
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

  /// Photo d'un portail (`m.room.avatar`), depuis le cache disque sinon le homeserver.
  /// L'inbox en a besoin pour les fils sans numéro : Instagram n'expose rien d'autre.
  func avatarData(mxcURI: String) async -> Data? {
    if let cached = MatrixAvatarStore.existingData(forMXC: mxcURI) { return cached }
    guard let data = try? await client.downloadMedia(mxcURI: mxcURI), !data.isEmpty else { return nil }
    MatrixAvatarStore.store(data: data, forMXC: mxcURI)
    return data
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
  /// WhatsApp comme Instagram n'acceptent **qu'un emoji par personne et par message**
  /// (`ReactionCount: 1` dans les capacités de mautrix-whatsapp et de mautrix-instagram) :
  /// reposer le même emoji le retire, en poser un autre remplace le précédent.
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

  /// Marque le fil lu côté réseau, à l'ouverture. Silencieux en cas d'échec :
  /// un accusé perdu ne doit pas faire échouer l'ouverture d'une conversation.
  func markRead(conversationID: String) async {
    guard let roomID = roomID(forConversation: conversationID),
          let last = rooms[roomID]?.sortedMessages.last,
          // Marquer nos propres messages n'apprend rien à personne.
          !last.isFromMe
    else { return }
    try? await client.sendReadReceipt(roomID: roomID, eventID: last.id)
  }

  /// Quitte le salon d'un fil, et l'oublie côté cache : quitter le portail d'un
  /// groupe revient à quitter le groupe sur le réseau distant.
  func leaveRoom(conversationID: String) async throws {
    guard let roomID = roomID(forConversation: conversationID) else { return }
    try await client.leave(roomID: roomID)
    rooms.removeValue(forKey: roomID)
  }

  // MARK: - Connexion d'un pont

  /// Où en est le bot dans le flux de connexion, quel que soit le pont.
  enum BridgeLoginStep: Sendable, Equatable {
    /// QR à scanner (PNG déjà téléchargé).
    case qrCode(Data)
    case pairingCode(String)
    /// Le bot attend qu'on lui colle quelque chose (les cookies Instagram).
    case awaitingCookies(String)
    case success(String)
    case failure(String)
    case waiting
  }

  /// Ce que l'app envoie pour démarrer une connexion, selon le pont.
  enum BridgeLoginInput: Sendable, Equatable {
    /// QR à scanner depuis le téléphone. WhatsApp et Signal s'y lient tous deux
    /// comme appareil secondaire.
    case qrCode
    /// Repli par code d'appairage, quand le pont sait le faire — WhatsApp seul :
    /// mautrix-signal n'expose que le flow QR.
    case phonePairing(phoneNumber: String)
    /// Instagram : la commande `login` seule, la session récoltée dans la fenêtre suivra.
    case webSession
  }

  /// Ouvre (ou retrouve) le salon de gestion du pont et envoie la commande de connexion.
  func startLogin(network: MessageNetwork, input: BridgeLoginInput) async throws {
    let command: String
    switch input {
    case .qrCode: command = "login qr"
    case .phonePairing(let phoneNumber): command = "login phone \(phoneNumber)"
    // Un seul flow côté mautrix-instagram (`instagram`, par cookies) : `login` suffit,
    // et le bot enchaîne tout seul sur l'étape « colle ton JSON ».
    case .webSession: command = "login"
    }
    // Une tentative précédente peut encore être ouverte côté pont — une feuille
    // fermée sans « Fermer », un QR qu'on a laissé tourner. Le bot refuserait alors
    // la nouvelle par « You already have an ongoing login », et « Relancer » ne
    // relancerait rien. On solde donc l'ancienne avant d'en ouvrir une.
    _ = try? await sendBotCommand("cancel", to: network)
    // On retient l'event de la commande : tout ce qui la précède appartient à une
    // tentative passée (QR périmés, « login timed out »…) et ne doit pas être lu.
    loginCommandEventIDs[network] = try await sendBotCommand(command, to: network)
    loginCommandSentAt[network] = Date()
  }

  /// Envoie la session au bot, en réponse à son invite : soit le JSON fabriqué à partir
  /// de la fenêtre de connexion intégrée, soit un collage manuel (le repli).
  ///
  /// Notre DM n'est pas le « salon de gestion » aux yeux du bot (c'est nous qui l'avons
  /// créé) : il exige alors le préfixe de commande même pour une entrée de login —
  /// « Entering login info must be prefixed with `!ig` like other commands ». Sans lui,
  /// le JSON est ignoré en silence. Le bot retire le préfixe avant de lire la suite.
  func submitLoginCookies(_ raw: String, network: MessageNetwork) async throws {
    guard let bridge = network.bridge else { throw MatrixError.notConfigured }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw MatrixError.decoding("cookies vides") }
    let payload = trimmed.hasPrefix(bridge.commandPrefix) ? trimmed : "\(bridge.commandPrefix) \(trimmed)"
    let roomID = try await ensureManagementRoom(for: network)
    let eventID = try await client.sendText(roomID: roomID, body: payload, transactionID: UUID().uuidString)
    // Le pont reçoit l'event par la transaction d'appservice, au moment même où Synapse
    // l'accepte : rédiger juste après ne lui retire rien. Le bot rédige lui-même quand il
    // lit une session — mais s'il n'est pas dans le salon, elle resterait en clair dans
    // la timeline. On ne laisse pas ce soin à quelqu'un d'autre.
    if let eventID {
      _ = try? await client.redact(roomID: roomID, eventID: eventID)
    }
  }

  /// Le bot doit **rejoindre** le salon de gestion pour lire quoi que ce soit ; un
  /// homeserver qui n'a pas chargé la registration du pont laisse l'invitation en plan.
  /// On pose la question à Synapse plutôt qu'au `/sync` : la réponse est immédiate.
  private static let botJoinGraceSeconds: TimeInterval = 12

  private func botHasJoined(roomID: String, network: MessageNetwork) async -> Bool? {
    guard let bridge = network.bridge, !selfUserID.isEmpty else { return nil }
    let serverName = String(selfUserID.split(separator: ":").last ?? "")
    let bot = bridge.botUserID(serverName: serverName)
    guard let state = try? await client.roomState(roomID: roomID, type: "m.room.member", stateKey: bot) else {
      return nil
    }
    return state.string(at: "membership") == "join"
  }

  /// Dernier état publié par le bot **depuis** notre commande de connexion.
  func loginStep(network: MessageNetwork) async throws -> BridgeLoginStep {
    let roomID = try await ensureManagementRoom(for: network)
    let response = try await client.roomMessages(roomID: roomID, direction: "b", limit: 20)
    let bound = loginCommandEventIDs[network]
    for event in response.chunk {
      // `dir=b` : du plus récent au plus ancien. Arrivé à notre propre commande,
      // la suite est l'historique d'avant — on s'arrête là.
      if let bound, event.eventID == bound { break }
      guard event.type == "m.room.message",
            let content = event.content,
            let sender = event.sender,
            MatrixIdentity.network(ofBot: sender) == network
      else { continue }
      let body = content.string(at: "body") ?? ""
      if let step = Self.loginStep(inBotMessage: body) { return step }
      if content.string(at: "msgtype") == "m.image", let mxc = content.string(at: "url") {
        let data = try await client.downloadMedia(mxcURI: mxc)
        return .qrCode(data)
      }
    }
    // Rien du bot : est-il seulement là ? Passé le délai de grâce, un bot encore
    // « invité » ne répondra jamais — on le dit tout de suite plutôt que dans 90 s.
    if let sentAt = loginCommandSentAt[network],
       Date().timeIntervalSince(sentAt) > Self.botJoinGraceSeconds,
       await botHasJoined(roomID: roomID, network: network) == false
    {
      throw MatrixError.bridgeBotNotJoined(network)
    }
    return .waiting
  }

  /// Lecture d'une réponse du bot, isolée pour être testable sans homeserver.
  /// `nil` = ce message ne dit rien du login (bavardage, état de connexion…).
  static func loginStep(inBotMessage body: String) -> BridgeLoginStep? {
    let lower = body.lowercased()
    // Succès : « Successfully logged in » (mautrix-whatsapp) ou l'instruction
    // « Logged in as <nom> (<id>) » de l'étape finale bridgev2.
    if lower.contains("successfully logged in")
      || lower.contains("connexion réussie")
      || lower.hasPrefix("logged in as")
    {
      return .success(body)
    }
    // Échecs : le message d'un flow QR, et ceux que bridgev2 renvoie sur les cookies.
    // Le pont garde une tentative ouverte : sans le dire, la feuille attendrait
    // un QR que le bot ne postera pas.
    if lower.contains("already have an ongoing login") {
      return .failure(body)
    }
    if lower.contains("failed to log in")
      || lower.contains("login failed")
      || lower.contains("timed out")
      || lower.contains("failed to parse input as json")
      || lower.contains("missing some keys")
      || lower.contains("invalid value for")
      || lower.contains("failed to submit input")
    {
      return .failure(body)
    }
    if let code = pairingCode(in: body) { return .pairingCode(code) }
    // Invite de l'étape « cookies » : l'instruction du connecteur, puis l'URL de login.
    if lower.contains("enter a json object with your cookies") || lower.hasPrefix("login url:") {
      return .awaitingCookies(body)
    }
    return nil
  }

  /// Ouvre un fil vers un correspondant via la commande bot `pm` (alias de `start-chat`).
  ///
  /// WhatsApp attend un numéro. Instagram attend l'identifiant **numérique** Meta :
  /// un pseudo doit d'abord passer par `search`, dont on lit la réponse du bot.
  func startConversation(network: MessageNetwork, identifier: String) async throws {
    guard let bridge = network.bridge else {
      throw MatrixError.decoding("réseau non bridgé : \(network.rawValue)")
    }
    switch network {
    case .whatsapp:
      let digits = identifier.filter { $0.isNumber }
      guard digits.count >= 8 else {
        throw MatrixError.decoding("numéro WhatsApp invalide")
      }
      _ = try await sendBotCommand(bridge.startChatCommand(identifier: "+\(digits)"), to: network)
    default:
      let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
      guard !trimmed.isEmpty else {
        throw MatrixError.decoding("identifiant \(network.labelFR) vide")
      }
      let metaID = trimmed.allSatisfy(\.isNumber)
        ? trimmed
        : try await resolveMetaID(username: trimmed, network: network)
      _ = try await sendBotCommand(bridge.startChatCommand(identifier: metaID), to: network)
    }
  }

  /// `search <pseudo>` puis lecture de la réponse du bot pour en tirer l'ID numérique.
  /// Les ghosts Meta sont des identifiants numériques : `pm <pseudo>` échouerait sec.
  private func resolveMetaID(username: String, network: MessageNetwork) async throws -> String {
    let commandEventID = try await sendBotCommand("search \(username)", to: network)
    let roomID = try await ensureManagementRoom(for: network)
    // Le bot interroge Meta : quelques secondes au plus, sinon on renonce proprement.
    for _ in 0..<10 {
      try? await Task.sleep(for: .seconds(1))
      let response = try await client.roomMessages(roomID: roomID, direction: "b", limit: 10)
      for event in response.chunk {
        if let commandEventID, event.eventID == commandEventID { break }
        guard event.type == "m.room.message",
              let sender = event.sender,
              MatrixIdentity.network(ofBot: sender) == network,
              let body = event.content?.string(at: "body")
        else { continue }
        if let id = Self.firstSearchResultID(in: body) { return id }
      }
    }
    throw MatrixError.decoding("aucun compte \(network.labelFR) trouvé pour « \(username) »")
  }

  /// Premier identifiant d'une réponse `search` : bridgev2 formate chaque résultat
  /// en `` `12345` / Nom ``. On ne garde que le premier, le plus pertinent.
  static func firstSearchResultID(in body: String) -> String? {
    let pattern = "`([0-9]{4,})`"
    guard let range = body.range(of: pattern, options: [.regularExpression]) else { return nil }
    return String(body[range]).trimmingCharacters(in: CharacterSet(charactersIn: "`"))
  }

  /// Salon de gestion d'un pont : celui où son bot est présent et qui n'est pas un portail.
  @discardableResult
  private func ensureManagementRoom(for network: MessageNetwork) async throws -> String {
    guard let bridge = network.bridge else { throw MatrixError.notConfigured }
    if let known = managementRoomIDs[network] { return known }
    detectManagementRooms()
    // Le sync peut encore porter un salon de gestion qu'on a quitté (ou où l'on n'est
    // qu'invité) : envoyer dedans donne « User not in room ». On vérifie, on rejoint,
    // sinon on repart sur un DM neuf avec le bot.
    if let candidate = managementRoomIDs[network] {
      if try await client.joinedRooms().contains(candidate) { return candidate }
      if let joined = try? await client.join(roomID: candidate) {
        managementRoomIDs[network] = joined
        return joined
      }
      rooms.removeValue(forKey: candidate)
      managementRoomIDs[network] = nil
    }
    guard !selfUserID.isEmpty else { throw MatrixError.notConfigured }
    let serverName = String(selfUserID.split(separator: ":").last ?? "")
    let roomID = try await client.createDM(with: bridge.botUserID(serverName: serverName))
    // `createDM` rend la main dès que le bot est *invité*. Il rejoint une fraction
    // de seconde plus tard, et une commande postée entre-temps tombe dans le vide :
    // le bot ne relit pas ce qui précède son arrivée. C'est ce qui faisait tourner
    // la demande de QR sans fin — le salon existait, le bot était bien là, mais
    // personne n'avait vu passer le `login`.
    try await waitForBotToJoin(roomID: roomID, network: network)
    managementRoomIDs[network] = roomID
    return roomID
  }

  /// Attend que le bot du pont ait rejoint le salon, avant d'oser lui parler.
  private func waitForBotToJoin(roomID: String, network: MessageNetwork) async throws {
    let deadline = Date().addingTimeInterval(Self.botJoinGraceSeconds)
    while Date() < deadline {
      if await botHasJoined(roomID: roomID, network: network) == true { return }
      try? await Task.sleep(for: .milliseconds(400))
    }
    // Passé le délai, ce n'est plus une course : la registration du pont n'est
    // pas chargée côté Synapse, et l'erreur le dit avec la marche à suivre.
    guard await botHasJoined(roomID: roomID, network: network) == true else {
      throw MatrixError.bridgeBotNotJoined(network)
    }
  }

  /// Envoie une commande au bot d'un pont ; si le salon retenu n'est plus valide (403),
  /// on le jette et on réessaie une fois avec un salon de gestion neuf.
  private func sendBotCommand(_ rawCommand: String, to network: MessageNetwork) async throws -> String? {
    guard let bridge = network.bridge else { throw MatrixError.notConfigured }
    // Préfixe (`!wa`, `!ig`) : accepté par mautrix dans tous les salons. Sans lui, un DM
    // créé par nous (et non par le bot) n'est pas traité comme salon de gestion
    // et la commande est ignorée en silence.
    let command = rawCommand.hasPrefix("!") ? rawCommand : "\(bridge.commandPrefix) \(rawCommand)"
    let roomID = try await ensureManagementRoom(for: network)
    do {
      return try await client.sendText(roomID: roomID, body: command, transactionID: UUID().uuidString)
    } catch MatrixError.http(let status, _, _) where status == 403 {
      rooms.removeValue(forKey: roomID)
      managementRoomIDs[network] = nil
      let fresh = try await ensureManagementRoom(for: network)
      return try await client.sendText(roomID: fresh, body: command, transactionID: UUID().uuidString)
    }
  }

  /// Un salon sans réseau (donc pas un portail) dont un membre est le bot de X est
  /// le salon de gestion de X. Les deux ponts en ont un, distinct.
  private func detectManagementRooms() {
    for model in rooms.values where model.network == nil {
      for userID in model.members.keys {
        guard let network = MatrixIdentity.network(ofBot: userID),
              managementRoomIDs[network] == nil
        else { continue }
        managementRoomIDs[network] = model.roomID
      }
    }
  }

  static func pairingCode(in body: String) -> String? {
    // Le bot annonce « Input the pairing code ABCD-EFGH in the WhatsApp app »,
    // parfois entre accents graves. La casse n'est pas garantie d'une version à l'autre.
    guard body.lowercased().contains("pairing code") else { return nil }
    let pattern = #"\b[A-Za-z0-9]{4}-[A-Za-z0-9]{4}\b"#
    guard let range = body.range(of: pattern, options: [.regularExpression]) else { return nil }
    return String(body[range]).uppercased()
  }

  /// « 12 WhatsApp · 3 Instagram » — un décompte qui dit de quoi l'inbox est faite.
  static func bridgedCountFR(_ conversations: [Conversation]) -> String {
    let parts = MessageNetwork.matrixBridged.compactMap { network -> String? in
      let count = conversations.filter { $0.network == network }.count
      return count > 0 ? "\(count) \(network.labelFR)" : nil
    }
    return parts.isEmpty ? "aucun fil bridgé" : parts.joined(separator: " · ")
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
