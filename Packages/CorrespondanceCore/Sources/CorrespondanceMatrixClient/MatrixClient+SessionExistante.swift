import Foundation

/// Ouvrir une session neuve **à partir d'une session déjà connectée**, sans
/// retaper de mot de passe ni tirer de code d'appairage.
///
/// C'est le mécanisme de la spécification (Matrix 1.7, ex-MSC3882) : la session
/// existante demande un jeton de connexion à usage unique
/// (`POST /login/get_token`), et le nouvel appareil s'en sert pour se connecter
/// (`m.login.token`). Le serveur doit l'autoriser — `login_via_existing_session`
/// chez Synapse comme chez Continuwuity. Il peut aussi exiger, une fois, le mot de
/// passe du compte (authentification interactive) : l'appelant le demande alors.
extension MatrixClient {
  public struct JetonDeConnexion: Sendable, Equatable {
    public let jeton: String
    /// Durée de validité annoncée par le serveur, s'il la donne.
    public let expireDans: TimeInterval?
  }

  public enum ErreurSessionExistante: Error, Equatable, Sendable {
    /// Le Relais ne propose pas ce chemin (option coupée, ou serveur trop ancien).
    case nonProposee
    /// Le Relais veut le mot de passe du compte pour délivrer le jeton.
    case motDePasseRequis(session: String?)
    /// Le mot de passe donné est refusé.
    case motDePasseRefuse
  }

  /// Demande un jeton de connexion pour un autre appareil, avec la session du
  /// client. `motDePasse` ne sert que si le serveur l'a exigé au premier essai.
  public func demanderJetonDeConnexion(motDePasse: String? = nil, sessionUIA: String? = nil) async throws -> JetonDeConnexion {
    guard let credentials = currentCredentials else { throw MatrixError.notConfigured }
    var body: [String: MatrixJSON] = [:]
    if let motDePasse {
      var auth: [String: MatrixJSON] = [
        "type": .string("m.login.password"),
        "identifier": .object(["type": .string("m.id.user"), "user": .string(credentials.userID)]),
        "password": .string(motDePasse),
      ]
      if let sessionUIA { auth["session"] = .string(sessionUIA) }
      body["auth"] = .object(auth)
    }
    // Le chemin stable d'abord, l'ancien chemin instable ensuite : un serveur de
    // 2023 ne connaît que le second.
    let chemins = [
      "/_matrix/client/v1/login/get_token",
      "/_matrix/client/unstable/org.matrix.msc3882/login/get_token",
    ]
    for chemin in chemins {
      do {
        let json = try await request(method: "POST", path: chemin, body: .object(body))
        guard let jeton = json.string(at: "login_token") else {
          throw MatrixError.decoding("jeton de connexion absent")
        }
        let millisecondes = json["expires_in_ms"]?.intValue ?? json["expires_in"]?.intValue
        return JetonDeConnexion(jeton: jeton, expireDans: millisecondes.map { Double($0) / 1000 })
      } catch MatrixError.http(let status, let errcode, _) {
        switch (status, errcode) {
        case (404, _), (405, _), (400, "M_UNRECOGNIZED"):
          continue // chemin inconnu : on essaie le suivant
        case (401, _) where dernierCorpsDErreur?["flows"] != nil:
          // Authentification interactive : le serveur veut le mot de passe. S'il
          // le redemande alors qu'on vient de le donner, c'est qu'il est faux.
          if motDePasse != nil { throw ErreurSessionExistante.motDePasseRefuse }
          throw ErreurSessionExistante.motDePasseRequis(session: dernierCorpsDErreur?.string(at: "session"))
        case (403, "M_FORBIDDEN") where motDePasse != nil:
          throw ErreurSessionExistante.motDePasseRefuse
        case (403, _), (400, _):
          // Synapse répond 403/400 quand l'option est coupée.
          throw ErreurSessionExistante.nonProposee
        default:
          throw MatrixError.http(status: status, errcode: errcode, message: dernierCorpsDErreur?.string(at: "error"))
        }
      }
    }
    throw ErreurSessionExistante.nonProposee
  }

  /// `POST /login` avec un jeton de connexion : la session du nouvel appareil.
  public func login(homeserver: URL, loginToken: String) async throws -> MatrixCredentials {
    let body: [String: MatrixJSON] = [
      "type": .string("m.login.token"),
      "token": .string(loginToken),
      "initial_device_display_name": .string(Self.deviceDisplayName),
    ]
    let json = try await request(
      method: "POST",
      path: "/_matrix/client/v3/login",
      body: .object(body),
      homeserverOverride: homeserver,
      authenticated: false
    )
    guard let token = json.string(at: "access_token"),
          let userID = json.string(at: "user_id")
    else {
      throw MatrixError.decoding("réponse de connexion sans access_token")
    }
    let creds = MatrixCredentials(
      homeserver: homeserver,
      userID: userID,
      accessToken: token,
      deviceID: json.string(at: "device_id")
    )
    setCredentials(creds)
    return creds
  }
}
