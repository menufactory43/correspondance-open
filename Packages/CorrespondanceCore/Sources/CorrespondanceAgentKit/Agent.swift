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
  /// Les salons que l'app a marqués tête-à-tête (`kind: agent`) : on y répond
  /// à tout message d'un propriétaire, sans mention.
  private var teteATeteRooms: Set<String> = []
  /// L'agent à qui est chaque tête-à-tête (`AgentWire.ConversationKey.agent`,
  /// sinon le nom du salon, que l'app pose au nom de l'agent). Quand un second
  /// agent y est invité, c'est l'hôte qui répond à ce qui ne nomme personne.
  private var teteATeteHosts: [String: String] = [:]
  /// Le nom des salons, pour reconnaître l'hôte d'un fil d'avant le champ `agent`.
  private var roomNames: [String: String] = [:]
  private let client: MatrixClient
  private let backend: any AgentBackend
  private let stateURL: URL
  private var state: AgentState
  private var cap: HourlyCap
  private let log: @Sendable (String) -> Void
  /// De quoi brancher une machine crypto après la connexion. `nil` — le défaut,
  /// et le seul cas possible sous Linux tant que la bibliothèque Rust n'y est
  /// pas construite — laisse l'agent exactement comme avant.
  private let chiffrement: AgentBranchementChiffrement?
  /// Les salons où un message est resté illisible, et depuis combien de
  /// messages. Un agent qui se tait est indiscernable d'un agent occupé : ce
  /// compteur existe pour que le journal le dise.
  private var illisibles: [String: Int] = [:]

  /// Les membres connus de chaque room — pour savoir si on est en tête-à-tête
  /// avec les propriétaires (réponse directe) ou devant des humains (brouillon).
  private var members: [String: Set<String>] = [:]
  /// Une seule demande à la fois par room : la suivante attend son tour.
  private var busyRooms: Set<String> = []
  /// Ce qui est arrivé pendant qu'un tour était en vol. À la fin du tour, tout
  /// ce qui attend part **ensemble** — comme `buzz-acp`. On ne poste jamais de
  /// bulle pour dire qu'on attend : ça remplirait la file au lieu de la vider,
  /// et ça perdait la demande.
  private var enAttente: [String: [AgentRequest]] = [:]
  /// Les tours consommés par atelier dans l'heure — un budget de salon, en plus
  /// du plafond de l'agent : deux agents qui se répondent brûleraient une
  /// fenêtre d'abonnement en une nuit.
  private var atelierBudgets: [String: HourlyCap] = [:]
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
  /// Le dernier scan des moteurs, gardé sous la main : un `--version` par
  /// moteur à chaque tour coûterait plus cher que le tour lui-même. Refait
  /// quand le moteur configuré change — c'est le seul cas où la réponse peut
  /// changer sans qu'on redémarre.
  private var dernierScan: (engine: String?, scan: EngineScan)?
  /// Pourquoi le journal ne peut pas s'exercer, quand c'est le cas. Le status
  /// le porte : sans ça, un garde-fou absent resterait invisible pour l'app.
  private var journalIndisponible: String?

  public init(
    config: AgentConfig,
    backend: any AgentBackend,
    stateURL: URL,
    client: MatrixClient? = nil,
    chiffrement: AgentBranchementChiffrement? = nil,
    log: @escaping @Sendable (String) -> Void = { print($0) }
  ) {
    self.config = config
    self.live = config
    self.backend = backend
    self.stateURL = stateURL
    self.state = AgentState.load(from: stateURL)
    self.client = client ?? MatrixClient(credentials: nil)
    self.cap = HourlyCap(limit: config.hourlyCap)
    self.chiffrement = chiffrement
    self.log = log
    self.notBefore = Date().addingTimeInterval(-600)
  }

  // MARK: - Session

  public func ensureLoggedIn() async throws -> MatrixCredentials {
    if let credentials = state.credentials, credentials.homeserver == config.homeserver {
      await client.setCredentials(credentials)
      do {
        _ = try await client.whoami()
        // Une session reprise porte le nom d'hier : on le remet, pour que
        // l'app sache d'où cet agent parle.
        try? await client.renameCurrentDevice(MatrixClient.agentDeviceDisplayName(host: AgentWire.hostName))
        return credentials
      } catch {
        log("session Matrix périmée (\(error.localizedDescription)) — reconnexion")
      }
    }
    // La session porte le nom de la machine : c'est ce que l'app lit pour
    // refuser d'activer un second agent quand celui-ci vit ailleurs.
    MatrixClient.deviceDisplayName = MatrixClient.agentDeviceDisplayName(host: AgentWire.hostName)
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

  /// Un autre agent tourne-t-il déjà sur ce compte ? On regarde le status le
  /// plus récent qu'on ait posté — l'event porte la machine et le pid.
  ///
  /// Deux agents sur le même compte, ce sont deux réponses à chaque message.
  /// L'app refuse déjà d'activer un second hôte ; le faire **aussi** ici couvre
  /// le cas où les deux lanceurs ne se connaissent pas (un `systemctl start`
  /// sur le NUC ne sait rien d'un clic sur le Mac).
  private func verifyOnlyInstance() async throws {
    let moi = SingleInstance.Sighting(
      host: AgentWire.hostName, pid: ProcessInfo.processInfo.processIdentifier, at: Date()
    )
    var dernier: SingleInstance.Sighting?
    guard let joined = try? await client.joinedRooms() else {
      // On n'a pas pu vérifier : on démarre quand même (mieux vaut un agent
      // qu'aucun), mais on le dit — c'est une protection qui n'a pas pu jouer.
      log("⚠ impossible de vérifier qu'aucun autre agent ne tourne : le Relais n'a pas répondu")
      return
    }
    for roomID in joined {
      guard let messages = try? await client.roomMessages(roomID: roomID, limit: 30) else { continue }
      for event in messages.chunk
      where event.type == AgentEvents.statusType && event.sender == config.botUserID {
        guard let vu = AgentEvents.sighting(in: event.content ?? .object([:]), at: event.sentAt) else {
          continue
        }
        if dernier == nil || vu.at > dernier!.at { dernier = vu }
      }
    }
    if case .refuse(let raison) = SingleInstance.verdict(sighting: dernier, moi: moi) {
      log("démarrage refusé : \(raison)")
      throw AgentError.dejaEnCours(raison)
    }
  }

  /// Trouve la room console en **interrogeant l'état des rooms**, sans
  /// dépendre du `/sync`.
  ///
  /// C'est le correctif d'un bug qui a rendu le journal muet : la découverte ne
  /// passait que par `absorbRemoteConfig`, donc par un event d'état — or Matrix
  /// n'envoie l'état complet qu'au **premier** `/sync`. Dès que `state.json`
  /// existait (c'est-à-dire à tous les redémarrages), les syncs étaient
  /// incrémentaux, la config n'était jamais revue, et `consoleRoomID` restait
  /// `nil` pour toujours. Le status, lui, parcourait les rooms directement :
  /// d'où un agent qui s'annonçait dans sa console mais n'y journalisait rien.
  private func discoverConsole() async {
    guard let joined = try? await client.joinedRooms() else {
      log("⚠ \(AgentJournal.sansConsole) (le Relais n'a pas répondu à la recherche)")
      journalIndisponible = AgentJournal.sansConsole
      return
    }
    var console: String?
    for roomID in joined {
      // Le marqueur de fil et le nom du salon, **relus à chaque démarrage** :
      // même correctif que pour la console. Avec un `state.json`, les syncs
      // sont incrémentaux, l'état ne repasse jamais, et un agent redémarré
      // exigeait « @claude » dans son propre fil — c'est ce qu'on a vu.
      if let marqueur = try? await client.roomState(roomID: roomID, type: AgentWire.conversationType) {
        noteRoomKind(roomID, content: marqueur)
      }
      if let nom = (try? await client.roomState(roomID: roomID, type: "m.room.name"))?.string(at: "name") {
        roomNames[roomID] = nom
      }
      guard console == nil,
            let content = try? await client.roomState(roomID: roomID, type: AgentEvents.configType),
            let remote = AgentRemoteConfig(content: content),
            remote.agent == config.user, remote.isReadable
      else { continue }
      console = roomID
      consoleRoomID = roomID
      live = config.applying(remote)
      cap = HourlyCap(limit: live.hourlyCap)
      log("console trouvée : \(roomID)")
    }
    if console == nil {
      // Un garde-fou qui ne peut pas s'exercer doit le dire — ici, et dans le
      // status que l'app affiche.
      log("⚠ \(AgentJournal.sansConsole)")
    }
  }

  public func run() async throws {
    let credentials = try await ensureLoggedIn()
    // Le chiffrement se branche **avant** le premier `/sync` : c'est ce sync-là
    // qui publie les clés d'appareil (`keys/upload`). Branché après, l'agent
    // resterait invisible pour les autres appareils jusqu'au tour suivant, et
    // personne ne lui porterait la clé du salon.
    if let chiffrement, let ligne = await chiffrement(credentials, client) { log(ligne) }
    try await verifyOnlyInstance()
    await discoverConsole()
    var backoff: TimeInterval = 2
    if state.nextBatch == nil {
      // Premier lancement : on prend l'état, on note où on en est, on ne
      // relit pas les timelines — l'agent ne répond qu'à ce qui vient.
      let initial = try await client.sync(since: nil, timeoutMilliseconds: 0)
      absorbMembers(from: initial)
      absorbRoomKinds(from: initial)
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
        absorbRoomKinds(from: response)
        absorbRemoteConfig(from: response)
        absorbSettings(from: response)
        await absorbCommands(from: response)
        await acceptInvites(in: response)
        for (roomID, room) in response.rooms?.join ?? [:] {
          signalerLesIllisibles(roomID: roomID, room: room, moi: credentials.userID)
          for event in room.timeline?.events ?? [] {
            guard event.sender != credentials.userID else { continue }
            if resolvePermission(from: event) { continue }
            if isAtelier(roomID) {
              if let request = atelierRequest(from: event, roomID: roomID) { dispatch(request) }
              continue
            }
            guard let request = Trigger.request(
              from: event, roomID: roomID, config: live, notBefore: notBefore,
              requiresTrigger: requiresTrigger(in: roomID)
            ) else { continue }
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

  /// Un `m.room.encrypted` qui traverse le `/sync` sans avoir été déchiffré,
  /// c'est un ordre qu'on n'entendra jamais. **Un agent qui se tait est
  /// indiscernable d'un agent occupé** : mesuré en phase 4, où cc n'a pas
  /// journalisé une ligne devant une note à soi chiffrée. On le dit donc, une
  /// fois par salon et par vague — pas à chaque tour, sinon le journal se
  /// remplit de la même phrase toutes les trente secondes.
  func signalerLesIllisibles(roomID: String, room: MatrixSyncResponse.JoinedRoom, moi: String) {
    let restes = (room.timeline?.events ?? []).filter {
      $0.type == "m.room.encrypted" && $0.sender != moi
    }
    guard !restes.isEmpty else { illisibles[roomID] = 0; return }
    let deja = illisibles[roomID] ?? 0
    illisibles[roomID] = deja + restes.count
    if deja == 0 {
      log(
        "⚠ \(roomID) : \(restes.count) message(s) chiffré(s) que je ne sais pas lire"
          + " — clé de salon pas encore reçue, ou pas de machine crypto dans ce binaire")
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
        // Le marqueur du salon, lu **directement** : un `/sync` incrémental ne
        // porte pas toujours l'état complet d'un salon qu'on vient de rejoindre,
        // et un fil d'agent où l'on exige la mention est un fil muet.
        if let marqueur = try? await client.roomState(roomID: roomID, type: AgentWire.conversationType) {
          noteRoomKind(roomID, content: marqueur)
        }
        if let nom = (try? await client.roomState(roomID: roomID, type: "m.room.name"))?.string(at: "name") {
          roomNames[roomID] = nom
        }
        // Un status à l'arrivée : sans ça, un bot invité après le démarrage
        // reste muet dans les réglages jusqu'au prochain redémarrage.
        members[roomID] = nil
        await publishStatus(in: [roomID])
      } catch {
        log("impossible de rejoindre \(roomID) : \(error.localizedDescription)")
      }
    }
  }

  /// Le marqueur de l'app sur un salon natif : c'est un event d'état, il
  /// arrive avec le premier `/sync` qui porte le salon.
  private func absorbRoomKinds(from response: MatrixSyncResponse) {
    for (roomID, room) in response.rooms?.join ?? [:] {
      for event in (room.state?.events ?? []) + (room.timeline?.events ?? []) {
        if event.type == "m.room.name", let name = event.content?.string(at: "name") {
          roomNames[roomID] = name
        }
        if event.type == AgentWire.conversationType { noteRoomKind(roomID, content: event.content) }
      }
    }
  }

  /// Le marqueur d'un salon, d'où qu'il vienne — le `/sync`, ou une lecture
  /// directe de l'état à l'arrivée. `kind: agent` fait du salon un
  /// tête-à-tête ; le champ `agent` dit à qui il est.
  private func noteRoomKind(_ roomID: String, content: MatrixJSON?) {
    let kind = content?.string(at: AgentWire.ConversationKey.kind)
    guard kind == AgentWire.ConversationKind.agent else {
      teteATeteRooms.remove(roomID)
      teteATeteHosts[roomID] = nil
      return
    }
    if let hote = content?.string(at: AgentWire.ConversationKey.agent), !hote.isEmpty {
      teteATeteHosts[roomID] = mxid(ofAgentNamed: hote)
    }
    if teteATeteRooms.insert(roomID).inserted { log("[\(roomID)] tête-à-tête : je réponds sans mention") }
  }

  /// Le MXID d'un agent nommé par son nom court, sur mon Relais.
  private func mxid(ofAgentNamed name: String) -> String {
    if name.hasPrefix("@"), name.contains(":") { return name }
    let serveur = live.botUserID.split(separator: ":").dropFirst().joined(separator: ":")
    return "@\(name):\(serveur)"
  }

  /// L'agent à qui est ce fil : le champ `agent` du marqueur, sinon le nom du
  /// salon — l'app le pose au nom de l'agent à la création. `nil` : un salon
  /// qui n'est pas un tête-à-tête, ou dont on ne sait pas l'hôte.
  private func host(of roomID: String) -> String? {
    guard teteATeteRooms.contains(roomID) else { return nil }
    if let hote = teteATeteHosts[roomID] { return hote }
    guard let nom = roomNames[roomID]?.trimmingCharacters(in: .whitespacesAndNewlines), !nom.isEmpty else { return nil }
    let candidat = mxid(ofAgentNamed: nom.lowercased())
    return agents(in: roomID).contains(candidat) ? candidat : nil
  }

  /// Les agents présents dans ce salon, moi compris : les pairs déclarés
  /// (`peers`) qui en sont membres, et, dans un tête-à-tête marqué par l'app,
  /// **tout membre qui n'est pas un propriétaire** — l'app n'y invite que des
  /// agents, il n'y a pas besoin de les déclarer pour les reconnaître.
  private func agents(in roomID: String) -> Set<String> {
    let membres = members[roomID] ?? []
    var resultat = membres.intersection(Set(live.peers))
    if teteATeteRooms.contains(roomID) {
      let proprietaires = Set(live.owners)
      resultat.formUnion(membres.filter { !proprietaires.contains($0) && !Trigger.isBridgeGhost($0) })
    }
    resultat.insert(live.botUserID)
    return resultat
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

  /// Faut-il m'appeler par mon nom dans ce salon ?
  ///
  /// Non dans les salons qui sont **à moi** : un tête-à-tête ouvert par l'app
  /// (elle le marque à la création) et ma console — leur seule raison d'être est
  /// de me parler, y taper « @cc » à chaque ligne est une friction sans objet.
  /// Oui partout ailleurs, et ce n'est pas négociable au hasard : dans la note à
  /// soi, où je suis invité, comme dans un fil bridgé, tout message d'un
  /// propriétaire me réveillerait. La config peut trancher salon par salon
  /// (`rooms.<id>.mention`), dans un sens comme dans l'autre.
  ///
  /// Un atelier ne passe jamais ici : plusieurs agents dans un salon, c'est la
  /// mention obligatoire de `Atelier`, et elle protège des boucles.
  private func requiresTrigger(in roomID: String) -> Bool {
    MentionPolicy.requiresTrigger(
      binding: live.rooms[roomID],
      isTeteATete: teteATeteRooms.contains(roomID),
      isConsole: roomID == consoleRoomID
    )
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
    // Un autre agent n'est pas un tiers : un brouillon n'aurait personne à
    // ménager. Dans un fil d'agent, il n'y a que des agents et moi-même.
    let allowed = Set(live.owners + [live.botUserID]).union(agents(in: roomID))
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

  /// Les ordres d'un propriétaire dans la console. `rescan` : on oublie le
  /// scan en cache et le status, on rescanne, on republie — c'est ce qui
  /// fait voir dans les réglages un moteur installé ou connecté **depuis** le
  /// démarrage, sans redémarrer. Un ordre d'avant le démarrage ne se rejoue
  /// pas (`notBefore`), et personne d'autre qu'un propriétaire n'ordonne.
  private func absorbCommands(from response: MatrixSyncResponse) async {
    for (roomID, room) in response.rooms?.join ?? [:] {
      for event in room.timeline?.events ?? [] where event.type == AgentEvents.commandType {
        guard event.sentAt >= notBefore,
              let sender = event.sender, config.owners.contains(sender),
              let content = event.content,
              let commande = AgentEvents.command(in: content, agent: config.user)
        else { continue }
        switch commande {
        case AgentWire.Command.rescan:
          log("[\(roomID)] ordre reçu : rescanner les moteurs")
          dernierScan = nil
          statusLine = nil
          await publishStatus()
        default:
          log("[\(roomID)] ordre inconnu ignoré : \(commande)")
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
    // Dans un fil d'agent, on parle à un agent : un brouillon n'y a aucun
    // sens, quel que soit le réglage par défaut.
    if teteATeteRooms.contains(roomID) { return .direct }
    return await AgentMode.resolve(
      roomMode: live.rooms[roomID]?.mode,
      isPrivateWithOwners: isPrivateWithOwners(roomID),
      accountDataDefault: accountDefaultMode,
      configuredDefault: live.defaultMode
    )
  }

  // MARK: - Ateliers

  /// Un salon où l'un des autres agents du Relais est présent. Sans pair
  /// déclaré, il n'y a pas d'atelier et rien ne change.
  private func isAtelier(_ roomID: String) -> Bool {
    agents(in: roomID).count > 1
  }

  /// Les règles d'un atelier : mention obligatoire (n'importe où dans le
  /// message), un agent ne déclenche pas un agent sauf délégation nommée par un
  /// propriétaire, et un budget de tours par salon. Cf. `Atelier`.
  private func atelierRequest(from event: MatrixEvent, roomID: String) -> AgentRequest? {
    guard Trigger.carriesText(event),
          let eventID = event.eventID,
          let sender = event.sender,
          !Trigger.isBridgeGhost(sender),
          event.sentAt >= notBefore
    else { return nil }
    let msgtype = event.content?.string(at: "msgtype") ?? "m.text"
    let media = AgentAttachment.mediaTypes.contains(msgtype)
    guard msgtype == "m.text" || msgtype == "m.notice" || media else { return nil }
    let attachments = [AgentAttachment.read(from: event.content, msgtype: msgtype)].compactMap { $0 }
    guard !media || !attachments.isEmpty else { return nil }
    // La mention reste obligatoire en atelier : elle est donc dans la légende.
    let body = media
      ? AgentAttachment.caption(from: event.content, msgtype: msgtype)
      : event.content?.string(at: "m.new_content.body")
        ?? Trigger.stripReplyFallback(event.content?.string(at: "body") ?? "")

    let budget = atelierBudgets[roomID] ?? HourlyCap(limit: live.atelierBudget)
    let presents = agents(in: roomID)
    let contexte = Atelier.Context(
      agents: presents,
      owners: Set(live.owners),
      turnsThisHour: budget.limit - budget.remaining(),
      budget: live.atelierBudget,
      triggers: [live.botUserID: live.trigger],
      host: host(of: roomID)
    )
    // La réponse d'une délégation ne déclenche jamais personne : profondeur 1.
    if presents.contains(sender), AgentEvents.isDelegatedReply(event.content) { return nil }
    // Une délégation : un propriétaire a chargé un agent d'en appeler un autre
    // (« @cc demande à @claude de… »), ou l'agent chargé m'appelle en tête de
    // phrase (« @claude fais un test de math »).
    let delegation = presents.contains(sender)
      && (Atelier.delegationTarget(in: body, among: presents, triggers: [live.botUserID: live.trigger]) == live.botUserID
          || Trigger.prompt(in: body, trigger: live.trigger) != nil)

    switch Atelier.decide(
      agent: live.botUserID, sender: sender, body: body, trigger: live.trigger,
      context: contexte, isDelegation: delegation
    ) {
    case .respond(let delegated):
      var reserve = budget
      guard reserve.admit() else {
        log("[\(roomID)] budget de l'atelier épuisé (\(live.atelierBudget)/h)")
        atelierBudgets[roomID] = reserve
        return nil
      }
      atelierBudgets[roomID] = reserve
      let prompt = Trigger.prompt(in: body, trigger: live.trigger) ?? body
      return AgentRequest(
        roomID: roomID, eventID: eventID, sender: sender, prompt: prompt,
        sentAt: event.sentAt, attachments: attachments, delegated: delegated
      )
    case .ignore(let raison):
      if raison != .notMentioned {
        log("[\(roomID)] ignoré (\(raison.rawValue)) — \(sender)")
      }
      return nil
    }
  }

  // MARK: - Un tour

  private func dispatch(_ request: AgentRequest) {
    Task { await self.handle(request) }
  }

  private func handle(_ arrivee: AgentRequest) async {
    // Un tour est déjà en vol ici : la demande attend, et elle partira avec les
    // autres. Aucune bulle — le « écrit… » dit déjà qu'on travaille, et une
    // bulle de refus remplissait la file en perdant la demande.
    guard !busyRooms.contains(arrivee.roomID) else {
      enAttente[arrivee.roomID, default: []].append(arrivee)
      log("[\(arrivee.roomID)] mise en attente (\(enAttente[arrivee.roomID]?.count ?? 0) en file)")
      return
    }
    busyRooms.insert(arrivee.roomID)
    defer { busyRooms.remove(arrivee.roomID) }

    var aTraiter = [arrivee]
    // Tant qu'il reste quelque chose, on enchaîne : ce qui est arrivé pendant
    // le tour part au tour suivant, fusionné.
    while !aTraiter.isEmpty {
      await runTurn(aTraiter)
      aTraiter = enAttente.removeValue(forKey: arrivee.roomID) ?? []
    }
  }

  /// Un tour : un lot de demandes, un appel au moteur, une réponse.
  ///
  /// Le plafond horaire se prend **ici**, au moment où le tour part — pas quand
  /// une demande entre dans la file. Deux messages coup sur coup coûtent donc
  /// un seul tour, ce qui est tout l'intérêt du lot.
  private func runTurn(_ requests: [AgentRequest]) async {
    guard let lot = RequestBatch.merge(requests) else { return }
    let request = lot.reply

    guard cap.admit() else {
      let wait = Int((cap.nextSlot() ?? 0) / 60) + 1
      await reply("Plafond horaire atteint (\(live.hourlyCap) demandes). Réessaie dans \(wait) min.", to: request)
      return
    }

    if !lot.dropped.isEmpty {
      // Une perte se dit dans le journal, jamais dans la conversation.
      log("[\(request.roomID)] ⚠ \(lot.dropped.count) demande(s) trop anciennes écartées du lot (prompt trop long)")
    }
    if lot.count > 1 {
      log("[\(request.roomID)] \(lot.count) demandes fusionnées en un tour")
    }

    let startedTurn = Date()
    let texte = lot.prompt.isEmpty && lot.attachments.isEmpty
      ? "Le propriétaire t'a appelé sans rien demander. Demande-lui ce qu'il veut, en une phrase."
      : lot.prompt
    log("[\(request.roomID)] \(request.sender) → « \(texte.prefix(80)) »"
      + (lot.attachments.isEmpty ? "" : " + \(lot.attachments.count) pièce(s) jointe(s)"))

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

    // Le moteur est-il seulement là ? Se taire était le pire des choix : on
    // écrit « @cc … », rien ne revient, et il faut aller lire un journal sur
    // une autre machine pour apprendre que `hermes` n'a jamais été installé.
    // Un agent qui ne peut pas répondre dit pourquoi, et où.
    let scan = await scanCourant()
    if !scan.isPresent(live.backend) {
      let moteur = scan.configuredEngine ?? live.backend.rawValue
      let message = EngineScan.absenceFR(engine: moteur, host: EngineScan.hostName)
      log("[\(request.roomID)] moteur \(moteur) absent — on le dit plutôt que de se taire")
      await reply(message, to: request)
      await journal(request, seconds: Date().timeIntervalSince(startedTurn), tools: [], tokens: nil)
      return
    }
    // Là, mais jamais connecté : le tour remonterait « invalid credentials »
    // en anglais, sans le geste. On le dit en français, avec le geste.
    if scan.isLoggedOut(live.backend) {
      let moteur = scan.configuredEngine ?? live.backend.rawValue
      let message = EngineScan.nonConnecteFR(engine: moteur, host: EngineScan.hostName)
      log("[\(request.roomID)] moteur \(moteur) installé mais pas connecté — on le dit")
      await reply(message, to: request)
      await journal(request, seconds: Date().timeIntervalSince(startedTurn), tools: [], tokens: nil)
      return
    }

    do {
      // Jamais `~` : un tour travaille dans le dossier de sa room tant qu'aucun
      // dépôt n'est lié. C'est le rayon d'explosion, et c'est le garde-fou qui
      // remplace la question qu'on ne pose plus.
      let cwd = Workspace.prepare(
        Workspace.directory(agent: live.user, roomID: request.roomID, binding: live.rooms[request.roomID]?.cwd)
      )
      // Les pièces jointes descendent sur le disque du tour, dans le dossier de
      // la room — jamais ailleurs : c'est le même rayon d'explosion que le
      // reste. Le prompt ne porte que leurs chemins ; un moteur sait ouvrir un
      // fichier, il ne sait pas suivre un `mxc://`.
      let lignes = await AgentAttachmentDrop.drop(
        lot.attachments,
        eventID: request.eventID,
        cwd: cwd,
        download: { [client] mxc in try await client.downloadMedia(mxcURI: mxc) }
      )
      for ligne in lignes { log("[\(request.roomID)] pièce jointe \(ligne.dropFirst(2))") }
      let prompt = AgentAttachmentDrop.promptSection(lignes) + atelierPreamble(for: request.roomID) + texte
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

  /// Ce que le moteur doit savoir des autres agents du salon : qu'ils sont
  /// là, et **comment** leur confier une tâche — un message qui commence par
  /// leur mention. Sans ça, « dis à @claude de… » fait chercher au moteur une
  /// session claude sur sa machine, et il répond « injoignable » : le salon
  /// est le seul chemin, et rien ne le lui disait.
  private func atelierPreamble(for roomID: String) -> String {
    let autres = agents(in: roomID).subtracting([live.botUserID]).sorted()
    guard !autres.isEmpty else { return "" }
    let noms = autres.map { agent -> String in
      let local = agent.hasPrefix("@") ? String(agent.dropFirst()) : agent
      return "@" + (local.split(separator: ":").first.map(String.init) ?? local)
    }
    return "Autres agents présents dans cette conversation : \(noms.joined(separator: ", ")). "
      + "Pour confier une tâche à l'un d'eux, réponds par un message qui **commence** par sa mention "
      + "(par exemple « \(noms[0]) fais ceci ») : lui seul y répondra, dans cette conversation. "
      + "Ne cherche pas à le joindre autrement.\n\n"
  }

  /// Le scan des moteurs, refait seulement quand le moteur configuré change.
  /// Bloquant (des `--version`) : détaché, comme au démarrage.
  private func scanCourant() async -> EngineScan {
    let config = self.live
    let attendu: String? = switch config.backend {
    case .claude: "claude"
    case .hermes: "hermes"
    case .acp: config.acp.command
    }
    if let dernierScan, dernierScan.engine == attendu { return dernierScan.scan }
    let scan = await Task.detached { EngineScan.scan(config: config) }.value
    dernierScan = (engine: attendu, scan: scan)
    return scan
  }

  // MARK: - Journal

  /// Chaque tour laisse une trace dans la room console : qui a demandé, quoi,
  /// quels outils ont servi, combien de temps. Depuis qu'on donne la pleine
  /// permission, c'est ce qui rend l'agent relisible — et c'est le troisième
  /// garde-fou avec le dossier borné et les propriétaires seuls.
  ///
  /// On n'invente pas un endroit où déverser ce que les gens se disent : sans
  /// console, rien n'est posté. Mais **on le dit** — un garde-fou qui ne peut
  /// pas s'exercer et qui se tait est pire qu'un garde-fou absent, parce que
  /// personne ne sait qu'il manque.
  private func journal(_ request: AgentRequest, seconds: Double, tools: [String], tokens: Int?) async {
    let carnet = AgentJournal(consoleRoomID: consoleRoomID) { [client] roomID, type, content in
      try await client.sendEvent(roomID: roomID, type: type, content: content)
    }
    let issue = await carnet.record(
      agent: live.user, roomID: request.roomID, sender: request.sender,
      prompt: request.prompt, tools: tools, seconds: seconds, tokens: tokens
    )
    switch issue {
    case .written:
      journalIndisponible = nil
    case .impossible(let raison):
      // Une fois dans le journal local, et dans le status : l'app doit pouvoir
      // le montrer sans qu'on aille lire un fichier sur la machine.
      if journalIndisponible != raison {
        log("⚠ \(raison)")
        journalIndisponible = raison
        statusLine = nil  // le prochain status portera l'avertissement
      }
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
      var ligne = scan.statusLine(
        backend: config.backend, agent: config.user, host: EngineScan.hostName, since: startedAt
      )
      // Un garde-fou qui manque se voit dans les réglages, pas seulement dans
      // un fichier sur la machine de l'agent.
      if journalIndisponible != nil { ligne += " · ⚠ journal indisponible" }
      statusLine = ligne
      log("moteurs : \(statusLine ?? "")")
    }
    guard let line = statusLine else { return }
    let targets: [String]
    if let rooms {
      targets = rooms
    } else {
      guard let joined = try? await client.joinedRooms() else {
        log("⚠ status non publié : le Relais n'a pas répondu — l'app dira que cc est muet")
        return
      }
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
      // Dans un atelier, le tour se déroule dans un thread : seul le résultat
      // remonte, et le salon reste lisible à trois moteurs.
      if isAtelier(request.roomID), mode == .direct, !teteATeteRooms.contains(request.roomID) {
        try await client.sendEvent(
          roomID: request.roomID,
          type: "m.room.message",
          content: AgentEvents.threadedText(text, root: request.eventID, lastEventID: request.eventID, delegated: request.delegated)
        )
        return
      }
      switch mode {
      case .direct:
        // Pas de préfixe : côté Relais l'expéditeur est déjà « cc », et sur un
        // portail en relais c'est le pont qui signe (`message_formats`) — en
        // préfixer un ici doublerait la signature chez le correspondant.
        try await client.sendEvent(
          roomID: request.roomID, type: "m.room.message",
          content: AgentEvents.replyText(text, inReplyTo: request.eventID, delegated: request.delegated)
        )
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
