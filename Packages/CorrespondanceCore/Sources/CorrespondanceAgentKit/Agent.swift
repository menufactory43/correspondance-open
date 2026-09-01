import CorrespondanceMatrixClient
import Foundation

/// La boucle de « cc » : un `/sync` sans fin, et pour chaque ordre d'un
/// propriétaire, un tour de Claude dont la réponse revient là où l'ordre a été donné.
public actor Agent {
  /// La config du fichier — l'amorce, et le repli tant que le Relais n'a rien dit.
  public let config: AgentConfig
  /// La config vivante : le fichier revu par l'event d'état de la room console.
  /// C'est elle qu'on lit partout ; changer un réglage dans l'app prend effet
  /// au `/sync` suivant, sans SSH ni redémarrage.
  private var live: AgentConfig
  /// La room console de cet agent, découverte par l'event de config qu'elle
  /// porte — l'app n'a pas à nous dire laquelle c'est.
  private var consoleRoomID: String?
  private let client: MatrixClient
  private let backend: any AgentBackend
  private let stateURL: URL
  private var state: AgentState
  private var cap: HourlyCap
  private let log: @Sendable (String) -> Void

  /// Les membres connus de chaque room — pour savoir si on est en tête-à-tête
  /// avec les propriétaires (réponse directe) ou devant des humains (brouillon).
  private var members: [String: Set<String>] = [:]
  /// Une seule demande à la fois par room : la suivante attend son tour.
  private var busyRooms: Set<String> = []
  /// Les demandes de permission posées dans une room, en attente d'un 👍 —
  /// clef : l'event de la question ; valeur : où écrire la décision.
  private var pendingPermissions: [String: PendingPermission] = [:]

  struct PendingPermission {
    var spool: URL
    var requestID: String
    var roomID: String
    var toolName: String
  }
  /// Le mode par défaut que l'app a écrit dans l'account data globale
  /// (`fr.correspondance.agent.settings`). `nil` tant qu'elle n'a rien dit :
  /// c'est alors la config qui décide. Cf. `AgentMode`.
  private var accountDefaultMode: AgentConfig.RoomMode?
  /// On ne rejoue pas l'historique : seuls les ordres postérieurs comptent —
  /// avec dix minutes de marge pour un ordre donné pendant un redémarrage.
  private let notBefore: Date
  /// Depuis quand ce processus tourne — le status le dit, pour qu'on sache
  /// *où* et *depuis quand* sans ouvrir un terminal.
  private let startedAt = Date()
  /// La ligne de status, scannée une fois : elle est reposée à chaque arrivée
  /// dans une room, et rescanner à chaque fois coûterait un `--version` par moteur.
  private var statusLine: String?

  public init(
    config: AgentConfig,
    backend: any AgentBackend,
    stateURL: URL,
    client: MatrixClient? = nil,
    log: @escaping @Sendable (String) -> Void = { print($0) }
  ) {
    self.config = config
    self.live = config
    self.backend = backend
    self.stateURL = stateURL
    self.state = AgentState.load(from: stateURL)
    self.client = client ?? MatrixClient(credentials: nil)
    self.cap = HourlyCap(limit: config.hourlyCap)
    self.log = log
    self.notBefore = Date().addingTimeInterval(-600)
  }

  // MARK: - Session

  public func ensureLoggedIn() async throws -> MatrixCredentials {
    if let credentials = state.credentials, credentials.homeserver == config.homeserver {
      await client.setCredentials(credentials)
      do {
        _ = try await client.whoami()
        return credentials
      } catch {
        log("session Matrix périmée (\(error.localizedDescription)) — reconnexion")
      }
    }
    let credentials = try await client.login(homeserver: config.homeserver, user: config.user, password: config.password)
    state.credentials = credentials
    try persist()
    log("connecté comme \(credentials.userID)")
    return credentials
  }

  /// Les rooms où le bot est, avec leur nom — pour remplir `rooms` dans la config.
  public func listRooms() async throws -> [(roomID: String, name: String)] {
    _ = try await ensureLoggedIn()
    var result: [(String, String)] = []
    for roomID in try await client.joinedRooms() {
      let name = (try? await client.roomState(roomID: roomID, type: "m.room.name"))?.string(at: "name") ?? "(sans nom)"
      result.append((roomID, name))
    }
    return result
  }

  // MARK: - Boucle

  public func run() async throws {
    let credentials = try await ensureLoggedIn()
    var backoff: TimeInterval = 2
    if state.nextBatch == nil {
      // Premier lancement : on prend l'état, on note où on en est, on ne
      // relit pas les timelines — l'agent ne répond qu'à ce qui vient.
      let initial = try await client.sync(since: nil, timeoutMilliseconds: 0)
      absorbMembers(from: initial)
      absorbRemoteConfig(from: initial)
      absorbSettings(from: initial)
      await acceptInvites(in: initial)
      state.nextBatch = initial.nextBatch
      try persist()
      log("état initial reçu — \(initial.rooms?.join?.count ?? 0) rooms")
    }
    log("à l'écoute de « \(live.trigger) » pour \(live.owners.joined(separator: ", ")) — plafond \(live.hourlyCap)/h")

    // La machine des moteurs, c'est celle-ci : on scanne, et on le dit dans
    // les rooms en tête-à-tête (la note à soi en tête) — l'app le lit dans les
    // réglages, sans SSH. La présence Matrix est éteinte sur le Relais, exprès.
    Task { await self.publishStatus() }

    while !Task.isCancelled {
      do {
        let response = try await client.sync(since: state.nextBatch, timeoutMilliseconds: 30_000)
        backoff = 2
        absorbMembers(from: response)
        absorbRemoteConfig(from: response)
        absorbSettings(from: response)
        await acceptInvites(in: response)
        for (roomID, room) in response.rooms?.join ?? [:] {
          for event in room.timeline?.events ?? [] {
            guard event.sender != credentials.userID else { continue }
            if resolvePermission(from: event) { continue }
            guard let request = Trigger.request(from: event, roomID: roomID, config: live, notBefore: notBefore)
            else { continue }
            dispatch(request)
          }
        }
        state.nextBatch = response.nextBatch
        try persist()
      } catch {
        log("sync en échec : \(error.localizedDescription) — nouvel essai dans \(Int(backoff)) s")
        try? await Task.sleep(for: .seconds(backoff))
        backoff = min(backoff * 2, 60)
      }
    }
  }

  // MARK: - Invitations

  /// On rejoint ce qu'un propriétaire nous ouvre, et rien d'autre.
  private func acceptInvites(in response: MatrixSyncResponse) async {
    for (roomID, invite) in response.rooms?.invite ?? [:] {
      let events = invite.value(at: "invite_state.events")?.arrayValue ?? []
      let inviter = events.first { event in
        event.string(at: "type") == "m.room.member"
          && event.string(at: "state_key") == config.botUserID
          && event.string(at: "content.membership") == "invite"
      }?.string(at: "sender")
      guard let inviter, live.owners.contains(inviter) else {
        log("invitation ignorée dans \(roomID) (par \(inviter ?? "inconnu"))")
        continue
      }
      do {
        _ = try await client.join(roomID: roomID)
        log("rejoint \(roomID) sur invitation de \(inviter)")
        // Un status à l'arrivée : sans ça, un bot invité après le démarrage
        // reste muet dans les réglages jusqu'au prochain redémarrage.
        members[roomID] = nil
        await publishStatus(in: [roomID])
      } catch {
        log("impossible de rejoindre \(roomID) : \(error.localizedDescription)")
      }
    }
  }

  private func absorbMembers(from response: MatrixSyncResponse) {
    for (roomID, room) in response.rooms?.join ?? [:] {
      for event in (room.state?.events ?? []) + (room.timeline?.events ?? []) where event.type == "m.room.member" {
        guard let user = event.stateKey else { continue }
        var set = members[roomID] ?? []
        // Un invité compte comme présent : il lira le fil dès qu'il entrera.
        // Ne pas le compter ferait répondre l'agent en clair dans une room
        // qu'on vient d'ouvrir à un humain.
        let membership = event.content?.string(at: "membership")
        if membership == "join" || membership == "invite" { set.insert(user) } else { set.remove(user) }
        members[roomID] = set
      }
    }
  }

  /// Tête-à-tête : personne dans la room hors les propriétaires et le bot.
  private func isPrivateWithOwners(_ roomID: String) async -> Bool {
    if members[roomID] == nil, let events = try? await client.roomStateEvents(roomID: roomID) {
      var set: Set<String> = []
      for event in events where event.type == "m.room.member" {
        let membership = event.content?.string(at: "membership")
        if membership == "join" || membership == "invite", let user = event.stateKey { set.insert(user) }
      }
      members[roomID] = set
    }
    let allowed = Set(live.owners + [live.botUserID])
    return (members[roomID] ?? []).isSubset(of: allowed)
  }

  /// La config que l'app a écrite dans la room console, quand ce `/sync` la
  /// porte. Le fichier de l'hôte reste le repli : un event minuscule ne
  /// remplace pas une config, il la corrige champ par champ.
  private func absorbRemoteConfig(from response: MatrixSyncResponse) {
    for (roomID, room) in response.rooms?.join ?? [:] {
      let events = (room.state?.events ?? []) + (room.timeline?.events ?? [])
      for event in events where event.type == AgentEvents.configType {
        guard let content = event.content, let remote = AgentRemoteConfig(content: content) else { continue }
        guard remote.agent == config.user else { continue }
        guard remote.isReadable else {
          log("config v\(remote.version) reçue dans \(roomID) — trop récente pour moi (v\(AgentRemoteConfig.currentVersion)), je garde la mienne")
          continue
        }
        guard let sender = event.sender, config.owners.contains(sender) else {
          // Une config écrite par quelqu'un d'autre qu'un propriétaire : jamais.
          // C'est ce qui empêche un tiers dans une room de reconfigurer l'agent.
          //
          // On lit les propriétaires du **fichier**, pas ceux du Relais : qui a
          // le droit de reconfigurer est ancré dans l'amorce, sur l'hôte. Un
          // event peut élargir qui *déclenche* l'agent, jamais qui le *règle*.
          log("config ignorée dans \(roomID) : écrite par \(event.sender ?? "inconnu")")
          continue
        }
        consoleRoomID = roomID
        let updated = config.applying(remote)
        if updated != live {
          live = updated
          cap = HourlyCap(limit: updated.hourlyCap)
          log("config reçue du Relais (\(roomID)) : déclencheur « \(updated.trigger) », moteur \(updated.backend.rawValue), palier \(AgentConfig.Presets.name(of: updated.claude.allowedTools)), plafond \(updated.hourlyCap)/h")
        }
      }
    }
  }

  /// Le réglage que l'app a écrit, quand ce `/sync` en parle. Un `/sync` qui
  /// n'en parle pas ne l'efface pas — le serveur ne renvoie que ce qui change.
  private func absorbSettings(from response: MatrixSyncResponse) {
    guard let mode = AgentMode.defaultMode(in: response) else { return }
    if mode != accountDefaultMode {
      log("réglage reçu : réponses par défaut en « \(mode.rawValue) »")
    }
    accountDefaultMode = mode
  }

  func mode(for roomID: String) async -> AgentConfig.RoomMode {
    await AgentMode.resolve(
      roomMode: live.rooms[roomID]?.mode,
      isPrivateWithOwners: isPrivateWithOwners(roomID),
      accountDataDefault: accountDefaultMode,
      configuredDefault: live.defaultMode
    )
  }

  // MARK: - Un tour

  private func dispatch(_ request: AgentRequest) {
    Task { await self.handle(request) }
  }

  private func handle(_ request: AgentRequest) async {
    guard !busyRooms.contains(request.roomID) else {
      await reply("Je suis encore sur ta demande précédente ici — une à la fois.", to: request)
      return
    }
    guard cap.admit() else {
      let wait = Int((cap.nextSlot() ?? 0) / 60) + 1
      await reply("Plafond horaire atteint (\(live.hourlyCap) demandes). Réessaie dans \(wait) min.", to: request)
      return
    }
    busyRooms.insert(request.roomID)
    defer { busyRooms.remove(request.roomID) }

    let startedTurn = Date()
    let prompt = request.prompt.isEmpty ? "Le propriétaire t'a appelé sans rien demander. Demande-lui ce qu'il veut, en une phrase." : request.prompt
    log("[\(request.roomID)] \(request.sender) → « \(prompt.prefix(80)) »")

    let typing = Task { [client] in
      while !Task.isCancelled {
        try? await client.sendTyping(roomID: request.roomID, isTyping: true, timeoutMilliseconds: 25_000)
        try? await Task.sleep(for: .seconds(20))
      }
    }
    defer {
      typing.cancel()
      Task { [client] in try? await client.sendTyping(roomID: request.roomID, isTyping: false) }
    }

    // Le spool du tour : `claude` y dépose ses demandes d'outils, le guetteur
    // les porte dans la room, un 👍 y répond. Sans permission activée : rien.
    var spool: URL?
    var watcher: Task<Void, Never>?
    if live.claude.permission.enabled {
      let dir = stateURL.deletingLastPathComponent().appending(path: "permissions/\(UUID().uuidString)")
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
      spool = dir
      watcher = Task { await self.watchPermissionRequests(in: dir, for: request) }
    }
    defer {
      watcher?.cancel()
      if let spool {
        pendingPermissions = pendingPermissions.filter { $0.value.spool != spool }
        try? FileManager.default.removeItem(at: spool)
      }
    }

    do {
      // Jamais `~` : un tour travaille dans le dossier de sa room tant qu'aucun
      // dépôt n'est lié. C'est le rayon d'explosion, et c'est le garde-fou qui
      // remplace la question qu'on ne pose plus.
      let cwd = Workspace.prepare(
        Workspace.directory(agent: live.user, roomID: request.roomID, binding: live.rooms[request.roomID]?.cwd)
      )
      let turn = try await backend.run(prompt: prompt, cwd: cwd, sessionID: state.claudeSessions[request.roomID], permissionSpool: spool)
      if let session = turn.sessionID {
        state.claudeSessions[request.roomID] = session
        try? persist()
      }
      let text = turn.text.isEmpty ? "(Claude n'a rien répondu.)" : turn.text
      await reply(text, to: request)
      log("[\(request.roomID)] ← \(text.count) caractères\(turn.isError ? " (erreur)" : "")")
      await journal(request, seconds: Date().timeIntervalSince(startedTurn), tools: turn.tools, tokens: turn.tokens)
    } catch {
      log("[\(request.roomID)] échec : \(error.localizedDescription)")
      await reply("Je n'ai pas pu répondre : \(error.localizedDescription)", to: request)
    }
  }

  // MARK: - Journal

  /// Chaque tour laisse une trace dans la room console : qui a demandé, quoi,
  /// quels outils ont servi, combien de temps. Depuis qu'on donne la pleine
  /// permission, c'est ce qui rend l'agent relisible — et c'est le troisième
  /// garde-fou avec le dossier borné et les propriétaires seuls.
  ///
  /// Rien n'est posté s'il n'y a pas de room console : on n'invente pas un
  /// endroit où déverser ce que les gens se disent.
  private func journal(_ request: AgentRequest, seconds: Double, tools: [String], tokens: Int?) async {
    guard let consoleRoomID else { return }
    do {
      try await client.sendEvent(
        roomID: consoleRoomID,
        type: AgentEvents.journalType,
        content: AgentEvents.journal(
          agent: live.user, roomID: request.roomID, sender: request.sender,
          prompt: request.prompt, tools: tools, seconds: seconds, tokens: tokens
        )
      )
    } catch {
      log("journal impostable : \(error.localizedDescription)")
    }
  }

  // MARK: - Status

  /// Scanne les moteurs et poste `fr.correspondance.agent.status` dans chaque
  /// room en tête-à-tête avec les propriétaires. Les ponts ignorent ce type,
  /// et on ne le poste de toute façon jamais devant des tiers.
  private func publishStatus(in rooms: [String]? = nil) async {
    let config = self.live
    if statusLine == nil {
      let scan = await Task.detached { EngineScan.scan(config: config) }.value
      statusLine = scan.statusLine(
        backend: config.backend, agent: config.user, host: EngineScan.hostName, since: startedAt
      )
      log("moteurs : \(statusLine ?? "")")
    }
    guard let line = statusLine else { return }
    let targets: [String]
    if let rooms {
      targets = rooms
    } else {
      guard let joined = try? await client.joinedRooms() else { return }
      targets = joined
    }
    for roomID in targets {
      guard await isPrivateWithOwners(roomID) else { continue }
      do {
        try await client.sendEvent(
          roomID: roomID,
          type: AgentEvents.statusType,
          content: AgentEvents.status(body: line, agent: config.user)
        )
      } catch {
        log("[\(roomID)] status impostable : \(error.localizedDescription)")
      }
    }
  }

  // MARK: - Permissions

  /// Guette le spool tant que le tour dure : chaque demande de `claude`
  /// devient une question dans la room où l'ordre a été donné.
  private func watchPermissionRequests(in spool: URL, for request: AgentRequest) async {
    var asked: Set<String> = []
    while !Task.isCancelled {
      for pending in Permission.pendingRequests(in: spool) where !asked.contains(pending.id) {
        asked.insert(pending.id)
        await askPermission(pending, in: spool, for: request)
      }
      try? await Task.sleep(for: .milliseconds(500))
    }
  }

  /// Pose la question. En tête-à-tête : un message ordinaire, lisible partout
  /// (Correspondance, Element, le téléphone). Devant des tiers ou un pont : un
  /// event `fr.correspondance.agent.permission`, que les ponts ne relaient pas
  /// — la demande ne part jamais vers le réseau.
  private func askPermission(_ pending: Permission.Request, in spool: URL, for request: AgentRequest) async {
    let body = "🔐 cc veut utiliser \(pending.toolName) : \(pending.summary)\n👍 pour autoriser, 👎 pour refuser."
    do {
      let eventID: String?
      if await isPrivateWithOwners(request.roomID) {
        eventID = try await client.sendText(roomID: request.roomID, body: body, replyToEventID: request.eventID)
      } else {
        eventID = try await client.sendEvent(
          roomID: request.roomID,
          type: AgentEvents.permissionType,
          content: AgentEvents.permission(body: body, tool: pending.toolName, agent: config.user, inReplyTo: request.eventID)
        )
      }
      guard let eventID else { return }
      pendingPermissions[eventID] = PendingPermission(
        spool: spool, requestID: pending.id, roomID: request.roomID, toolName: pending.toolName
      )
      log("[\(request.roomID)] permission demandée : \(pending.toolName)")
    } catch {
      log("[\(request.roomID)] demande de permission impossible : \(error.localizedDescription)")
      try? Permission.write(.init(allow: false, message: "la question n'a pas pu être posée"), in: spool, id: pending.id)
    }
  }

  /// Un 👍 (ou 👎) d'un propriétaire sur une question en attente la tranche.
  /// Tout autre event ressort sans effet. `👍🏻` et ses variantes comptent :
  /// le scalaire de tête suffit.
  private func resolvePermission(from event: MatrixEvent) -> Bool {
    guard event.type == "m.reaction",
          let target = event.content?.string(at: "m.relates_to.event_id"),
          let pending = pendingPermissions[target]
    else { return false }
    guard let sender = event.sender, live.owners.contains(sender),
          let key = event.content?.string(at: "m.relates_to.key")
    else { return true } // la question est à nous, mais pas la réaction : on l'ignore
    let allow: Bool
    if key.hasPrefix("👍") { allow = true } else if key.hasPrefix("👎") { allow = false } else { return true }
    pendingPermissions.removeValue(forKey: target)
    do {
      try Permission.write(
        .init(allow: allow, message: allow ? nil : "refusé par \(sender) depuis la conversation"),
        in: pending.spool, id: pending.requestID
      )
      log("[\(pending.roomID)] \(pending.toolName) : \(allow ? "autorisé" : "refusé") par \(sender)")
    } catch {
      log("[\(pending.roomID)] décision inécrivable : \(error.localizedDescription)")
    }
    return true
  }

  /// La réponse va là où l'ordre a été donné, dans la forme que la room impose.
  private func reply(_ text: String, to request: AgentRequest) async {
    let mode = await mode(for: request.roomID)
    do {
      switch mode {
      case .direct:
        // Pas de préfixe : côté Relais l'expéditeur est déjà « cc », et sur un
        // portail en relais c'est le pont qui signe (`message_formats`) — en
        // préfixer un ici doublerait la signature chez le correspondant.
        try await client.sendText(roomID: request.roomID, body: text, replyToEventID: request.eventID)
      case .draft:
        try await client.sendEvent(
          roomID: request.roomID,
          type: AgentEvents.proposalType,
          content: AgentEvents.proposal(text: text, agent: config.user, inReplyTo: request.eventID)
        )
      }
    } catch {
      log("[\(request.roomID)] envoi impossible : \(error.localizedDescription)")
    }
  }

  private func persist() throws {
    try state.write(to: stateURL)
  }
}
