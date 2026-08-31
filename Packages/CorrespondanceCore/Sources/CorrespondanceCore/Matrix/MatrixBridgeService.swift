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
  /// La base locale. `nil` seulement si SQLite refuse d'ouvrir le fichier —
  /// l'app marche alors sans mémoire, plutôt que pas du tout.
  private let store: LocalStore?
  /// Salons dont l'historique est déjà relu du magasin. Un fil qu'on n'a pas
  /// ouvert n'a en mémoire que son dernier message : c'est ce qui fait que le
  /// lancement ne charge plus l'historique de toutes les conversations.
  private var loadedHistoryRoomIDs: Set<String> = []
  /// Salons dont la ligne d'inbox a bougé pendant cette passe : eux seuls sont
  /// réécrits. Plus jamais de réécriture globale.
  private var dirtyRoomIDs: Set<String> = []
  /// La réconciliation avec `/joined_rooms` n'a lieu qu'une fois par lancement.
  private var didReconcileJoinedRooms = false

  /// Ce qu'un fil charge à l'ouverture ; au-delà, on remonte à la demande.
  public static let historyPageSize = LocalStore.defaultPageSize

  public init(
    credentials: MatrixCredentials? = MatrixCredentialStore.load(),
    store: LocalStore? = LocalStore.shared
  ) {
    client = MatrixClient(credentials: credentials)
    self.store = store
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
    forgetEverything()
    return creds
  }

  public func disconnect() async {
    await client.logout()
    MatrixCredentialStore.clear()
    forgetEverything()
    selfUserID = ""
    loginCommandEventIDs = [:]
    loginCommandSentAt = [:]
  }

  /// « Recharger depuis le Relais » : la base se vide, le curseur repart de
  /// zéro, et le prochain `/sync` — initial, donc — la repeuple entièrement.
  /// La porte de secours quand la base raconte autre chose que le Relais.
  public func reloadFromRelay() {
    forgetEverything()
  }

  /// Tout oublier : la mémoire **et** la base.
  private func forgetEverything() {
    store?.reset()
    // Une base vidée n'a plus rien à relire : la prochaine passe repart d'un
    // sync initial, pas d'une hydratation sur du vide.
    didHydrate = true
    rooms = [:]
    nextBatch = nil
    managementRoomIDs = [:]
    loadedHistoryRoomIDs = []
    dirtyRoomIDs = []
    backfilledRoomIDs = []
    pendingTimelineGaps = [:]
    didReconcileJoinedRooms = false
  }

  // MARK: - Sync

  /// Reprend le curseur `next_batch` du cache et vérifie que la session tient encore.
  /// `false` = pas de credentials ou token périmé : l'appelant n'ouvre pas de boucle.
  /// Reprend l'inbox du disque, sans réseau : l'identité vient des identifiants
  /// enregistrés, la base locale fait le reste. C'est ce qui permet à l'écran
  /// de s'allumer avant que le tunnel (Tailscale, dehors) ne soit monté.
  public func restoreFromDisk() async -> Bool {
    guard let credentials = await client.currentCredentials else { return false }
    selfUserID = credentials.userID
    hydrateIfNeeded()
    return true
  }

  /// La session, vue du Relais. « Injoignable » n'est pas « invalide » : dehors,
  /// le premier est fréquent et passager, le second demande une reconnexion.
  public enum SessionCheck: Sendable { case valid, invalid, unreachable }

  public func checkSession() async -> SessionCheck {
    hydrateIfNeeded()
    guard await client.isConfigured else { return .invalid }
    do {
      selfUserID = try await client.whoami()
      return .valid
    } catch MatrixError.http(let status, let errcode, _) where status == 401 || errcode == "M_UNKNOWN_TOKEN" {
      return .invalid
    } catch {
      return .unreachable
    }
  }

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
    hydrateIfNeeded()
    if selfUserID.isEmpty { selfUserID = try await client.whoami() }
    let response = try await client.sync(since: nextBatch, timeoutMilliseconds: timeoutMilliseconds)
    let parser = MatrixSyncParser(selfUserID: selfUserID)
    // Avant `apply` : c'est l'état d'avant la passe qui dit jusqu'où remonter.
    for gap in MatrixSyncParser.timelineGaps(in: response, rooms: rooms) {
      pendingTimelineGaps[gap.roomID] = gap
    }
    let before = Set(rooms.keys)
    parser.apply(response, to: &rooms)
    parser.applyConversationState(response, to: &relayState)
    dirtyRoomIDs.formUnion(response.rooms?.join?.keys ?? [:].keys)
    let left = before.subtracting(rooms.keys)
    detectManagementRooms()
    await fillTimelineGaps()
    await fetchMissingQuoteTargets()
    // Les invitations d'abord, le curseur ensuite : Synapse n'envoie une
    // invitation de portail qu'une fois, et un curseur avancé sur un lot mal
    // digéré la perdrait pour de bon.
    await acceptBridgeInvites(response)
    nextBatch = response.nextBatch
    persist(cursor: response.nextBatch, leftRoomIDs: Array(left))
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
    hydrateIfNeeded()
    var list = rooms.values
      .compactMap { $0.conversation(selfUserID: selfUserID) }
    // La note à soi n'a pas de pont : c'est l'account data qui la désigne.
    if let roomID = relayState.selfNoteRoomID, let model = rooms[roomID] {
      list.append(model.selfNoteConversation(selfUserID: selfUserID))
    }
    return list.sorted { $0.lastMessageAt > $1.lastMessageAt }
  }

  /// Le salon de la note à soi, en le créant s'il n'existe pas encore.
  ///
  /// Un salon privé dont je suis le seul membre, désigné une fois pour toutes
  /// par l'account data global : le Mac et l'iPhone tombent donc sur le même,
  /// et personne n'en crée un second.
  @discardableResult
  public func ensureSelfNote() async throws -> String {
    if let existing = relayState.selfNoteRoomID { return existing }
    let roomID = try await client.createSelfRoom(name: MessageNetwork.selfNote.labelFR)
    try await client.setAccountData(
      type: ConversationStateKeys.selfNoteType,
      content: ConversationStateCodec.selfNoteContent(roomID: roomID)
    )
    relayState.selfNoteRoomID = roomID
    if rooms[roomID] == nil { rooms[roomID] = MatrixRoomModel(roomID: roomID) }
    return roomID
  }

  /// L'identifiant du fil de la note à soi, s'il existe déjà.
  public func selfNoteConversationID() -> String? {
    guard let roomID = relayState.selfNoteRoomID else { return nil }
    return "\(MessageNetwork.selfNote.rawValue):\(roomID)"
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

  /// « Alice écrit… » pour ce fil, ou `nil` si personne n'écrit.
  public func typingLabel(conversationID: String, now: Date = Date()) -> String? {
    guard let roomID = roomID(forConversation: conversationID) else { return nil }
    return rooms[roomID]?.typingLabelFR(now: now, selfUserID: selfUserID)
  }

  /// Dit au Relais qu'on écrit — ou qu'on a fini. Le pont le relaie au réseau
  /// (WhatsApp et Signal dans les deux sens ; Instagram l'envoie surtout).
  public func setTyping(conversationID: String, isTyping: Bool) async {
    guard let roomID = roomID(forConversation: conversationID) else { return }
    // Une frappe qui n'arrive pas n'est pas une erreur à montrer : on se tait.
    try? await client.sendTyping(roomID: roomID, isTyping: isTyping)
  }

  /// Le fil d'une conversation. Sa dernière page se relit du magasin à la
  /// première demande — au lancement, la mémoire ne porte que les lignes de
  /// l'inbox, pas l'historique de tous les fils.
  public func messages(conversationID: String) -> [ChatMessage] {
    hydrateIfNeeded()
    guard let roomID = roomID(forConversation: conversationID) else { return [] }
    loadHistoryIfNeeded(roomID: roomID)
    return rooms[roomID]?.sortedMessages ?? []
  }

  /// Ce qui précède ce qu'on a déjà : la page suivante en remontant, prise dans
  /// le magasin. Rend `[]` quand on a touché le fond de ce qui est stocké — au
  /// Relais alors de fournir la suite (`backfill`).
  @discardableResult
  public func loadOlderMessages(
    conversationID: String,
    limit: Int = MatrixBridgeService.historyPageSize
  ) -> [ChatMessage] {
    hydrateIfNeeded()
    guard let store, let roomID = roomID(forConversation: conversationID) else { return [] }
    loadHistoryIfNeeded(roomID: roomID)
    guard var model = rooms[roomID] else { return [] }
    let oldest = model.messagesByID.values.map(\.sentAt).min()
    let page = store.messages(roomID: roomID, limit: limit, before: oldest)
    guard !page.isEmpty else { return [] }
    MatrixSyncParser(selfUserID: selfUserID)
      .hydrate(messages: page, reactions: [:], into: &model)
    rooms[roomID] = model
    return page
  }

  /// Complète l'historique d'un salon (ouverture d'un fil encore court). Une
  /// fois par session et par salon : un fil qui reste court après ça l'est
  /// vraiment, inutile de redemander la même page à chaque ouverture.
  public func backfill(conversationID: String, limit: Int = 50) async -> [ChatMessage] {
    hydrateIfNeeded()
    guard let roomID = roomID(forConversation: conversationID) else { return [] }
    loadHistoryIfNeeded(roomID: roomID)
    guard !backfilledRoomIDs.contains(roomID) else { return rooms[roomID]?.sortedMessages ?? [] }
    backfilledRoomIDs.insert(roomID)
    do {
      let response = try await client.roomMessages(roomID: roomID, direction: "b", limit: limit)
      guard var model = rooms[roomID] else { return [] }
      MatrixSyncParser(selfUserID: selfUserID).applyMessages(response.chunk, roomID: roomID, to: &model)
      rooms[roomID] = model
      // Une page remontée une fois est écrite : elle ne se redemandera plus.
      dirtyRoomIDs.insert(roomID)
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
        // Le chemin local descendu vaut d'être gardé : sans ça, chaque
        // relancement retéléchargerait la même photo.
        rooms[roomID]?.markWritten(message.id)
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
      let sendsFallback = Self.sendsReplyFallback(on: rooms[roomID]?.network)
      try await client.sendText(
        roomID: roomID,
        body: text,
        replyToEventID: replyToMessageID,
        replyFallback: sendsFallback
          ? quoted.map { (sender: $0.senderID ?? selfUserID, text: $0.sidebarPreviewText) }
          : nil,
        transactionID: txnID
      )
    }
  }

  /// Faut-il joindre le repli « > <@x> … » à une réponse citée ?
  ///
  /// mautrix-signal transmet le corps **tel quel** : le repli arrive chez le
  /// correspondant en texte brut, MXID `@signal_…:correspondance.local` compris.
  /// La citation passe par `m.in_reply_to`, le repli n'apporte rien — on ne
  /// l'envoie pas. WhatsApp, lui, le retire correctement ; on ne change rien
  /// à ce qui marche.
  static func sendsReplyFallback(on network: MessageNetwork?) -> Bool {
    network != .signal
  }

  /// Pose, remplace ou retire ma réaction sur un message.
  ///
  /// WhatsApp comme Instagram n'acceptent **qu'un emoji par personne et par message**
  /// (`ReactionCount: 1` dans les capacités de mautrix-whatsapp et de mautrix-instagram) :
  /// reposer le même emoji le retire, en poser un autre remplace le précédent.
  /// Envoie un message vocal : le fichier enregistré et sa forme d'onde.
  /// Un `m.audio` marqué MSC3245, ce que les ponts traduisent en vocal chez
  /// WhatsApp et Signal (et en pièce jointe audio ailleurs).
  public func sendVoiceMessage(
    conversationID: String,
    fileURL: URL,
    voice: VoiceNote,
    localID: String
  ) async throws {
    guard let roomID = roomID(forConversation: conversationID) else {
      throw MatrixError.decoding("salon introuvable pour \(conversationID)")
    }
    try await client.sendVoiceMessage(
      roomID: roomID,
      fileURL: fileURL,
      voice: voice,
      transactionID: ledger.transactionID(forLocalID: localID)
    )
  }

  /// Vote sur un sondage. Le geste bascule : retoucher la réponse qu'on avait
  /// choisie la retire (`answers: []` — une abstention explicite, ce que
  /// MSC3381 prévoit).
  public func votePoll(conversationID: String, pollMessageID: String, answerID: String) async throws {
    guard let roomID = roomID(forConversation: conversationID),
          let entry = rooms[roomID]?.pollsByEventID[pollMessageID]
    else { throw MatrixError.decoding("sondage introuvable") }
    guard !entry.poll.isClosed else { return }
    let next = entry.poll.toggling(answerID)

    // La voix se voit tout de suite : le `/sync` la confirmera.
    applyMyVote(next, roomID: roomID, pollMessageID: pollMessageID)

    do {
      try await client.sendPollResponse(
        roomID: roomID,
        pollEventID: pollMessageID,
        answerIDs: next,
        responseType: PollEventTypes.responseType(forStart: entry.startType)
      )
    } catch {
      // Le Relais n'a rien reçu : la voix qu'on montrait n'existe pas, on la retire.
      applyMyVote(entry.poll.myAnswerIDs, roomID: roomID, pollMessageID: pollMessageID)
      throw error
    }
  }

  private func applyMyVote(_ answerIDs: [String], roomID: String, pollMessageID: String) {
    rooms[roomID]?.pollsByEventID[pollMessageID]?.poll.myAnswerIDs = answerIDs
    if answerIDs.isEmpty {
      rooms[roomID]?.pollsByEventID[pollMessageID]?.poll.votesByVoter.removeValue(forKey: selfUserID)
    } else {
      rooms[roomID]?.pollsByEventID[pollMessageID]?.poll.votesByVoter[selfUserID] = answerIDs
    }
    if var message = rooms[roomID]?.messagesByID[pollMessageID] {
      message.poll = rooms[roomID]?.pollsByEventID[pollMessageID]?.poll
      rooms[roomID]?.messagesByID[pollMessageID] = message
      rooms[roomID]?.markWritten(pollMessageID)
      dirtyRoomIDs.insert(roomID)
    }
  }

  /// Pose un sondage dans ce fil.
  public func sendPoll(
    conversationID: String,
    question: String,
    answers: [String],
    maxSelections: Int = 1
  ) async throws {
    guard let roomID = roomID(forConversation: conversationID) else {
      throw MatrixError.decoding("salon introuvable pour \(conversationID)")
    }
    try await client.sendPollStart(
      roomID: roomID,
      question: question,
      answers: answers,
      maxSelections: maxSelections
    )
  }

  public func toggleReaction(conversationID: String, messageID: String, emoji: String) async throws {
    guard let roomID = roomID(forConversation: conversationID) else {
      throw MatrixError.decoding("salon introuvable pour \(conversationID)")
    }
    let mine = rooms[roomID]?.reactionsByEventID
      .first { $0.value.targetEventID == messageID && $0.value.isMine }

    if let mine {
      try await client.redact(roomID: roomID, eventID: mine.key)
      rooms[roomID]?.reactionsByEventID.removeValue(forKey: mine.key)
      rooms[roomID]?.markDeleted(mine.key)
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
    rooms[roomID]?.markWritten(eventID)
    persist()
  }

  /// Supprime un message pour tout le monde : une `m.room.redaction` sur son event.
  ///
  /// Les trois ponts la traduisent dans les deux sens (`revoke` WhatsApp,
  /// `remote delete` Signal, `unsend` Meta) — c'est la même suppression que celle
  /// du téléphone. Le `/sync` la confirmera ; on retire l'event du modèle tout de
  /// suite pour que le fil ne le montre plus le temps du long-poll.
  /// Modifier un de mes messages. Refuse là où le réseau ne le sait pas faire
  /// (Instagram) : mieux vaut un geste absent qu'une correction qui n'arrive
  /// que chez soi.
  public func editMessage(conversationID: String, messageID: String, newText: String) async throws {
    guard let roomID = roomID(forConversation: conversationID),
          let message = rooms[roomID]?.messagesByID[messageID]
    else { throw MatrixError.decoding("message introuvable") }
    guard message.isFromMe else { throw MatrixError.decoding("on ne modifie que ses propres messages") }
    guard message.network.supportsEditing else {
      throw MatrixError.decoding("\(message.network.labelFR) ne sait pas modifier un message envoyé")
    }
    let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != message.text else { return }
    try await client.sendEdit(roomID: roomID, targetEventID: messageID, newText: trimmed)
  }

  public func deleteMessage(conversationID: String, messageID: String) async throws {
    guard let roomID = roomID(forConversation: conversationID) else {
      throw MatrixError.decoding("salon introuvable pour \(conversationID)")
    }
    try await client.redact(roomID: roomID, eventID: messageID)
    rooms[roomID]?.messagesByID.removeValue(forKey: messageID)
    rooms[roomID]?.markDeleted(messageID)
    // Une réaction dont la cible disparaît n'a plus de sens.
    for (id, reaction) in rooms[roomID]?.reactionsByEventID ?? [:]
    where reaction.targetEventID == messageID {
      rooms[roomID]?.reactionsByEventID.removeValue(forKey: id)
      rooms[roomID]?.markDeleted(id)
    }
    dirtyRoomIDs.insert(roomID)
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
    loadedHistoryRoomIDs.remove(roomID)
    store?.deleteRooms([roomID])
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
    case .agentSettings(let settings):
      try await client.setAccountData(
        type: ConversationStateKeys.agentSettingsType,
        content: ConversationStateCodec.agentSettingsContent(settings)
      )
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
      throw MatrixError.bridgeBotNotJoined(networkLabel: network.labelFR)
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

  /// Ajoute un contact à un groupe : on invite son ghost dans le portail, le pont
  /// fait l'ajout sur le réseau. WhatsApp prend un numéro (`@whatsapp_<num>`),
  /// Instagram un pseudo ou un identifiant Meta (`@instagram_<id>`). Signal
  /// n'identifie ses ghosts que par UUID : on ne sait pas les deviner d'un
  /// numéro, et on le dit plutôt que d'inviter dans le vide.
  public func inviteMember(conversationID: String, identifier: String) async throws {
    guard let roomID = roomID(forConversation: conversationID),
          let network = rooms[roomID]?.network,
          let bridge = network.bridge
    else { throw MatrixError.decoding("fil sans pont : impossible d'y ajouter quelqu'un") }
    let serverName = String(selfUserID.split(separator: ":").last ?? "")
    let localpart: String
    switch network {
    case .whatsapp:
      let digits = identifier.filter { $0.isNumber }
      guard digits.count >= 8 else { throw MatrixError.decoding("numéro WhatsApp invalide") }
      localpart = bridge.ghostPrefix + digits
    case .instagram:
      let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
      guard !trimmed.isEmpty else { throw MatrixError.decoding("identifiant Instagram vide") }
      let metaID = trimmed.allSatisfy(\.isNumber)
        ? trimmed
        : try await resolveMetaID(username: trimmed, network: network)
      localpart = bridge.ghostPrefix + metaID
    default:
      throw MatrixError.decoding("ajouter par numéro n'est pas possible sur \(network.labelFR)")
    }
    try await client.invite(roomID: roomID, userID: "@\(localpart):\(serverName)")
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
      throw MatrixError.bridgeBotNotJoined(networkLabel: network.labelFR)
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

  /// La base locale est relue dès le premier accès, pas seulement à l'ouverture
  /// de la boucle `/sync` : au lancement, l'inbox demande le fil de la
  /// conversation ouverte avant que la sync ait commencé, et un actor encore
  /// vide lui répondait « pas de messages » — le fil déjà à l'écran s'effaçait
  /// jusqu'au retour du serveur.
  ///
  /// Ce qu'on relit ici : **les salons seulement**, avec leur état (réseau,
  /// membres, pont, marqueurs de lecture) et leur dernier message, de quoi
  /// dresser l'inbox entière. L'historique d'un fil attend qu'on l'ouvre.
  ///
  /// Et le curseur reprend, lui aussi : l'état des salons étant gardé, un
  /// `/sync` incrémental ne laisse plus de salon anonyme derrière lui.
  private func hydrateIfNeeded() {
    guard !didHydrate else { return }
    didHydrate = true
    guard let store else { return }
    store.importLegacySnapshotIfNeeded(selfUserID: selfUserID)

    let stored = store.rooms()
    guard !stored.isEmpty else {
      nextBatch = store.syncCursor
      return
    }
    let previews = store.lastMessages()
    for room in stored {
      var model = room.model()
      // Le dernier message donne son aperçu à la ligne d'inbox ; sans lui, une
      // conversation rechargée retomberait sur « Écrire sur WhatsApp… ».
      if let last = previews[room.roomID] {
        model.messagesByID[last.id] = last
      }
      // Et les messages que les autres disent avoir lus : sans eux, la coche
      // « Vu » retomberait à « Envoyé » à chaque lancement.
      let markers = Set(model.readMarkerByUser.values).subtracting(model.messagesByID.keys)
      for message in store.messages(eventIDs: Array(markers)) {
        model.messagesByID[message.id] = message
      }
      model.clearPendingWrites()
      rooms[room.roomID] = model
    }
    nextBatch = store.syncCursor
  }

  /// Relit du magasin la dernière page d'un fil, une fois. Ce qui suit se
  /// demande en remontant (`loadOlderMessages`).
  private func loadHistoryIfNeeded(roomID: String) {
    guard let store, !loadedHistoryRoomIDs.contains(roomID) else { return }
    loadedHistoryRoomIDs.insert(roomID)
    guard var model = rooms[roomID] else { return }
    let page = store.messages(roomID: roomID, limit: Self.historyPageSize)
    let reactions = store.reactions(roomID: roomID)
    guard !page.isEmpty || !reactions.isEmpty else { return }
    MatrixSyncParser(selfUserID: selfUserID)
      .hydrate(messages: page, reactions: reactions, into: &model)
    rooms[roomID] = model
  }

  /// Une fois par lancement, en arrière-plan : ce que le Relais dit avoir
  /// rejoint, comparé à ce que la base connaît.
  ///
  /// Le curseur repris fait gagner un sync initial complet, mais il ferme aussi
  /// la porte : un salon rejoint pendant que l'app dormait — un portail créé
  /// par un pont, une invitation acceptée ailleurs — n'apparaîtrait dans aucun
  /// `/sync` incrémental. On demande donc la liste, et tout salon joint que la
  /// base ignore reçoit son état et ses derniers messages.
  @discardableResult
  public func reconcileJoinedRooms(limit: Int = 30) async -> [String] {
    guard !didReconcileJoinedRooms, await client.isConfigured else { return [] }
    didReconcileJoinedRooms = true
    hydrateIfNeeded()
    guard let joined = try? await client.joinedRooms() else { return [] }
    let unknown = joined.filter { rooms[$0] == nil }
    guard !unknown.isEmpty else { return [] }
    let parser = MatrixSyncParser(selfUserID: selfUserID)
    var adopted: [String] = []
    for roomID in unknown.prefix(limit) {
      var model = rooms[roomID] ?? MatrixRoomModel(roomID: roomID)
      guard let state = try? await client.roomStateEvents(roomID: roomID) else { continue }
      parser.applyState(state, roomID: roomID, to: &model)
      if let page = try? await client.roomMessages(roomID: roomID, direction: "b", limit: 30) {
        parser.applyMessages(page.chunk, roomID: roomID, to: &model)
      }
      rooms[roomID] = model
      dirtyRoomIDs.insert(roomID)
      adopted.append(roomID)
    }
    detectManagementRooms()
    persist()
    return adopted
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

  /// Écrit le lot : les salons qui ont bougé, les messages et réactions posés
  /// ou corrigés depuis la dernière passe, ce qui a été rédigé, puis le curseur
  /// — **une seule transaction**. Le curseur n'avance donc jamais sur un lot
  /// qui ne serait pas écrit.
  private func persist(cursor: String?? = nil, leftRoomIDs: [String] = []) {
    guard let store else { return }
    var storedRooms: [StoredRoom] = []
    var messages: [String: [ChatMessage]] = [:]
    var reactions: [String: [String: MatrixRoomModel.ReactionEvent]] = [:]
    var deleted: [String] = []

    for (roomID, model) in rooms {
      let hasChanges = !model.pendingWrites.isEmpty || !model.pendingDeletions.isEmpty
      guard hasChanges || dirtyRoomIDs.contains(roomID) else { continue }
      storedRooms.append(StoredRoom(model: model, selfUserID: selfUserID))
      var touchedMessages: [ChatMessage] = []
      var touchedReactions: [String: MatrixRoomModel.ReactionEvent] = [:]
      for eventID in model.pendingWrites {
        if let message = model.messagesByID[eventID] { touchedMessages.append(message) }
        if let reaction = model.reactionsByEventID[eventID] { touchedReactions[eventID] = reaction }
      }
      if !touchedMessages.isEmpty { messages[roomID] = touchedMessages }
      if !touchedReactions.isEmpty { reactions[roomID] = touchedReactions }
      deleted.append(contentsOf: model.pendingDeletions)
      rooms[roomID]?.clearPendingWrites()
    }
    dirtyRoomIDs.removeAll()

    store.commit(
      rooms: storedRooms,
      messages: messages,
      reactions: reactions,
      deletedEventIDs: deleted,
      deletedRoomIDs: leftRoomIDs,
      cursor: cursor
    )
  }
}
