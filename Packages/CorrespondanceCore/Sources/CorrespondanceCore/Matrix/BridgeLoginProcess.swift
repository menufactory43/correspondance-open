import Foundation

/// Une étape de connexion telle que l'API de provisioning de bridgev2 la décrit.
///
/// Le chat avec le bot raconte la connexion en prose (« Please enter your Email »,
/// « Login URL: … ») ; l'API de provisioning (`/_matrix/provision/v3/login/…`) la
/// décrit en JSON : le type de l'étape, les champs à saisir (avec leur type, leurs
/// options), ou — pour une étape « cookies » — la page à ouvrir et le JavaScript qui
/// en extrait ce que le pont attend. C'est ce que Beeper consomme, et c'est le seul
/// chemin pour le captcha de Slack : le bot n'en montre, dans le chat, que l'URL.
///
/// Le modèle est volontairement celui du pont (`bridgev2.LoginStep`), pour qu'une
/// étape inconnue ne casse rien : l'app affiche `instructions` et s'arrête là.
public struct BridgeLoginProcessStep: Decodable, Sendable, Equatable {
  public enum Kind: String, Decodable, Sendable {
    case userInput = "user_input"
    case cookies
    case clientHTTP = "client_http"
    case displayAndWait = "display_and_wait"
    case webauthn
    case complete
  }

  /// Un champ de saisie : `type` est un indice pour l'affichage (`email`,
  /// `2fa_code`, `select`…), `id` la clé à renvoyer.
  public struct InputField: Decodable, Sendable, Equatable {
    public let type: String
    public let id: String
    public let name: String
    public let description: String?
    public let defaultValue: String?
    public let pattern: String?
    public let options: [String]?

    enum CodingKeys: String, CodingKey {
      case type, id, name, description, pattern, options
      case defaultValue = "default_value"
    }

    /// À masquer à l'écran : un code, un mot de passe, un jeton.
    public var isSecret: Bool {
      ["password", "2fa_code", "token", "captcha_code"].contains(type)
    }
  }

  public struct UserInputParams: Decodable, Sendable, Equatable {
    public let fields: [InputField]
  }

  /// D'où le client peut tirer un champ d'une étape « cookies » : un cookie
  /// (`cookie`, avec son domaine), le `localStorage`, le corps d'une requête, ou
  /// `special` — le JavaScript d'extraction le rend directement.
  public struct CookieSource: Decodable, Sendable, Equatable {
    public let type: String
    public let name: String
    public let requestURLRegex: String?
    public let cookieDomain: String?

    enum CodingKeys: String, CodingKey {
      case type, name
      case requestURLRegex = "request_url_regex"
      case cookieDomain = "cookie_domain"
    }
  }

  public struct CookieField: Decodable, Sendable, Equatable {
    public let id: String
    public let required: Bool?
    public let sources: [CookieSource]
    public let pattern: String?

    public var isRequired: Bool { required ?? false }
  }

  public struct CookiesParams: Decodable, Sendable, Equatable {
    public let url: String
    public let userAgent: String?
    public let fields: [CookieField]
    /// Un JavaScript qui s'évalue en une promesse ; elle se résout en un objet
    /// dont les clés sont des `fields[].id`. Ce qui n'y est pas se prend ailleurs
    /// (les cookies, selon `sources`).
    public let extractJS: String?
    public let waitForURLPattern: String?
    public let hidden: Bool?

    enum CodingKeys: String, CodingKey {
      case url, fields, hidden
      case userAgent = "user_agent"
      case extractJS = "extract_js"
      case waitForURLPattern = "wait_for_url_pattern"
    }

    /// Les champs que le JavaScript ne rend pas et qu'il faut lire dans le
    /// magasin de cookies de la vue web : `(id, nom du cookie, domaine)`.
    public var cookieBackedFields: [(id: String, cookieName: String, domain: String?)] {
      fields.flatMap { field in
        field.sources
          .filter { $0.type == "cookie" }
          .map { (id: field.id, cookieName: $0.name, domain: $0.cookieDomain) }
      }
    }

    /// Les identifiants des champs obligatoires.
    public var requiredFieldIDs: [String] {
      fields.filter(\.isRequired).map(\.id)
    }
  }

  public struct CompleteParams: Decodable, Sendable, Equatable {
    public let userLoginID: String?

    enum CodingKeys: String, CodingKey {
      case userLoginID = "user_login_id"
    }
  }

