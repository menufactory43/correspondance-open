import Foundation

/// Pont entre le homeserver et l'inbox : tient l'état des salons, la boucle `/sync`,
/// l'envoi et les flux de connexion des ponts. Un seul `MatrixClient` en dessous.
///
/// Un seul `/sync` pour tous les ponts — ils vivent sur le même homeserver — mais
/// **un salon de gestion par pont** : le bot WhatsApp et le bot Instagram ne se
/// parlent pas, et une commande envoyée au mauvais bot reste sans réponse.
public actor MatrixBridgeService {
  /// Interne, et pas `private` : les extensions du service (la console d'un
  /// agent, par exemple) vivent dans d'autres fichiers du même module.
  let client: MatrixClient
  private var rooms: [String: MatrixRoomModel] = [:]
  private var nextBatch: String?
  /// Interne : les extensions du service, dans leurs propres fichiers, en ont
  /// besoin pour déduire le serveur (le MXID d'un agent, par exemple).
  private(set) var selfUserID: String = ""
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

  // MARK: - Démonstration

  /// Avale un payload `/sync` sans réseau ni base : c'est le mode démonstration,
  /// qui montre exactement ce que le Relais montrerait — mêmes payloads, même
  /// analyseur. À n'appeler que sur un service construit sans magasin
  /// (`store: nil`) : rien de ce qui entre ici ne doit toucher la base réelle.
  public func ingestDemo(_ response: MatrixSyncResponse, selfUserID: String) {
    didHydrate = true
    self.selfUserID = selfUserID
    let parser = MatrixSyncParser(selfUserID: selfUserID)
    parser.apply(response, to: &rooms)
    parser.applyConversationState(response, to: &relayState)
    detectManagementRooms()
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
  /// L'état du chiffrement, tel que les réglages l'affichent : « chiffrement :
  /// actif · cet appareil : vérifié ou non · sauvegarde : faite ou non ».
  ///
  /// Il passe par le service plutôt que par le client parce que l'écran n'a
  /// aucune raison de connaître `MatrixClient` — et parce qu'un binaire sans
  /// crypto doit répondre quelque chose, pas planter.
  public func etatDuChiffrement() async -> MatrixEtatChiffrement {
    await client.etatDuChiffrement()
  }

  /// Les appareils du compte, pour l'écran qui les liste.
  public func appareilsDuCompte() async -> [MatrixAppareil] {
    (try? await client.appareilsDuCompte()) ?? []
  }

  public func syncOnce(timeoutMilliseconds: Int = 30_000) async throws -> [Conversation] {
    guard await client.isConfigured else { throw MatrixError.notConfigured }
    hydrateIfNeeded()
    if selfUserID.isEmpty { selfUserID = try await client.whoami() }
    // Le chiffrement, s'il est compilé **et** demandé. Sans les deux, cet appel
    // ne fait rien et le /sync qui suit est celui d'avant.
    if let ligne = await MatrixChiffrement.brancher(sur: client) { print("[Correspondance] \(ligne)") }
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

  /// Le tête-à-tête avec un agent : le fil existant s'il y en a un — un
  /// salon marqué `agent` où il n'y a que lui et moi — sinon un salon neuf,
  /// marqué à la création, où l'agent est invité. Il accepte à sa prochaine
  /// synchro, parce qu'un propriétaire l'a invité.
  public func openAgentConversation(agent: String) async throws -> String {
    let agentID = MatrixIdentity.agentUserID(named: agent, sameServerAs: selfUserID)
    hydrateIfNeeded()
    if let existing = rooms.values.first(where: { room in
      room.network == .agent && room.agentNames(selfUserID: selfUserID) == [agent]
        && room.remoteMembers(selfUserID: selfUserID).allSatisfy { MatrixIdentity.isAgent($0.userID) }
    }) {
      return existing.conversationID
    }
    let roomID = try await client.createPrivateRoom(
      name: agent, invite: [agentID], isDirect: true,
      initialState: [(
        type: AgentWire.conversationType,
        // `agent` : à qui est ce fil. Si un second agent y est invité un
        // jour, c'est celui-ci qui répond à ce qui ne nomme personne.
        content: .object([
          AgentWire.ConversationKey.kind: .string(AgentWire.ConversationKind.agent),
          AgentWire.ConversationKey.agent: .string(agent),
        ])
      )]
    )
    var model = rooms[roomID] ?? MatrixRoomModel(roomID: roomID)
    model.network = .agent
    model.explicitName = agent
    model.members[selfUserID] = MatrixRoomModel.Member(displayName: nil, membership: "join")
    model.members[agentID] = MatrixRoomModel.Member(displayName: agent, membership: "invite")
    rooms[roomID] = model
    dirtyRoomIDs.insert(roomID)
    return model.conversationID
  }


  public struct Member: Sendable, Hashable {
    public let userID: String
    public let displayName: String?
    public let avatarMXC: String?
  }

  /// Les correspondants d'un salon — ni moi, ni le bot, ni mon propre ghost.
  public func members(conversationID: String) -> [Member] {
    hydrateIfNeeded()
    guard let model = rooms.values.first(where: { $0.conversationID == conversationID }) else { return [] }
    return model.remoteMembers(selfUserID: selfUserID).map {
      Member(userID: $0.userID, displayName: $0.member.displayName, avatarMXC: $0.member.avatarMXC)
    }
  }

  /// Le Matrix ID de l'agent « cc » sur ce Relais — même serveur que moi.
  public var agentUserID: String {
    MatrixIdentity.agentUserID(sameServerAs: selfUserID)
  }

  /// Ce que l'agent dit de lui-même : à chaque démarrage il scanne sa machine
  /// et poste `fr.correspondance.agent.status` dans la note à soi —
  /// « moteur hermes · prêts : claude, hermes ». C'est ainsi que les réglages
  /// savent si un Hermes est présent, sans SSH : les moteurs vivent là où
  /// l'agent tourne, pas là où l'app tourne. (La présence Matrix aurait été le
  /// canal naturel ; elle est éteinte sur le Relais, exprès.)
  public struct AgentStatus: Sendable, Equatable {
    /// La ligne des moteurs, telle que l'agent l'a publiée.
    public var engines: String
    /// Le démarrage qui l'a publiée — un status vieux d'un mois parle d'un
    /// agent qui ne redémarre plus.
    public var publishedAt: Date
    /// L'adresse de sa machine, telle qu'il l'a lue sur ses interfaces
    /// (`AgentWire.StatusKey.address`). `nil` pour un agent d'avant cette
    /// version.
    public var address: String?

    public init(engines: String, publishedAt: Date, address: String? = nil) {
      self.engines = engines
      self.publishedAt = publishedAt
      self.address = address
    }

    /// La machine où l'agent tourne, lue dans « cc tourne sur umbrel depuis
    /// 14 h 02 · moteur acp · prêts : claude ».
    ///
    /// **C'est la seule preuve qu'on ait de l'hôte d'un agent distant** : l'app
    /// n'a rien installé là-bas et ne peut pas y regarder. Un `nil` se dit
    /// « on ne sait pas où », jamais « sur ce Mac ».
    public var host: String? {
      guard let apres = engines.range(of: "tourne sur ") else { return nil }
      let reste = engines[apres.upperBound...]
      let fin = reste.firstIndex(of: "·") ?? reste.endIndex
      var nom = reste[..<fin]
      if let depuis = nom.range(of: " depuis ") { nom = nom[..<depuis.lowerBound] }
      let texte = nom.trimmingCharacters(in: .whitespaces)
      return texte.isEmpty ? nil : texte
    }

    /// Le moteur configuré, lu dans « · moteur acp · ».
    public var backend: String? {
      guard let apres = engines.range(of: "moteur ") else { return nil }
      let reste = engines[apres.upperBound...]
      let fin = reste.firstIndex(of: "·") ?? reste.endIndex
      let texte = reste[..<fin].trimmingCharacters(in: .whitespaces)
      return texte.isEmpty ? nil : texte
    }

    /// Les moteurs prêts **sur la machine de l'agent**, lus dans
    /// « prêts : claude, hermes ». Vide veut dire « il n'en a annoncé aucun »,
    /// pas « il n'y en a pas » : un agent d'avant le scan n'en publie aucun.
    public var enginesReady: [String] { liste(apres: "prêts : ") }

    /// Les moteurs **installés mais pas connectés** sur la machine de l'agent,
    /// lus dans « à connecter : grok ». L'agent ne les dit pas prêts : un tour
    /// dessus n'est qu'une erreur d'authentification. On les montre pour que
    /// le geste se fasse là-bas, pas pour les proposer.
    public var enginesToConnect: [String] { liste(apres: "à connecter : ") }

    /// Une liste du status : après son étiquette, jusqu'au prochain « · ».
    private func liste(apres etiquette: String) -> [String] {
      guard let apres = engines.range(of: etiquette) else { return [] }
      let reste = engines[apres.upperBound...]
      let fin = reste.range(of: " · ")?.lowerBound ?? reste.endIndex
      return reste[..<fin]
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && $0 != "aucun" }
    }

    /// Un status daté de moins d'une heure : l'agent a donné signe de vie.
    /// Le seuil est large exprès — un agent qui n'a rien à faire ne poste rien.
    public func isFresh(now: Date = Date(), silenceMax: TimeInterval = 3600) -> Bool {
      now.timeIntervalSince(publishedAt) <= silenceMax
    }
  }

  /// Le dernier status de cc dans la note à soi, ou `nil` : agent jamais
  /// démarré, trop ancien pour publier, ou pas invité dans la note à soi.
  public func agentStatus() async throws -> AgentStatus? {
    guard let roomID = relayState.selfNoteRoomID else { return nil }
    let messages = try await client.roomMessages(roomID: roomID, limit: 80)
    let status = messages.chunk.first { event in
      event.type == "fr.correspondance.agent.status" && event.sender == agentUserID
    }
    guard let status, let body = status.content?.string(at: "body") else { return nil }
    return AgentStatus(engines: body, publishedAt: status.sentAt)
  }

  /// Cet agent est-il déjà membre (ou invité) de ce fil ?
  public func hasAgent(conversationID: String, agent: String = MatrixIdentity.agentName) -> Bool {
    hydrateIfNeeded()
    // Par le résolveur, pas par `conversationID` du modèle : la note à soi et
    // le fil d'un agent portent un identifiant construit à la volée, et cc y
    // passait pour absent — la carte Assistant ne s'y montrait jamais.
    guard let roomID = roomID(forConversation: conversationID), let model = rooms[roomID] else { return false }
    let userID = MatrixIdentity.agentUserID(named: agent, sameServerAs: selfUserID)
    return model.members[userID]?.isActive == true
  }

  /// Les agents présents (ou invités) dans ce fil, parmi ceux qu'on nomme.
  /// C'est ce qui décide entre un bouton « Inviter cc » et un menu : la
  /// question « lesquels sont là » se pose au salon, pas à un réglage.
  public func agentsPresent(conversationID: String, among agents: [String]) -> [String] {
    agents.filter { hasAgent(conversationID: conversationID, agent: $0) }
  }

  /// Invite « cc » dans le fil. Il ne rejoint que sur MON invitation — c'est
  /// précisément elle. Le fil affichera « cc a rejoint la conversation ».
  public func inviteAgent(conversationID: String, agent: String = MatrixIdentity.agentName) async throws {
    guard let roomID = roomID(forConversation: conversationID) else {
      throw MatrixError.decoding("salon introuvable pour \(conversationID)")
    }
    let userID = MatrixIdentity.agentUserID(named: agent, sameServerAs: selfUserID)
    // Le pont ne m'a pas toujours donné le droit d'inviter dans ce portail :
    // `withRoomPower` se hisse et réessaie. On n'ajoute personne au groupe
    // réel — cc est un utilisateur Matrix, les ponts ne relaient pas les
    // adhésions de gens qui n'ont pas de compte sur le réseau.
    try await withRoomPower(roomID: roomID) {
      try await self.client.invite(roomID: roomID, userID: userID)
    }
  }

  /// Allume ou éteint le **relais** d'un portail : c'est ce qui permet à cc de
  /// parler à voix haute dans une conversation WhatsApp ou Signal. Sans lui, le
  /// pont refuse tout message qui ne vient pas de mon compte — « You're not
  /// logged in (relay not set) », vu en vrai. Avec, il part depuis mon compte,
  /// signé par le pont (« 🤖 cc : … », `message_formats`). La commande se donne
  /// dans le portail lui-même ; le pont la lit et ne la relaie pas. Rend `false`
  /// quand le fil n'est pas un portail : il n'y a alors rien à allumer.
  /// Ce fil est-il un portail de pont ? Un agent n'y parle à voix haute que
  /// si le relais du pont est allumé (`setPortalRelay`).
  public func isPortal(conversationID: String) -> Bool {
    guard let roomID = roomID(forConversation: conversationID) else { return false }
    return rooms[roomID]?.network?.bridge != nil
  }

  @discardableResult
  public func setPortalRelay(conversationID: String, enabled: Bool) async throws -> Bool {
    guard let roomID = roomID(forConversation: conversationID) else {
      throw MatrixError.decoding("salon introuvable pour \(conversationID)")
    }
    guard let network = rooms[roomID]?.network, let bridge = network.bridge else { return false }
    let command = "\(bridge.commandPrefix) \(enabled ? "set-relay" : "unset-relay")"
    _ = try await client.sendText(roomID: roomID, body: command, transactionID: UUID().uuidString)
    return true
  }

  /// Les fils que le pont annonce comme des demandes — vide tant qu'aucun
  /// pont ne l'annonce (voir `MatrixRoomModel.isNetworkFlaggedRequest`).
  public func networkFlaggedRequestIDs() -> Set<String> {
    hydrateIfNeeded()
    return Set(rooms.values.filter(\.isNetworkFlaggedRequest).map(\.conversationID))
  }

  /// « Alice écrit… » pour ce fil, ou `nil` si personne n'écrit.
  public func typingLabel(conversationID: String, now: Date = Date()) -> String? {
    hydrateIfNeeded()
    guard let roomID = roomID(forConversation: conversationID) else { return nil }
    return rooms[roomID]?.typingLabelFR(now: now, selfUserID: selfUserID)
  }

  /// « Vu par Alice et Bruno » pour ce fil de groupe, ou `nil` : en DM le
  /// « Vu » de `Conversation.lastDelivery` dit déjà tout.
  public func seenByLabel(conversationID: String) -> String? {
    hydrateIfNeeded()
    guard let roomID = roomID(forConversation: conversationID) else { return nil }
    return rooms[roomID]?.seenByLabelFR(selfUserID: selfUserID)
  }

  /// Dit au Relais qu'on écrit — ou qu'on a fini. Le pont le relaie au réseau
  /// (WhatsApp et Signal dans les deux sens ; Instagram et Messenger l'envoient surtout).
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
    // Les téléchargements manquants partent de front avant la passe message
    // par message : en série, un groupe de quinze photos coûtait quinze
    // allers-retours l'un derrière l'autre.
    await prefetchMissingMedia(for: messages)
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

  /// Descend en parallèle (quatre de front — assez pour masquer la latence,
  /// sans assommer le Relais) tout média encore absent du cache disque. La
  /// passe message par message qui suit ne trouve alors plus rien à attendre.
  private func prefetchMissingMedia(for messages: [ChatMessage]) async {
    struct Missing: Sendable {
      let mxc: String
      let contentType: String?
    }
    var missingByMXC: [String: Missing] = [:]
    for message in messages {
      if let preview = message.linkPreview, let mxc = preview.imageMXC,
         preview.imageLocalPath == nil,
         MatrixAttachmentStore.existingLocalPath(forMXC: mxc, contentType: preview.imageContentType) == nil
      {
        missingByMXC[mxc] = Missing(mxc: mxc, contentType: preview.imageContentType)
      }
      for attachment in message.attachments
      where attachment.resolvedFileURL == nil
        && MatrixAttachmentStore.existingLocalPath(forMXC: attachment.id, contentType: attachment.contentType) == nil
      {
        missingByMXC[attachment.id] = Missing(mxc: attachment.id, contentType: attachment.contentType)
      }
    }
    guard !missingByMXC.isEmpty else { return }
    let client = self.client
    let download: @Sendable (Missing) async -> Void = { missing in
      guard let data = try? await client.downloadMedia(mxcURI: missing.mxc), !data.isEmpty
      else { return }
      _ = MatrixAttachmentStore.store(data: data, forMXC: missing.mxc, contentType: missing.contentType)
    }
    await withTaskGroup(of: Void.self) { group in
      var iterator = missingByMXC.values.makeIterator()
      var inFlight = 0
      while inFlight < 4, let missing = iterator.next() {
        inFlight += 1
        group.addTask { await download(missing) }
      }
      while await group.next() != nil {
        guard let missing = iterator.next() else { continue }
        group.addTask { await download(missing) }
      }
    }
  }

  /// Photo d'un portail (`m.room.avatar`), depuis le cache disque sinon le homeserver.
  /// L'inbox en a besoin pour les fils sans numéro : Instagram et Messenger n'exposent rien d'autre.
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
      // Un agent nommé devant des humains : le message part en **aparté**, un
      // type que les ponts ne relaient pas. Le correspondant ne voit ni la
      // question ni le brouillon qui lui répondra — c'est toute l'idée d'un
      // agent invité dans une conversation qui n'est pas la sienne.
      let apartes = asideAgents(conversationID: conversationID, text: text)
      if !apartes.isEmpty {
        var content: [String: MatrixJSON] = [
          "msgtype": .string("m.text"),
          "body": .string(text),
          AgentWire.AsideKey.agents: .array(apartes.map(MatrixJSON.string)),
        ]
        if let replyToMessageID {
          content["m.relates_to"] = .object(["m.in_reply_to": .object(["event_id": .string(replyToMessageID)])])
        }
        try await client.sendEvent(roomID: roomID, type: AgentWire.asideType, content: .object(content), transactionID: txnID)
        return
      }
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

  /// Les agents présents dans ce fil, par leur nom court — vide hors des fils
  /// bridgés : dans une note à soi ou un fil d'agent, il n'y a pas d'humain
  /// à qui cacher quoi que ce soit, et le message part comme un message.
  public func asideAgents(conversationID: String) -> [String] {
    hydrateIfNeeded()
    guard let model = rooms.values.first(where: { $0.conversationID == conversationID }),
          let network = model.network, network.isMatrixBridged
    else { return [] }
    return model.agentNames(selfUserID: selfUserID)
  }

  /// Les agents **présents** dans un fil du Relais, aparté ou pas : dans la
  /// note à soi et le tête-à-tête d'un agent aussi. C'est ce qui décide que la
  /// carte Assistant, les réactions réservées et Résumer ont leur place —
  /// `asideAgents` ne dit, lui, que si un message doit partir en aparté.
  public func agentsPresent(conversationID: String) -> [String] {
    hydrateIfNeeded()
    guard let roomID = roomID(forConversation: conversationID), let model = rooms[roomID] else { return [] }
    return model.agentNames(selfUserID: selfUserID)
  }

  /// Ceux de ces agents que ce texte nomme : s'il y en a, le message part en aparté.
  public func asideAgents(conversationID: String, text: String) -> [String] {
    AgentWire.agentsMentioned(in: text, among: asideAgents(conversationID: conversationID))
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
  /// WhatsApp comme les ponts Meta n'acceptent **qu'un emoji par personne et par message**
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
  /// Modifier un de mes messages. Refuse là où le pont ne remonte pas le
  /// `m.replace` jusqu'au réseau (cf. `NetworkCapabilities`) : mieux vaut un
  /// geste absent qu'une correction qui n'arrive que chez soi.
  public func editMessage(conversationID: String, messageID: String, newText: String) async throws {
    guard let roomID = roomID(forConversation: conversationID),
          let message = rooms[roomID]?.messagesByID[messageID]
    else { throw MatrixError.decoding("message introuvable") }
    guard message.isFromMe else { throw MatrixError.decoding("on ne modifie que ses propres messages") }
    guard message.network.supportsEditing else {
      throw MatrixError.decoding("\(message.network.labelFR) ne sait pas modifier un message envoyé")
    }
    // Le pont annonce sa fenêtre (`edit_max_age`) et refuse au-delà, sans rien
    // nous dire : ni notice, ni accusé d'échec. Une correction partie trop tard
    // ne reviendrait donc jamais — sauf chez nous, où le `m.replace` s'applique
    // à la réception. On s'arrête avant de créer cet écart.
    guard message.network.acceptsEdit(sentAt: message.sentAt) else {
      throw MatrixError.decoding(
        "Trop tard pour corriger : passé \(message.network.editWindowLabelFR ?? "le délai"), "
          + "\(message.network.labelFR) n’accepte plus de modification"
      )
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
  ///
  /// Relit d'abord le magasin : au lancement, le fil se dessine depuis le disque
  /// avant la première passe `/sync`, et un actor encore vide répondait « pas de
  /// photo » — réponse que le Mac mettait en cache pour toute la session.
  public func memberAvatarData(conversationID: String, userID: String) async -> Data? {
    hydrateIfNeeded()
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
  ///
  /// `sygnalURL` est celle que **le Relais** voit, pas nous : depuis que la
  /// passerelle est publique, c'est une URL HTTPS qu'un Relais de n'importe où
  /// sait joindre. `appID` choisit l'entrée d'`apps:` dans `sygnal.yaml`, donc
  /// l'environnement APNs — c'est l'app qui le décide (`#if DEBUG`), Core ne
  /// fait que le transmettre.
  public func setPusher(
    pushkey: String,
    sygnalURL: URL,
    deviceDisplayName: String,
    appID: String = MatrixClient.iOSPusherAppID
  ) async throws {
    try await client.setPusher(
      pushkey: pushkey,
      sygnalURL: sygnalURL,
      deviceDisplayName: deviceDisplayName,
      appID: appID
    )
  }

  /// Retire le pusher — à la déconnexion, tant que le jeton d'accès vaut encore.
  /// Le même `appID` qu'à la déclaration : un pusher se nomme par le couple
  /// (`app_id`, `pushkey`), et se tromper laisserait le vrai en place.
  public func removePusher(
    pushkey: String,
    appID: String = MatrixClient.iOSPusherAppID
  ) async throws {
    try await client.removePusher(pushkey: pushkey, appID: appID)
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
    /// Le bot attend qu'on lui colle quelque chose (les cookies Instagram, Messenger, X).
    case awaitingCookies(String)
    /// Le bot attend une saisie libre, du flow conversationel de Slack (e-mail,
    /// code reçu par mail, espace de travail, 2FA). `prompt` est ce que le bot
    /// demande, `isSecret` masque le champ (code, mot de passe). `options` liste
    /// les choix quand il y en a (les espaces de travail).
    case awaitingInput(prompt: String, isSecret: Bool, options: [String])
    /// Le bot attend le code PIN à quatre chiffres de X Chat — celui qui
    /// déverrouille les clés des messages privés chiffrés. `isSetup` : le compte
    /// n'en a pas encore, et c'est ici qu'il se crée. `hint` : ce que le pont a
    /// reproché à l'essai précédent (« Invalid passcode. You have 2 guesses
    /// remaining. »), quand il y en a un.
    case awaitingPasscode(isSetup: Bool, hint: String?)
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
    /// Instagram et Messenger : la commande `login` seule, la session récoltée dans
    /// la fenêtre suivra.
    case webSession
  }

  /// Ouvre (ou retrouve) le salon de gestion du pont et envoie la commande de connexion.
  public func startLogin(network: MessageNetwork, input: BridgeLoginInput) async throws {
    let command: String
    switch input {
    case .qrCode: command = "login qr"
    case .phonePairing(let phoneNumber): command = "login phone \(phoneNumber)"
    // On nomme le flow : bridgev2 ne choisit tout seul que si le pont n'en a qu'un,
    // et mautrix-facebook en annonce quatre. Sans le mot, le bot répond « Please
    // specify a login flow » et la fenêtre attendrait une invite qui ne vient pas.
    case .webSession:
      if let flow = network.bridge?.webLoginFlowID {
        command = "login \(flow)"
      } else {
        command = "login"
      }
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

  /// (Re)lance une connexion en nommant explicitement le flow — utilisé pour passer
  /// Slack du flow e-mail au flow `token` quand l'utilisateur ouvre « Coller la session ».
  public func startLoginFlow(_ flow: String, network: MessageNetwork) async throws {
    _ = try? await sendBotCommand("cancel", to: network)
    loginCommandEventIDs[network] = try await sendBotCommand("login \(flow)", to: network)
    loginCommandSentAt[network] = Date()
  }

  /// Envoie une saisie libre au bot pendant un flow conversationnel (l'e-mail, le
  /// code, l'espace de travail de Slack). Même chemin que les cookies : préfixé,
  /// et rédigé aussitôt — un code de connexion n'a rien à laisser dans la timeline.
  public func submitLoginInput(_ text: String, network: MessageNetwork) async throws {
    try await submitLoginCookies(text, network: network)
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
    let trimmed = Self.normalizedCookiePayload(raw)
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

  /// Un collage manuel, nettoyé : les valeurs d'un JSON perdent leurs blancs de
  /// bord. Copier un cookie depuis le tableau des outils de développement de
  /// Brave ou Chrome emporte souvent une espace finale — et X répond alors
  /// « HTTP 401: Could not authenticate you », sans dire pourquoi. Tout ce qui
  /// n'est pas un objet JSON de chaînes (une commande cURL, un PIN) passe tel
  /// quel, seulement débarrassé des blancs autour.
  public static func normalizedCookiePayload(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("{"),
          let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: String]
    else { return trimmed }
    var cleaned: [String: String] = [:]
    for (key, value) in object {
      cleaned[key.trimmingCharacters(in: .whitespacesAndNewlines)] =
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard let data = try? JSONSerialization.data(withJSONObject: cleaned, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8)
    else { return trimmed }
    return text
  }

  /// Envoie au bot le code PIN de X Chat, en réponse à « Please enter your Passcode ».
  ///
  /// Même chemin que les cookies : préfixé, parce que notre DM n'est pas le salon de
  /// gestion aux yeux du bot ; rédigé juste après, parce que bridgev2 ne rédige que
  /// les champs de type mot de passe ou jeton, et qu'un code 2FA n'en est pas un
  /// pour lui — le PIN resterait en clair dans la timeline.
  public func submitLoginPasscode(_ raw: String, network: MessageNetwork) async throws {
    let pin = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard pin.count == 4, pin.allSatisfy(\.isNumber) else {
      throw MatrixError.decoding("le code PIN de X fait quatre chiffres")
    }
    try await submitLoginCookies(pin, network: network)
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
      if network == .slack {
        // Le flow conversationnel : la saisie ou le captcha priment. On saute le
        // bruit (« Login URL: … », l'invite « coller une session ») pour ne pas
        // masquer le message qui compte — le captcha arrive AVANT « Login URL ».
        if let step = Self.slackInputStep(inBotMessage: body) { return step }
        if let step = Self.loginStep(inBotMessage: body) {
          switch step {
          case .success, .failure: return step
          default: continue   // awaitingCookies / login url : on remonte plus loin
          }
        }
        continue
      }
      if let step = Self.loginStep(inBotMessage: body) {
        // Le pont dit d'abord ce qu'il reproche (« Invalid passcode… »), puis
        // redemande (« Please enter your Passcode »). Le plus récent est la
        // demande ; le reproche est le message d'avant, et c'est lui qu'on
        // veut afficher — sans lui, l'utilisateur retaperait le même code.
        if case .awaitingPasscode(let isSetup, nil) = step,
           let previous = Self.passcodeHint(before: event.eventID, in: response.chunk, network: network)
        {
          return .awaitingPasscode(isSetup: isSetup, hint: previous)
        }
        return step
      }
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
      // mautrix-facebook refuse la session incomplète par « Missing cookies: [datr] » :
      // sans ça la feuille attendrait en silence une étape qui ne viendra plus.
      || lower.contains("missing cookies")
      || lower.contains("invalid value for")
      || lower.contains("failed to submit input")
      // Le pont a plusieurs flows et on ne lui en a pas nommé un : la tentative
      // n'a jamais commencé. À dire, plutôt que d'attendre une invite fantôme.
      || lower.contains("please specify a login flow")
    {
      return .failure(body)
    }
    if let code = pairingCode(in: body) { return .pairingCode(code) }
    if let passcode = passcodeStep(inBotMessage: body) { return passcode }
    // Invite de l'étape « session » : l'instruction du connecteur, puis l'URL de
    // login. Meta et X disent « with your cookies », Slack « with your auth token
    // and cookie token » — d'où la forme courte, commune aux deux.
    if lower.contains("enter a json object") || lower.hasPrefix("login url:") {
      return .awaitingCookies(body)
    }
    return nil
  }

  /// Le flow e-mail de Slack, tel que bridgev2 l'écrit dans le salon : une suite
  /// de « Please enter your <champ> », parfois avec « Options: `a`, `b` ». On rend
  /// une saisie libre, en masquant les champs sensibles et en offrant les options
  /// quand il y en a. C'est le chemin « natif » à la Beeper — pas de vue web.
  ///
  /// Le captcha est le seul mur : si le bot le demande, on ne sait pas l'afficher,
  /// et on renvoie un échec qui pointe vers le repli « coller la session ».
  static func slackInputStep(inBotMessage body: String) -> BridgeLoginStep? {
    let lower = body.lowercased()
    if lower.contains("captcha") {
      return .failure("Slack demande un captcha, que la fenêtre ne sait pas afficher. Utilise « Coller la session ».")
    }
    guard let range = body.range(of: "please enter your ", options: [.caseInsensitive]) else { return nil }
    // Le nom du champ, première ligne après « Please enter your ».
    let afterField = body[range.upperBound...]
    let fieldName = afterField.prefix { $0 != "\n" }.trimmingCharacters(in: .whitespaces)
    let lowerField = fieldName.lowercased()
    let isSecret = lowerField.contains("code") || lowerField.contains("password")
      || lowerField.contains("passcode") || lowerField.contains("2fa") || lowerField.contains("token")
    // « Options: `T123`, `T456` » → les choix, entre accents graves.
    var options: [String] = []
    if let optRange = body.range(of: "options:", options: [.caseInsensitive]) {
      let tail = body[optRange.upperBound...]
      options = tail.split(separator: "`").enumerated()
        .filter { $0.offset % 2 == 1 }
        .map { $0.element.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    }
    return .awaitingInput(prompt: body, isSecret: isSecret, options: options)
  }

  /// L'étape PIN de mautrix-twitter, dans les mots de `makePINStep` (pkg/connector/login.go)
  /// et de bridgev2, qui la présente en deux messages : les instructions du connecteur,
  /// puis « Please enter your <champ> ». Le champ s'appelle « Passcode » quand le compte
  /// a déjà un PIN, « Create your PIN code » quand il faut le créer.
  private static func passcodeStep(inBotMessage body: String) -> BridgeLoginStep? {
    let lower = body.lowercased()
    if lower.contains("please enter your create your pin code")
      || lower.contains("no pin code is registered yet")
    {
      return .awaitingPasscode(isSetup: true, hint: nil)
    }
    if lower.contains("invalid passcode") {
      // La première ligne porte le reproche ; le reste est l'instruction répétée.
      let hint = body.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init)
      return .awaitingPasscode(isSetup: false, hint: hint ?? body)
    }
    if lower.contains("please enter your passcode")
      || lower.contains("to retrieve your encrypted messages")
    {
      return .awaitingPasscode(isSetup: false, hint: nil)
    }
    return nil
  }

  /// Le reproche du pont sur le PIN précédent, s'il précède immédiatement `eventID`
  /// dans une page lue du plus récent au plus ancien.
  private static func passcodeHint(
    before eventID: String?,
    in chunk: [MatrixEvent],
    network: MessageNetwork
  ) -> String? {
    guard let index = chunk.firstIndex(where: { $0.eventID == eventID }),
          chunk.indices.contains(index + 1)
    else { return nil }
    let previous = chunk[index + 1]
    guard previous.type == "m.room.message",
          let sender = previous.sender,
          MatrixIdentity.network(ofBot: sender) == network,
          let body = previous.content?.string(at: "body"),
          case .awaitingPasscode(_, let hint) = passcodeStep(inBotMessage: body) ?? .waiting
    else { return nil }
    return hint
  }

  /// Ouvre un fil vers un correspondant via la commande bot `pm` (alias de `start-chat`).
  ///
  /// WhatsApp attend un numéro. Instagram et Messenger attendent l'identifiant
  /// **numérique** Meta :
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
    case .twitter:
      // Le connecteur résout lui-même un pseudo (`ResolveIdentifier` cherche le
      // compte dont le `screen_name` est exactement celui-là) : `pm <pseudo>`,
      // sans arobase, et sans passer par `search` — que ce pont n'expose pas.
      let handle = Self.twitterHandle(identifier)
      guard !handle.isEmpty else { throw MatrixError.decoding("pseudo X vide") }
      _ = try await sendBotCommand(bridge.startChatCommand(identifier: handle), to: network)
    case .slack:
      // Slack résout par e-mail (LookupEmail) ou par recherche : `pm <identifiant>`,
      // le connecteur s'en charge.
      let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { throw MatrixError.decoding("identifiant Slack vide") }
      _ = try await sendBotCommand(bridge.startChatCommand(identifier: trimmed), to: network)
    default:
      let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
      guard !trimmed.isEmpty else {
        throw MatrixError.decoding("identifiant \(network.labelFR) vide")
      }
      let metaID = trimmed.allSatisfy(\.isNumber)
        ? trimmed
        : try await resolveRemoteID(username: trimmed, network: network)
      _ = try await sendBotCommand(bridge.startChatCommand(identifier: metaID), to: network)
    }
  }

  /// Un pseudo X tel que le connecteur le compare : sans arobase ni blancs.
  public static func twitterHandle(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
  }

  /// Ajoute un contact à un groupe : on invite son ghost dans le portail, le pont
  /// fait l'ajout sur le réseau. WhatsApp prend un numéro (`@whatsapp_<num>`),
  /// Instagram et Messenger un pseudo ou un identifiant Meta (`@instagram_<id>`,
  /// `@messenger_<id>`). Signal
  /// n'identifie ses ghosts que par UUID : on ne sait pas les deviner d'un
  /// numéro, et on le dit plutôt que d'inviter dans le vide.
  public func inviteMember(conversationID: String, identifier: String) async throws {
    guard let roomID = roomID(forConversation: conversationID),
          let network = rooms[roomID]?.network,
          let bridge = network.bridge
    else { throw MatrixError.decoding("fil sans pont : impossible d'y ajouter quelqu'un") }
    let ghost = try await ghostUserID(for: identifier, network: network, bridge: bridge)
    try await withRoomPower(roomID: roomID) {
      try await self.client.invite(roomID: roomID, userID: ghost)
    }
  }

  /// Le MXID du fantôme d'un correspondant, à partir de ce qu'on tape.
  ///
  /// WhatsApp prend un numéro, Instagram et Messenger un pseudo (résolu en
  /// identifiant Meta) ou l'identifiant lui-même. Signal n'identifie ses fantômes que par UUID :
  /// on ne sait pas les deviner d'un numéro, et on le dit plutôt que d'inviter
  /// dans le vide.
  private func ghostUserID(
    for identifier: String,
    network: MessageNetwork,
    bridge: MatrixBridgeDescriptor
  ) async throws -> String {
    let serverName = String(selfUserID.split(separator: ":").last ?? "")
    let localpart: String
    switch network {
    case .whatsapp:
      let digits = identifier.filter { $0.isNumber }
      guard digits.count >= 8 else { throw MatrixError.decoding("numéro WhatsApp invalide") }
      localpart = bridge.ghostPrefix + digits
    case .instagram, .messenger:
      let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
      guard !trimmed.isEmpty else { throw MatrixError.decoding("identifiant \(network.labelFR) vide") }
      let metaID = trimmed.allSatisfy(\.isNumber)
        ? trimmed
        : try await resolveRemoteID(username: trimmed, network: network)
      localpart = bridge.ghostPrefix + metaID
    case .twitter:
      // Un ghost X porte l'identifiant numérique du compte ; un pseudo passe par
      // `resolve-identifier`, dont la réponse est formatée comme celle de `search`.
      let handle = Self.twitterHandle(identifier)
      guard !handle.isEmpty else { throw MatrixError.decoding("pseudo X vide") }
      let userID = handle.allSatisfy(\.isNumber)
        ? handle
        : try await resolveRemoteID(username: handle, network: network)
      localpart = bridge.ghostPrefix + userID
    case .slack:
      // Un ghost Slack porte l'identifiant du membre ; un e-mail ou un nom passe
      // par `resolve-identifier`, formaté comme `search`.
      let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { throw MatrixError.decoding("identifiant Slack vide") }
      let userID = trimmed.contains("-") && !trimmed.contains("@")
        ? trimmed
        : try await resolveRemoteID(username: trimmed, network: network)
      localpart = bridge.ghostPrefix + userID
    case .signal:
      let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
      guard trimmed.contains("-"), trimmed.count >= 32 else {
        throw MatrixError.decoding(
          "Signal identifie ses correspondants par UUID, pas par numéro : ouvre d'abord un fil avec la personne."
        )
      }
      localpart = bridge.ghostPrefix + trimmed.lowercased()
    default:
      throw MatrixError.decoding("ajouter quelqu'un n'est pas possible sur \(network.labelFR)")
    }
    return "@\(localpart):\(serverName)"
  }

  // MARK: - Créer un groupe

  /// Crée un groupe sur le réseau, depuis l'app.
  ///
  /// Le chemin est celui de bridgev2, et il n'y en a pas d'autre : on monte un
  /// salon Matrix nommé, on y invite le bot du pont **et** les fantômes des
  /// participants, puis on lui envoie `create-group`. Le pont lit alors le nom
  /// et les membres du salon, crée le groupe distant, et adopte le salon comme
  /// portail. C'est pour cela que le nom se pose à la création du salon et non
  /// après : la commande le lit, elle ne l'attend pas.
  ///
  /// Deux ponts seulement le savent faire (`NetworkCapabilities.createsGroup`) :
  /// mautrix-whatsapp depuis v0.12.5, mautrix-signal depuis v0.8.7. Un pont plus
  /// ancien répondra « unknown command » — on le dit, et on jette le salon
  /// plutôt que de laisser un salon orphelin dans la liste.
  public func createGroup(
    network: MessageNetwork,
    name: String,
    identifiers: [String]
  ) async throws -> String {
    guard network.capabilities.createsGroup, let bridge = network.bridge else {
      throw MatrixError.decoding("\(network.labelFR) ne sait pas créer un groupe depuis l'app")
    }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw MatrixError.decoding("un groupe a besoin d'un nom") }
    // Signal borne le nom à 32 signes ; refuser ici évite un aller-retour et un
    // salon à jeter.
    guard network != .signal || trimmed.count <= 32 else {
      throw MatrixError.decoding("un groupe Signal ne prend pas plus de 32 caractères")
    }
    guard !identifiers.isEmpty else { throw MatrixError.decoding("un groupe a besoin de quelqu'un") }

    var ghosts: [String] = []
    for identifier in identifiers {
      ghosts.append(try await ghostUserID(for: identifier, network: network, bridge: bridge))
    }
    let serverName = String(selfUserID.split(separator: ":").last ?? "")
    let botID = bridge.botUserID(serverName: serverName)
    let roomID = try await client.createGroupRoom(name: trimmed, invite: [botID] + ghosts)

    do {
      try await waitForBotToJoin(roomID: roomID, network: network)
      let commandEventID = try await client.sendText(
        roomID: roomID,
        body: "\(bridge.commandPrefix) create-group",
        transactionID: UUID().uuidString
      )
      try await waitForPortal(roomID: roomID, network: network, after: commandEventID)
    } catch {
      // Un salon qui n'est devenu le portail de rien n'a aucune raison de
      // rester : il paraîtrait dans la liste comme un groupe fantôme.
      try? await client.leave(roomID: roomID)
      rooms.removeValue(forKey: roomID)
      throw error
    }
    return "\(network.rawValue):\(roomID)"
  }

  /// Attend que le pont ait adopté le salon (`m.bridge` posé). S'il répond une
  /// erreur à la place, c'est elle qu'on rapporte — pas un délai qui expire.
  private func waitForPortal(roomID: String, network: MessageNetwork, after commandEventID: String?) async throws {
    for _ in 0..<20 {
      try? await Task.sleep(for: .seconds(1))
      if (try? await client.roomState(roomID: roomID, type: "m.bridge")) != nil { return }
      let response = try await client.roomMessages(roomID: roomID, direction: "b", limit: 10)
      for event in response.chunk {
        if let commandEventID, event.eventID == commandEventID { break }
        guard event.type == "m.room.message",
              let sender = event.sender,
              MatrixIdentity.network(ofBot: sender) == network,
              let body = event.content?.string(at: "body"),
              Self.isBotFailure(body)
        else { continue }
        throw MatrixError.decoding("\(network.labelFR) : \(body)")
      }
    }
    throw MatrixError.decoding("\(network.labelFR) n'a pas créé le groupe — le pont est peut-être trop ancien.")
  }

  /// Le bot annonce ses refus en clair. On ne cherche pas à tout comprendre :
  /// on reconnaît qu'il s'agit d'un refus, et on rend SA phrase.
  static func isBotFailure(_ body: String) -> Bool {
    let folded = body.lowercased()
    return folded.contains("unknown command")
      || folded.contains("failed")
      || folded.contains("error")
      || folded.contains("you must")
      || folded.contains("not logged in")
  }

  /// Renomme un groupe. Le `m.room.name` part sur le Relais ; les ponts qui
  /// savent le faire (WhatsApp, Signal) poussent le nom jusqu'au réseau — c'est
  /// `NetworkCapabilities` qui décide si le geste est seulement proposé.
  public func renameGroup(conversationID: String, name: String) async throws {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw MatrixError.decoding("un groupe ne se nomme pas avec du blanc") }
    guard let roomID = roomID(forConversation: conversationID) else {
      throw MatrixError.decoding("salon introuvable pour \(conversationID)")
    }
    // Un salon sans réseau est la note à soi : un salon à nous, qu'on nomme
    // comme on veut.
    let network = rooms[roomID]?.network ?? .selfNote
    guard network.supportsGroupRename else {
      throw MatrixError.decoding("\(network.labelFR) ne relaie pas le nom d'un groupe")
    }
    try await withRoomPower(roomID: roomID) {
      try await self.client.setRoomName(roomID: roomID, name: trimmed)
    }
  }

  /// Retire quelqu'un d'un groupe. Le `kick` part sur le portail, le pont le
  /// relaie comme un retrait sur le réseau.
  public func removeMember(conversationID: String, userID: String) async throws {
    guard let roomID = roomID(forConversation: conversationID),
          let network = rooms[roomID]?.network
    else { throw MatrixError.decoding("salon introuvable pour \(conversationID)") }
    guard network.supportsMemberRemoval else {
      throw MatrixError.decoding("\(network.labelFR) ne relaie pas le retrait d'un membre")
    }
    guard userID != selfUserID else {
      throw MatrixError.decoding("pour sortir soi-même d'un groupe, il faut le quitter")
    }
    try await withRoomPower(roomID: roomID) {
      try await self.client.kick(roomID: roomID, userID: userID)
    }
  }

  /// Fait un geste qui demande du pouvoir dans le salon, et le refait une fois
  /// après s'être donné ce pouvoir.
  ///
  /// Un portail de pont ne m'accorde parfois rien : le bot y est seul au
  /// pouvoir. Mon compte administre le Relais, donc je peux me hisser (l'API
  /// Synapse s'appuie sur le bot, déjà admin) puis recommencer. C'est le même
  /// chemin que l'invitation de « cc » — extrait ici, parce que trois gestes
  /// s'y heurtent désormais.
  private func withRoomPower(roomID: String, _ action: () async throws -> Void) async throws {
    do {
      try await action()
    } catch MatrixError.http(403, _, _) {
      do {
        try await client.makeRoomAdmin(roomID: roomID, userID: selfUserID)
      } catch MatrixError.administrationIndisponible {
        // Continuwuity n'a aucun équivalent de `make_room_admin` (matrice de la
        // phase 1). On ne plante pas et on ne réessaie pas dans le vide : on dit
        // ce qui manque et par où passer — le bot du pont, lui, sait donner un
        // pouvoir dans son propre portail.
        throw MatrixError.administrationIndisponible(
          "me donner le pouvoir dans ce salon. Le pont y est seul au pouvoir ; "
            + "demande-le-lui dans son salon de gestion (« set-pl <mon identifiant> 100 »)")
      }
      try await action()
    }
  }

  /// `search <pseudo>` puis lecture de la réponse du bot pour en tirer l'ID numérique.
  /// Les ghosts Meta sont des identifiants numériques : `pm <pseudo>` échouerait sec.
  /// L'identifiant numérique d'un compte, à partir de son pseudo, demandé au bot.
  ///
  /// Meta passe par `search <pseudo>` ; mautrix-twitter n'expose pas `search`
  /// (`Search: false` dans ses capacités) mais `resolve-identifier <pseudo>`, qui
  /// répond « Found `id` / Nom » — le même format, lu par la même expression.
  private func resolveRemoteID(username: String, network: MessageNetwork) async throws -> String {
    let command = (network == .twitter || network == .slack) ? "resolve-identifier \(username)" : "search \(username)"
    let commandEventID = try await sendBotCommand(command, to: network)
    let roomID = try await ensureManagementRoom(for: network)
    // Le bot interroge le réseau : quelques secondes au plus, sinon on renonce proprement.
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

  /// « 12 WhatsApp · 3 Instagram · 2 Messenger » — un décompte qui dit de quoi l'inbox est faite.
  public static func bridgedCountFR(_ conversations: [Conversation]) -> String {
    let parts = MessageNetwork.matrixBridged.compactMap { network -> String? in
      let count = conversations.filter { $0.network == network }.count
      return count > 0 ? "\(count) \(network.labelFR)" : nil
    }
    return parts.isEmpty ? "aucune conversation" : parts.joined(separator: " · ")
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
