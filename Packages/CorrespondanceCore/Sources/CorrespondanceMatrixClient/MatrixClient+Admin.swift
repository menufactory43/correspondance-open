import Foundation

/// Le branchement de la couche « salon d'administration » sur le client.
///
/// Les cinq fonctions d'administration gardent leur signature : l'appelant
/// (`MatrixBridgeService`, l'écran des réglages) ne sait pas sur quel Relais il
/// parle, et n'a pas à le savoir.

/// Ce que le Relais offre comme administration.
public enum RelaisAdministration: String, Sendable, Equatable {
  /// `_synapse/admin` répond : Synapse, ou un serveur qui l'imite.
  case synapse
  /// Il faut passer par des commandes dans `#admins` : Continuwuity.
  case salonAdmin
}

extension MatrixClient {

  // MARK: - Détecter, une fois

  /// **Pourquoi le 404 plutôt que le nom du serveur.**
  ///
  /// On aurait pu lire `/_matrix/client/versions` ou `/_matrix/federation/v1/version`
  /// et y chercher « Continuwuity ». Trois raisons de ne pas le faire : la
  /// fédération est **fermée** sur un Relais personnel (la route ne répond
  /// pas) ; un nom se déguise (fork, proxy, en-tête réécrit) ; et surtout, un
  /// Synapse peut très bien avoir son API d'administration **désactivée** — le
  /// nom dirait alors « Synapse » et l'appel échouerait quand même.
  ///
  /// On éprouve donc la capacité elle-même : le premier appel `_synapse/admin`
  /// de la session part pour de vrai ; s'il revient en `M_UNRECOGNIZED`, la
  /// session entière bascule sur `#admins` et l'appel est refait par là. Ça
  /// coûte **une** requête perdue par session, et rien ne se devine.
  func administrationDuRelais() async -> RelaisAdministration? { administration }

  func noterSalonAdmin() {
    guard administration != .salonAdmin else { return }
    administration = .salonAdmin
  }

  func noterSynapse() { administration = .synapse }

  /// Une route que le serveur ne connaît pas — la signature exacte que
  /// Continuwuity rend sur les quatre appels de la matrice :
  /// `404 {"errcode":"M_UNRECOGNIZED","error":"not found :("}`. Certains
  /// serveurs répondent 400 sur le même motif : on accepte les deux.
  public static func estUneRouteInconnue(_ erreur: Error) -> Bool {
    guard case MatrixError.http(let status, let errcode, _) = erreur else { return false }
    if errcode == "M_UNRECOGNIZED" { return true }
    return status == 404 && errcode == nil
  }

  // MARK: - La couche #admins

  /// La couche, construite au premier besoin sur le serveur de notre propre
  /// MXID. `nil` si on n'est pas connecté.
  func salonAdmin() -> MatrixSalonAdmin? {
    if let couchesalonAdmin { return couchesalonAdmin }
    guard let userID = credentials?.userID,
          let serveur = userID.split(separator: ":").dropFirst().first
    else { return nil }
    let couche = MatrixSalonAdmin(
      transport: MatrixClientAdminTransport(client: self), serveur: String(serveur))
    couchesalonAdmin = couche
    return couche
  }

  /// `provisionUser` par `#admins` : créer, et si le compte est déjà là, lui
  /// reposer le mot de passe **sans `--logout`**.
  func provisionnerParSalonAdmin(userID: String, password: String) async throws {
    guard let salon = salonAdmin() else { throw MatrixError.notConfigured }
    do {
      _ = try await salon.commande(
        MatrixAdminCommandes.creer(userID: userID, motDePasse: password))
    } catch MatrixSalonAdmin.Echec.commandeRefusee(let detail)
      where MatrixAdminCommandes.compteDejaLa(detail)
    {
      _ = try await salon.commande(
        MatrixAdminCommandes.reposerMotDePasse(userID: userID, motDePasse: password))
    }
  }

  /// `userDevices` par `#admins`, puis l'analyse du `Debug` Rust. C'est ce
  /// résultat qui alimente la garde du second cc (`AgentSessions.elsewhere`,
  /// fenêtre de quinze minutes) : `display_name` et `last_seen_ts` y sont, donc
  /// la garde tient telle qu'elle est écrite.
  func sessionsParSalonAdmin(userID: String) async throws -> [UserDevice] {
    guard let salon = salonAdmin() else { throw MatrixError.notConfigured }
    let reponse = try await salon.commande(MatrixAdminCommandes.sessions(userID: userID))
    return MatrixSessionsRust.analyser(reponse)
  }

  // MARK: - Ce dont la couche a besoin, en vrai

  /// `GET /directory/room/{alias}` — la seule route que le client n'avait pas.
  public func resolveRoomAlias(_ alias: String) async throws -> String? {
    let json = try await request(
      method: "GET",
      path: "/_matrix/client/v3/directory/room/\(Self.escape(alias))",
      body: nil
    )
    return json.string(at: "room_id")
  }
}

/// L'implémentation réelle du transport de la couche `#admins`. Elle relit
/// l'historique du salon (`/messages`) plutôt que d'ouvrir un second `/sync` :
/// l'app en tient déjà un, et deux boucles de synchronisation sur le même jeton
/// se marcheraient dessus pour rien.
struct MatrixClientAdminTransport: MatrixAdminTransport {
  let client: MatrixClient

  func resoudreAlias(_ alias: String) async throws -> String? {
    try await client.resolveRoomAlias(alias)
  }

  func salonsRejoints() async throws -> [String] {
    try await client.joinedRooms()
  }

  func envoyerTexte(salon: String, corps: String) async throws -> String {
    let event = try await client.sendEvent(
      roomID: salon, type: "m.room.message",
      content: .object(["msgtype": .string("m.text"), "body": .string(corps)]))
    guard let event else { throw MatrixError.decoding("commande d'administration sans event_id") }
    return event
  }

  func derniersMessages(salon: String, limite: Int) async throws -> [MatrixAdminMessage] {
    let reponse = try await client.roomMessages(roomID: salon, direction: "b", limit: limite)
    return reponse.chunk.compactMap { event in
      guard event.type == "m.room.message",
            let corps = event.content?.value(at: "body")?.stringValue
      else { return nil }
      guard let identifiant = event.eventID else { return nil }
      return MatrixAdminMessage(eventID: identifiant, sender: event.sender ?? "", body: corps)
    }
  }
}