  /// L'identifiant du processus côté pont : il nomme les requêtes suivantes.
  public let loginID: String
  public let type: Kind
  public let stepID: String
  public let instructions: String
  public let userInput: UserInputParams?
  public let cookies: CookiesParams?
  public let complete: CompleteParams?

  enum CodingKeys: String, CodingKey {
    case type, instructions, cookies, complete
    case loginID = "login_id"
    case stepID = "step_id"
    case userInput = "user_input"
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    loginID = try c.decode(String.self, forKey: .loginID)
    type = try c.decode(Kind.self, forKey: .type)
    stepID = try c.decodeIfPresent(String.self, forKey: .stepID) ?? ""
    instructions = try c.decodeIfPresent(String.self, forKey: .instructions) ?? ""
    userInput = try c.decodeIfPresent(UserInputParams.self, forKey: .userInput)
    cookies = try c.decodeIfPresent(CookiesParams.self, forKey: .cookies)
    complete = try c.decodeIfPresent(CompleteParams.self, forKey: .complete)
  }

  public static func decode(_ data: Data) throws -> BridgeLoginProcessStep {
    try JSONDecoder().decode(BridgeLoginProcessStep.self, from: data)
  }

  /// Le premier champ de saisie, quand l'étape en demande un — c'est le cas de
  /// tout le flow Slack (e-mail, code, espace de travail, 2FA : un par étape).
  public var firstInputField: InputField? { userInput?.fields.first }
}

// MARK: - Le client de l'API de provisioning

extension MatrixBridgeService {
  /// L'adresse de l'API de provisioning d'un pont : le homeserver, port du pont.
  ///
  /// Le pont est publié sur la même interface que Synapse (bootstrap.sh ne publie
  /// jamais sur 0.0.0.0), et la requête passe par la même `URLSession` — donc par
  /// le même mandataire tailcat, s'il y en a un. Rien de plus à configurer.
  public static func provisioningURL(homeserver: URL, port: Int) -> URL? {
    var components = URLComponents(url: homeserver, resolvingAgainstBaseURL: false)
    components?.port = port
    components?.path = ""
    components?.query = nil
    return components?.url
  }

  private func provisioningBase(for network: MessageNetwork) async throws -> URL {
    guard let port = network.bridge?.provisioningPort else { throw MatrixError.notConfigured }
    guard let creds = await client.currentCredentials,
          let base = Self.provisioningURL(homeserver: creds.homeserver, port: port)
    else { throw MatrixError.notConfigured }
    return base
  }

  private func provisioningRequest(
    network: MessageNetwork,
    method: String = "POST",
    path: String,
    body: [String: String]? = nil
  ) async throws -> Data {
    let base = try await provisioningBase(for: network)
    // L'API accepte le jeton Matrix de l'utilisateur (`allow_matrix_auth`), à
    // condition de nommer l'utilisateur en clair : `?user_id=`.
    let query = [URLQueryItem(name: "user_id", value: selfUserID)]
    let json: MatrixJSON? = body.map { .object($0.mapValues { .string($0) }) }
    return try await client.rawRequest(
      method: method,
      path: "/_matrix/provision/v3" + path,
      query: query,
      body: method == "GET" ? nil : (json ?? .object([:])),
      homeserverOverride: base
    )
  }

  // MARK: - Les comptes connectés

  /// Les comptes de l'utilisateur sur un pont, tels que `whoami` les liste.
  /// Vide si le pont n'a pas d'API publiée, ou ne répond pas — Réglages le dit
  /// alors, sans casser le reste.
  public func bridgeAccounts(network: MessageNetwork) async throws -> [BridgeAccount] {
    let data = try await provisioningRequest(network: network, method: "GET", path: "/whoami")
    return try BridgeAccount.decodeWhoami(data)
  }

  /// Déconnecte un compte du pont. Le pont ferme la session côté réseau et
  /// cesse d'alimenter ses salons ; ils restent dans l'inbox comme historique.
  public func logoutBridgeAccount(network: MessageNetwork, loginID: String) async throws {
    let escaped = loginID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? loginID
    _ = try await provisioningRequest(network: network, path: "/logout/\(escaped)")
  }

  /// Démarre un processus de connexion par l'API de provisioning, et rend sa
  /// première étape. `flow` est l'identifiant annoncé par le connecteur
  /// (`email`, `token`…).
  public func startProvisionedLogin(network: MessageNetwork, flow: String) async throws -> BridgeLoginProcessStep {
    let data = try await provisioningRequest(network: network, path: "/login/start/\(flow)")
    return try Self.decodeStep(data)
  }

