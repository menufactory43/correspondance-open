import CorrespondanceMatrixClient
import Foundation

/// La boucle de « cc » : un `/sync` sans fin, et pour chaque ordre d'un
/// propriétaire, un tour de Claude dont la réponse revient là où l'ordre a été donné.
public actor Agent {
  public let config: AgentConfig
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
  /// On ne rejoue pas l'historique : seuls les ordres postérieurs comptent —
  /// avec dix minutes de marge pour un ordre donné pendant un redémarrage.
  private let notBefore: Date

  public init(
    config: AgentConfig,
    backend: any AgentBackend,
    stateURL: URL,
    client: MatrixClient? = nil,
    log: @escaping @Sendable (String) -> Void = { print($0) }
  ) {
    self.config = config
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
      await acceptInvites(in: initial)
      state.nextBatch = initial.nextBatch
      try persist()
      log("état initial reçu — \(initial.rooms?.join?.count ?? 0) rooms")
    }
    log("à l'écoute de « \(config.trigger) » pour \(config.owners.joined(separator: ", ")) — plafond \(config.hourlyCap)/h")

    while !Task.isCancelled {
      do {
        let response = try await client.sync(since: state.nextBatch, timeoutMilliseconds: 30_000)
        backoff = 2
        absorbMembers(from: response)
        await acceptInvites(in: response)
        for (roomID, room) in response.rooms?.join ?? [:] {
          for event in room.timeline?.events ?? [] {
            guard event.sender != credentials.userID,
                  let request = Trigger.request(from: event, roomID: roomID, config: config, notBefore: notBefore)
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
      guard let inviter, config.owners.contains(inviter) else {
        log("invitation ignorée dans \(roomID) (par \(inviter ?? "inconnu"))")
        continue
      }
      do {
        _ = try await client.join(roomID: roomID)
        log("rejoint \(roomID) sur invitation de \(inviter)")
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
    let allowed = Set(config.owners + [config.botUserID])
    return (members[roomID] ?? []).isSubset(of: allowed)
  }

  func mode(for roomID: String) async -> AgentConfig.RoomMode {
    if let explicit = config.rooms[roomID]?.mode { return explicit }
    return await isPrivateWithOwners(roomID) ? .direct : config.defaultMode
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
      await reply("Plafond horaire atteint (\(config.hourlyCap) demandes). Réessaie dans \(wait) min.", to: request)
      return
    }
    busyRooms.insert(request.roomID)
    defer { busyRooms.remove(request.roomID) }

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

    do {
      let cwd = config.rooms[request.roomID]?.cwd
      let turn = try await backend.run(prompt: prompt, cwd: cwd, sessionID: state.claudeSessions[request.roomID])
      if let session = turn.sessionID {
        state.claudeSessions[request.roomID] = session
        try? persist()
      }
      let text = turn.text.isEmpty ? "(Claude n'a rien répondu.)" : turn.text
      await reply(text, to: request)
      log("[\(request.roomID)] ← \(text.count) caractères\(turn.isError ? " (erreur)" : "")")
    } catch {
      log("[\(request.roomID)] échec : \(error.localizedDescription)")
      await reply("Je n'ai pas pu répondre : \(error.localizedDescription)", to: request)
    }
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
