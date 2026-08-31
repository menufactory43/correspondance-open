import Foundation

/// Pont entre le homeserver et l'inbox : tient l'état des salons, la boucle `/sync`,
/// l'envoi et les flux de connexion des ponts. Un seul `MatrixClient` en dessous.
///
/// Un seul `/sync` pour tous les ponts — ils vivent sur le même homeserver — mais
/// **un salon de gestion par pont** : le bot WhatsApp et le bot Instagram ne se
/// parlent pas, et une commande envoyée au mauvais bot reste sans réponse.
public actor MatrixBridgeService {
  private let client: MatrixClient
  private var rooms: [String: MatrixRoomModel] = [:]
  private var nextBatch: String?
  private var selfUserID: String = ""
  private var didHydrate = false
  /// Salon de gestion par réseau (commandes `login`, `pm`…).
  private var managementRoomIDs: [MessageNetwork: String] = [:]
  /// Invitations de bridge déjà traitées (évite de marteler `/join`).
  private var attemptedInviteJoins: Set<String> = []
  /// Invitations d'un pont qu'on n'a pas encore réussi à accepter. Elles ne
  /// reviendront pas d'elles-mêmes : un `/sync` incrémental ne réémet pas une
  /// invitation déjà envoyée. C'est donc à nous de les garder sous la main.
  private var pendingInviteJoins: Set<String> = []
  /// Event de la dernière commande `login` envoyée, par réseau : borne basse de lecture
  /// des réponses du bot (tout ce qui précède appartient à une tentative passée).
  private var loginCommandEventIDs: [MessageNetwork: String] = [:]
  /// Heure de la dernière commande `login`, par réseau : au-delà de quelques secondes
  /// sans que le bot ait rejoint le salon, ce n'est plus de la latence, c'est une panne.
  private var loginCommandSentAt: [MessageNetwork: Date] = [:]
  /// `txnId` par message optimiste : un renvoi ne duplique rien.
  private var ledger = MatrixTransactionLedger()
  /// Salons dont on a déjà demandé l'historique cette session.
  private var backfilledRoomIDs: Set<String> = []
  /// Trous de timeline signalés par `/sync` (`limited`) et pas encore comblés,
  /// par salon. Un `/sync` incrémental ne les resignale jamais : c'est à nous
  /// de les garder jusqu'à ce que le rattrapage passe.
  private var pendingTimelineGaps: [String: MatrixSyncParser.TimelineGap] = [:]
  /// Cibles de citation déjà demandées au Relais cette session, trouvées ou non.
  private var attemptedQuoteTargets: Set<String> = []
  /// L'état de conversation tel que le Relais le raconte (ADR 0001). Cumulatif :
  /// chaque `/sync` y fusionne ce qui a changé.
  private var relayState = ConversationStateSnapshot()

  public init(credentials: MatrixCredentials? = MatrixCredentialStore.load()) {
    client = MatrixClient(credentials: credentials)
    if let credentials { selfUserID = credentials.userID }
  }

  // MARK: - Session

  public var isConnected: Bool { !selfUserID.isEmpty }

  public var currentUserID: String { selfUserID }

  public func statusMessageFR() async -> String {
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
  public func connect(homeserver: URL, user: String, password: String) async throws -> MatrixCredentials {
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

  public func disconnect() async {
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
  public func restoreCursorAndCheckSession() async -> Bool {
    hydrateIfNeeded()
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
  public func syncOnce(timeoutMilliseconds: Int = 30_000) async throws -> [Conversation] {
    guard await client.isConfigured else { throw MatrixError.notConfigured }
    if selfUserID.isEmpty { selfUserID = try await client.whoami() }
    let response = try await client.sync(since: nextBatch, timeoutMilliseconds: timeoutMilliseconds)
    let parser = MatrixSyncParser(selfUserID: selfUserID)
    // Avant `apply` : c'est l'état d'avant la passe qui dit jusqu'où remonter.
    for gap in MatrixSyncParser.timelineGaps(in: response, rooms: rooms) {
      pendingTimelineGaps[gap.roomID] = gap
    }
    parser.apply(response, to: &rooms)
    parser.applyConversationState(response, to: &relayState)
    nextBatch = response.nextBatch
    detectManagementRooms()
    await fillTimelineGaps()
    await fetchMissingQuoteTargets()
    persist()
    await acceptBridgeInvites(response)
    return conversations()
  }

  /// Comble les trous de timeline laissés par `/sync` : remonte `/messages` depuis
  /// `prev_batch`, page par page, tant qu'une page apporte encore du nouveau —
  /// ou, sans borne connue, une seule page. « Tant que du nouveau » plutôt que
  /// « jusqu'au premier event connu » : un historique troué par le passé (salon
  /// rejoint en retard, anciennes absences) se répare ainsi au passage, dans
  /// la même borne. Un échec réseau laisse le trou en attente : on retentera à
  /// la passe suivante, le curseur ne le resignalera pas.
  private func fillTimelineGaps() async {
    let parser = MatrixSyncParser(selfUserID: selfUserID)
    for (roomID, gap) in pendingTimelineGaps.sorted(by: { $0.key < $1.key }) {
      guard rooms[roomID] != nil else {
        pendingTimelineGaps.removeValue(forKey: roomID)
        continue
      }
      var from = gap.prevBatch
      var pages = 0
      let maxPages = gap.hasAnchor ? Self.gapPagesWithAnchor : 1
      do {
        while pages < maxPages {
          let page = try await client.roomMessages(
            roomID: roomID, from: from, direction: "b", limit: Self.gapPageSize
          )
          pages += 1
          guard var model = rooms[roomID] else { break }
          let outcome = parser.applyMessages(page.chunk, roomID: roomID, to: &model)
          rooms[roomID] = model
          // Plus rien de nouveau, ou début du salon : le trou est comblé.
          guard outcome.added > 0, !page.chunk.isEmpty, let next = page.end else { break }
          from = next
        }
        pendingTimelineGaps.removeValue(forKey: roomID)
      } catch {
        // Réseau ou quota : le trou reste en attente pour la prochaine passe.
      }
    }
  }

  /// Va chercher au Relais les messages cités qu'on n'a pas : le pont Signal
  /// ne met que l'`event_id` dans une réponse, sans texte de repli, et la cible
  /// peut être plus vieille que tout ce qu'on a chargé. Un seul essai par
  /// event : une cible introuvable (message d'avant la liaison) le restera.
  private func fetchMissingQuoteTargets() async {
    let parser = MatrixSyncParser(selfUserID: selfUserID)
    var budget = Self.quoteFetchBudgetPerPass
    for roomID in rooms.keys.sorted() {
      guard budget > 0, let model = rooms[roomID] else { continue }
      let targets = MatrixSyncParser.missingQuoteTargets(in: model)
        .subtracting(attemptedQuoteTargets)
        .sorted()
      for eventID in targets where budget > 0 {
        budget -= 1
        attemptedQuoteTargets.insert(eventID)
        guard let json = try? await client.roomEvent(roomID: roomID, eventID: eventID),
              let data = try? JSONEncoder().encode(json),
              let event = try? JSONDecoder().decode(MatrixEvent.self, from: data),
              var current = rooms[roomID]
        else { continue }
        parser.applyMessages([event], roomID: roomID, to: &current)
        rooms[roomID] = current
      }
    }
  }

  /// Vingt-cinq cibles par passe : de quoi rattraper une soirée de groupe sans
  /// transformer un `/sync` en rafale de requêtes.
  private static let quoteFetchBudgetPerPass = 25

  private static let gapPageSize = 100
  /// Dix pages de cent : une longue absence sur un groupe très bavard, sans que
  /// le rattrapage devienne une aspiration de tout l'historique du salon.
  private static let gapPagesWithAnchor = 10

  /// Les portails (un par chat distant) arrivent sous forme d'invitations du bridge :
  /// sans double puppeting, c'est au client de les accepter. On ne rejoint que ce qui
  /// vient d'un bot ou d'un ghost de bridge — jamais une invitation humaine à l'aveugle.
  private func acceptBridgeInvites(_ response: MatrixSyncResponse) async {
    for (roomID, payload) in response.rooms?.invite ?? [:] where !attemptedInviteJoins.contains(roomID) {
      let events = payload["invite_state"]?["events"]?.arrayValue ?? []
      let fromBridge = events.contains { event in
        guard let sender = event["sender"]?.stringValue else { return false }
        return MatrixIdentity.isBridgeBot(sender) || MatrixIdentity.isGhost(sender)
      }
      if fromBridge { pendingInviteJoins.insert(roomID) }
    }
    // Un pont fraîchement lié crée ses portails en rafale : Synapse refuse alors
    // une partie des `join` (429). On les reprend à chaque passe jusqu'à ce qu'ils
    // passent — sans quoi les salons refusés resteraient invisibles pour toujours.
    for roomID in pendingInviteJoins {
      do {
        try await client.join(roomID: roomID)
        pendingInviteJoins.remove(roomID)
        attemptedInviteJoins.insert(roomID)
      } catch MatrixError.http(let status, _, _) where status == 403 {
        // Invitation retirée, ou salon disparu : insister ne sert à rien.
        pendingInviteJoins.remove(roomID)
        attemptedInviteJoins.insert(roomID)
      } catch {
        // Réseau ou quota : on retentera au prochain `/sync`.
      }
    }
  }

  public func conversations() -> [Conversation] {
    rooms.values
      .compactMap { $0.conversation(selfUserID: selfUserID) }
      .sorted { $0.lastMessageAt > $1.lastMessageAt }
  }

  public struct Member: Sendable, Hashable {
    public let userID: String
    public let displayName: String?
    public let avatarMXC: String?
  }

  /// Les correspondants d'un salon — ni moi, ni le bot, ni mon propre ghost.
  public func members(conversationID: String) -> [Member] {
    guard let model = rooms.values.first(where: { $0.conversationID == conversationID }) else { return [] }
    return model.remoteMembers(selfUserID: selfUserID).map {
      Member(userID: $0.userID, displayName: $0.member.displayName, avatarMXC: $0.member.avatarMXC)
    }
  }

  /// Les fils que le pont annonce comme des demandes — vide tant qu'aucun
  /// pont ne l'annonce (voir `MatrixRoomModel.isNetworkFlaggedRequest`).
  public func networkFlaggedRequestIDs() -> Set<String> {
    Set(rooms.values.filter(\.isNetworkFlaggedRequest).map(\.conversationID))
  }

  public func messages(conversationID: String) -> [ChatMessage] {
    hydrateIfNeeded()
    guard let roomID = roomID(forConversation: conversationID) else { return [] }
    return rooms[roomID]?.sortedMessages ?? []
  }

  /// Complète l'historique d'un salon (ouverture d'un fil encore court). Une
  /// fois par session et par salon : un fil qui reste court après ça l'est
  /// vraiment, inutile de redemander la même page à chaque ouverture.
  public func backfill(conversationID: String, limit: Int = 50) async -> [ChatMessage] {
    hydrateIfNeeded()
    guard let roomID = roomID(forConversation: conversationID) else { return [] }
    guard !backfilledRoomIDs.contains(roomID) else { return rooms[roomID]?.sortedMessages ?? [] }
    backfilledRoomIDs.insert(roomID)
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
  public func ensureLocalAttachments(_ messages: [ChatMessage]) async -> [ChatMessage] {
    var result: [ChatMessage] = []
    for message in messages {
      guard !message.attachments.isEmpty || message.linkPreview?.imageMXC != nil else {
        result.append(message)
        continue
      }
      var updated = message
      // La vignette d'un aperçu de lien vit sur le Relais comme une pièce jointe.
      if var preview = updated.linkPreview, let mxc = preview.imageMXC, preview.imageLocalPath == nil {
        if let path = MatrixAttachmentStore.existingLocalPath(forMXC: mxc, contentType: preview.imageContentType) {
          preview.imageLocalPath = path
        } else if let data = try? await client.downloadMedia(mxcURI: mxc), !data.isEmpty {
          preview.imageLocalPath = MatrixAttachmentStore.store(
            data: data, forMXC: mxc, contentType: preview.imageContentType
          )
        }
        updated.linkPreview = preview
      }
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
      // Sans toucher aux réactions : `messagesByID` garde ce qu'il avait (rien
      // pour un event du `/sync`, l'agrégat du cache pour un message semé), et
      // l'agrégation vivante se refait à la lecture depuis `reactionsByEventID`.
      if let roomID = roomID(forConversation: message.conversationID) {
        var canonical = updated
        canonical.reactions = rooms[roomID]?.messagesByID[message.id]?.reactions ?? []
        rooms[roomID]?.messagesByID[message.id] = canonical
      }
      result.append(updated)
    }
    return result
  }

  /// Photo d'un portail (`m.room.avatar`), depuis le cache disque sinon le homeserver.
  /// L'inbox en a besoin pour les fils sans numéro : Instagram n'expose rien d'autre.
  public func avatarData(mxcURI: String) async -> Data? {
    if let cached = MatrixAvatarStore.existingData(forMXC: mxcURI) { return cached }
    guard let data = try? await client.downloadMedia(mxcURI: mxcURI), !data.isEmpty else { return nil }
    MatrixAvatarStore.store(data: data, forMXC: mxcURI)
    return data
  }

  // MARK: - Envoi

  public func send(
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
  public func toggleReaction(conversationID: String, messageID: String, emoji: String) async throws {
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

  /// Supprime un message pour tout le monde : une `m.room.redaction` sur son event.
  ///
  /// Les trois ponts la traduisent dans les deux sens (`revoke` WhatsApp,
  /// `remote delete` Signal, `unsend` Meta) — c'est la même suppression que celle
  /// du téléphone. Le `/sync` la confirmera ; on retire l'event du modèle tout de
  /// suite pour que le fil ne le montre plus le temps du long-poll.
  public func deleteMessage(conversationID: String, messageID: String) async throws {
    guard let roomID = roomID(forConversation: conversationID) else {
      throw MatrixError.decoding("salon introuvable pour \(conversationID)")
    }
    try await client.redact(roomID: roomID, eventID: messageID)
    rooms[roomID]?.messagesByID.removeValue(forKey: messageID)
    // Une réaction dont la cible disparaît n'a plus de sens.
    for (id, reaction) in rooms[roomID]?.reactionsByEventID ?? [:]
    where reaction.targetEventID == messageID {
      rooms[roomID]?.reactionsByEventID.removeValue(forKey: id)
    }
    persist()
  }

  /// Photo d'un participant (`m.room.member` → `avatar_url`) : c'est elle que le
  /// fil pose à gauche des bulles d'un groupe, où chaque bulle a un autre visage.
  public func memberAvatarData(conversationID: String, userID: String) async -> Data? {
    guard let model = rooms.values.first(where: { $0.conversationID == conversationID }),
          let mxc = model.members[userID]?.avatarMXC, !mxc.isEmpty
    else { return nil }
    return await avatarData(mxcURI: mxc)
  }

  /// Marque le fil lu côté réseau, à l'ouverture. Silencieux en cas d'échec :
  /// un accusé perdu ne doit pas faire échouer l'ouverture d'une conversation.
  public func markRead(conversationID: String) async {
    guard let roomID = roomID(forConversation: conversationID),
          let last = rooms[roomID]?.sortedMessages.last,
          // Marquer nos propres messages n'apprend rien à personne.
          !last.isFromMe
    else { return }
    try? await client.sendReadReceipt(roomID: roomID, eventID: last.id)
  }

  /// Quitte le salon d'un fil, et l'oublie côté cache : quitter le portail d'un
  /// groupe revient à quitter le groupe sur le réseau distant.
  public func leaveRoom(conversationID: String) async throws {
    guard let roomID = roomID(forConversation: conversationID) else { return }
    try await client.leave(roomID: roomID)
    rooms.removeValue(forKey: roomID)
  }

  // MARK: - Push

  /// Déclare le pusher de cet appareil auprès du Relais.
  /// `sygnalURL` est celle que **Synapse** voit, pas nous.
  public func setPusher(
    pushkey: String,
    sygnalURL: URL,
    deviceDisplayName: String
  ) async throws {
    try await client.setPusher(
      pushkey: pushkey,
      sygnalURL: sygnalURL,
      deviceDisplayName: deviceDisplayName
    )
  }

  /// Retire le pusher — à la déconnexion, tant que le jeton d'accès vaut encore.
  public func removePusher(pushkey: String) async throws {
    try await client.removePusher(pushkey: pushkey)
  }

  // MARK: - État de conversation (Relais)

  /// L'état que le Relais a déjà raconté à cette session.
  public var conversationState: ConversationStateSnapshot { relayState }

  /// Relit tout l'état depuis le Relais, sans consommer le curseur `/sync` :
  /// un sync initial filtré (aucun message, aucun état de salon) ne rapporte
  /// que les tags et les account data. C'est ce qui fait revenir l'archive
  /// après un `defaults delete`, ou sur un appareil neuf.
  @discardableResult
  public func fetchConversationState() async throws -> ConversationStateSnapshot {
    guard await client.isConfigured else { throw MatrixError.notConfigured }
    let filter = #"{"room":{"timeline":{"limit":0},"state":{"types":[]}},"presence":{"types":[]}}"#
    let response = try await client.sync(since: nil, timeoutMilliseconds: 0, filter: filter)
    var snapshot = ConversationStateSnapshot()
    snapshot.apply(response)
    relayState = snapshot
    return snapshot
  }

  /// Envoie une écriture en attente. Jette si le Relais refuse — l'appelant la
  /// garde alors dans sa file et la reprendra au prochain `/sync` réussi.
  public func perform(_ write: RelayWrite) async throws {
    switch write {
    case .archived(let roomID, let value):
      try await setTag(roomID: roomID, tag: ConversationStateKeys.archivedTag, on: value)
    case .pinned(let roomID, let value):
      try await setTag(roomID: roomID, tag: ConversationStateKeys.favouriteTag, on: value)
    case .muted(let roomID, let value):
      try await client.setRoomPushRule(roomID: roomID, muted: value)
    case .draft(let roomID, let text):
      try await client.setRoomAccountData(
        roomID: roomID,
        type: ConversationStateKeys.draftType,
        content: ConversationStateCodec.draftContent(text: text)
      )
    case .hidden(let roomID, let eventIDs):
      try await client.setRoomAccountData(
        roomID: roomID,
        type: ConversationStateKeys.hiddenType,
        content: ConversationStateCodec.hiddenContent(eventIDs: eventIDs)
      )
    case .reminder(let roomID, let value):
      try await client.setRoomAccountData(
        roomID: roomID,
        type: ConversationStateKeys.reminderType,
        content: ConversationStateCodec.reminderContent(value)
      )
    case .request(let roomID, let value):
      try await client.setRoomAccountData(
        roomID: roomID,
        type: ConversationStateKeys.requestType,
        content: ConversationStateCodec.requestContent(value)
      )
    case .mergedContacts(let stored):
      guard let content = ConversationStateCodec.mergedContactsContent(stored) else { return }
      try await client.setAccountData(type: ConversationStateKeys.mergedContactsType, content: content)
    }
    // L'écriture partie, on la pose aussi sur notre copie : le `/sync` qui la
    // renverra n'apprendra rien de neuf, et rien ne clignote entre-temps.
    write.apply(to: &relayState)
  }

  private func setTag(roomID: String, tag: String, on: Bool) async throws {
    if on {
      try await client.setRoomTag(roomID: roomID, tag: tag)
    } else {
      do {
        try await client.removeRoomTag(roomID: roomID, tag: tag)
      } catch MatrixError.http(let status, _, _) where status == 404 {
        // Le tag n'était pas posé : rien à retirer.
      }
    }
  }

  /// Range des identifiants de messages par salon. Sert à la migration unique :
  /// l'ensemble des messages masqués est global côté Mac, alors que le Relais
  /// les range salon par salon.
  public func roomIDs(ofMessages messageIDs: Set<String>) -> [String: Set<String>] {
    var result: [String: Set<String>] = [:]
    for (roomID, model) in rooms {
      let mine = messageIDs.filter { model.messagesByID[$0] != nil }
      if !mine.isEmpty { result[roomID] = mine }
    }
    return result
  }

  /// Le salon d'un fil, pour les écritures d'état. `nil` si le fil n'est pas
  /// bridgé (iMessage) ou si son salon n'est pas connu de cette session.
  public func roomID(ofConversation conversationID: String) -> String? {
    roomID(forConversation: conversationID)
  }

  // MARK: - Connexion d'un pont

  /// Où en est le bot dans le flux de connexion, quel que soit le pont.
  public enum BridgeLoginStep: Sendable, Equatable {
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
  public enum BridgeLoginInput: Sendable, Equatable {
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
  public func startLogin(network: MessageNetwork, input: BridgeLoginInput) async throws {
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
  public func submitLoginCookies(_ raw: String, network: MessageNetwork) async throws {
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
  public func loginStep(network: MessageNetwork) async throws -> BridgeLoginStep {
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
  public static func loginStep(inBotMessage body: String) -> BridgeLoginStep? {
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
  public func startConversation(network: MessageNetwork, identifier: String) async throws {
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
  public static func firstSearchResultID(in body: String) -> String? {
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

  public static func pairingCode(in body: String) -> String? {
    // Le bot annonce « Input the pairing code ABCD-EFGH in the WhatsApp app »,
    // parfois entre accents graves. La casse n'est pas garantie d'une version à l'autre.
    guard body.lowercased().contains("pairing code") else { return nil }
    let pattern = #"\b[A-Za-z0-9]{4}-[A-Za-z0-9]{4}\b"#
    guard let range = body.range(of: pattern, options: [.regularExpression]) else { return nil }
    return String(body[range]).uppercased()
  }

  /// « 12 WhatsApp · 3 Instagram » — un décompte qui dit de quoi l'inbox est faite.
  public static func bridgedCountFR(_ conversations: [Conversation]) -> String {
    let parts = MessageNetwork.matrixBridged.compactMap { network -> String? in
      let count = conversations.filter { $0.network == network }.count
      return count > 0 ? "\(count) \(network.labelFR)" : nil
    }
    return parts.isEmpty ? "aucun fil bridgé" : parts.joined(separator: " · ")
  }

  // MARK: - Privé

  /// Le cache disque est repris dès le premier accès, pas seulement à l'ouverture
  /// de la boucle `/sync` : au lancement, `load()` demande le fil de la conversation
  /// ouverte avant que la sync ait commencé, et un actor encore vide lui répondait
  /// « pas de messages » — le fil déjà à l'écran s'effaçait derrière un repère
  /// jusqu'au retour du serveur.
  ///
  /// Le sync initial ne ramène qu'une poignée d'events par salon : sans ce semis,
  /// `persist()` réécrirait le fichier avec ça, et tout ce que les sessions
  /// précédentes avaient backfillé disparaîtrait à chaque relance. Le curseur, lui,
  /// n'est pas repris : Synapse n'envoie les invitations de portails qu'une fois,
  /// et un sync initial à chaque lancement reste léger sur un homeserver privé.
  private func hydrateIfNeeded() {
    guard !didHydrate else { return }
    didHydrate = true
    let (_, _, cachedMessages) = MatrixConversationCache.load()
    MatrixSyncParser(selfUserID: selfUserID).seed(cachedMessages: cachedMessages, into: &rooms)
  }

  /// Un salon semé depuis le cache ne connaît pas encore son réseau (il vient de
  /// l'état, donc du `/sync`) : son `conversationID` ne correspond pas. Le salon
  /// lui-même, en revanche, se lit dans l'identifiant demandé.
  private func roomID(forConversation conversationID: String) -> String? {
    if let match = rooms.values.first(where: { $0.conversationID == conversationID }) {
      return match.roomID
    }
    guard let parsed = MatrixSyncParser.roomID(inConversationID: conversationID),
          rooms[parsed] != nil
    else { return nil }
    return parsed
  }

  private func persist() {
    var messages: [String: [ChatMessage]] = [:]
    for model in rooms.values where model.network != nil {
      messages[model.conversationID] = model.sortedMessages
    }
    MatrixConversationCache.save(nextBatch: nextBatch, conversations: conversations(), messages: messages)
  }
}