  /// Répond à une étape — les valeurs saisies (`user_input`) ou extraites de la
  /// vue web (`cookies`) — et rend la suivante.
  public func submitProvisionedStep(
    network: MessageNetwork,
    step: BridgeLoginProcessStep,
    values: [String: String]
  ) async throws -> BridgeLoginProcessStep {
    let path = "/login/step/\(step.loginID)/\(step.stepID)/\(step.type.rawValue)"
    let data = try await provisioningRequest(network: network, path: path, body: values)
    return try Self.decodeStep(data)
  }

  /// Solde un processus — « Relancer », la fenêtre fermée. Sans ça le pont le
  /// garde une demi-heure, et un nouveau `start` pourrait buter sur « too many
  /// logins ».
  public func cancelProvisionedLogin(network: MessageNetwork, loginID: String) async {
    _ = try? await provisioningRequest(network: network, path: "/login/cancel/\(loginID)")
  }

  private static func decodeStep(_ data: Data) throws -> BridgeLoginProcessStep {
    do {
      return try BridgeLoginProcessStep.decode(data)
    } catch {
      throw MatrixError.decoding("étape de connexion du pont")
    }
  }
}

// MARK: - Un compte connecté

/// Un compte de l'utilisateur sur un pont, d'après `whoami` : son identifiant
/// (celui que `logout` attend), son nom côté réseau, et son état.
public struct BridgeAccount: Sendable, Equatable, Identifiable {
  public let id: String
  /// Le nom que le pont donne au compte (« Acme - moi@acme.com », un numéro…).
  public let name: String
  public let phone: String?
  public let email: String?
  public let username: String?
  public let displayName: String?
  /// `state_event` du pont : `CONNECTED`, `CONNECTING`, `BACKFILLING`,
  /// `TRANSIENT_DISCONNECT`, `BAD_CREDENTIALS`, `UNKNOWN_ERROR`, `LOGGED_OUT`…
  public let stateEvent: String
  public let stateMessage: String?

  public init(
    id: String, name: String, phone: String? = nil, email: String? = nil, username: String? = nil,
    displayName: String? = nil, stateEvent: String, stateMessage: String? = nil
  ) {
    self.id = id
    self.name = name
    self.phone = phone
    self.email = email
    self.username = username
    self.displayName = displayName
    self.stateEvent = stateEvent
    self.stateMessage = stateMessage
  }

  /// Ce qu'on affiche : le nom du profil, sinon le nom du pont, sinon l'identifiant.
  public var labelFR: String {
    let primary = [displayName, name].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? id
    let secondary = [phone, username.map { "@" + $0 }, email].compactMap { $0 }.first { !$0.isEmpty && !primary.contains($0) }
    return secondary.map { "\(primary) · \($0)" } ?? primary
  }

  public var isConnected: Bool {
    ["CONNECTED", "BACKFILLING", "CONNECTING", "TRANSIENT_DISCONNECT"].contains(stateEvent)
  }

  public var stateFR: String {
    switch stateEvent {
    case "CONNECTED": "Connecté"
    case "BACKFILLING": "Connecté, historique en cours"
    case "CONNECTING": "Connexion…"
    case "TRANSIENT_DISCONNECT": "Reconnexion…"
    case "BAD_CREDENTIALS": "Session expirée : à reconnecter"
    case "LOGGED_OUT": "Déconnecté"
    case "UNKNOWN_ERROR": "En erreur" + (stateMessage.map { " : \($0)" } ?? "")
    default: stateEvent.isEmpty ? "État inconnu" : stateEvent
    }
  }

  /// Lecture de la réponse de `whoami` : seule la liste `logins` nous intéresse.
  public static func decodeWhoami(_ data: Data) throws -> [BridgeAccount] {
    struct Whoami: Decodable {
      struct Login: Decodable {
        struct State: Decodable {
          let stateEvent: String?
          let message: String?
          enum CodingKeys: String, CodingKey { case message; case stateEvent = "state_event" }
        }
        struct Profile: Decodable {
          let phone: String?
          let email: String?
          let username: String?
          let name: String?
        }
        let id: String
        let name: String?
        let profile: Profile?
        let state: State?
      }
      let logins: [Login]?
    }
    let whoami = try JSONDecoder().decode(Whoami.self, from: data)
    return (whoami.logins ?? []).map { login in
      BridgeAccount(
        id: login.id,
        name: login.name ?? "",
        phone: login.profile?.phone,
        email: login.profile?.email,
        username: login.profile?.username,
        displayName: login.profile?.name,
        stateEvent: login.state?.stateEvent ?? "",
        stateMessage: login.state?.message
      )
    }
  }
}
