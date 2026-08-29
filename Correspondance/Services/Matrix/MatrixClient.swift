import Foundation

/// Client Matrix Client-Server v3 en REST pur (`URLSession`). Pas de SDK, pas d'E2EE :
/// homeserver privé sur Tailscale, salons de bridge non chiffrés.
actor MatrixClient {
  private var credentials: MatrixCredentials?
  private let session: URLSession
  /// `txnId` déjà consommés — un renvoi du même identifiant ne doit pas dupliquer le message.
  private var ledger = MatrixTransactionLedger()

  init(credentials: MatrixCredentials? = nil) {
    self.credentials = credentials
    let config = URLSessionConfiguration.ephemeral
    // Le long-poll /sync tient 30 s côté serveur : la marge évite les faux timeouts.
    config.timeoutIntervalForRequest = 60
    config.timeoutIntervalForResource = 120
    config.waitsForConnectivity = false
    session = URLSession(configuration: config)
  }

  var currentCredentials: MatrixCredentials? { credentials }
  var isConfigured: Bool { credentials != nil }

  func setCredentials(_ value: MatrixCredentials?) {
    credentials = value
  }

  // MARK: - Session

  /// `POST /login` — renvoie la session, à charge de l'appelant de la persister.
  func login(homeserver: URL, user: String, password: String) async throws -> MatrixCredentials {
    let body: [String: MatrixJSON] = [
      "type": .string("m.login.password"),
      "identifier": .object(["type": .string("m.id.user"), "user": .string(user)]),
      "password": .string(password),
      "initial_device_display_name": .string("Correspondance (Mac)"),
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
    credentials = creds
    return creds
  }

  func whoami() async throws -> String {
    let json = try await request(method: "GET", path: "/_matrix/client/v3/account/whoami")
    guard let userID = json.string(at: "user_id") else {
      throw MatrixError.decoding("whoami sans user_id")
    }
    return userID
  }

  func logout() async {
    _ = try? await request(method: "POST", path: "/_matrix/client/v3/logout", body: .object([:]))
    credentials = nil
  }

  /// Versions supportées — sert de test de joignabilité avant d'écrire un mot de passe.
  func serverVersions(homeserver: URL) async throws -> [String] {
    let json = try await request(
      method: "GET",
      path: "/_matrix/client/versions",
      homeserverOverride: homeserver,
      authenticated: false
    )
    return json["versions"]?.arrayValue?.compactMap(\.stringValue) ?? []
  }

  // MARK: - Sync

  func sync(since: String?, timeoutMilliseconds: Int = 30_000) async throws -> MatrixSyncResponse {
    var items = [
      URLQueryItem(name: "timeout", value: String(timeoutMilliseconds)),
      // Sans `since`, on veut l'état complet mais peu d'historique : le backfill du bridge fera le reste.
      URLQueryItem(name: "full_state", value: since == nil ? "true" : "false"),
    ]
    if let since { items.append(URLQueryItem(name: "since", value: since)) }
    let data = try await rawRequest(method: "GET", path: "/_matrix/client/v3/sync", query: items)
    do {
      return try JSONDecoder().decode(MatrixSyncResponse.self, from: data)
    } catch {
      throw MatrixError.decoding("sync — \(error.localizedDescription)")
    }
  }

  // MARK: - Salons

  func roomMessages(
    roomID: String,
    from: String? = nil,
    direction: String = "b",
    limit: Int = 50
  ) async throws -> MatrixMessagesResponse {
    var items = [
      URLQueryItem(name: "dir", value: direction),
      URLQueryItem(name: "limit", value: String(limit)),
    ]
    if let from { items.append(URLQueryItem(name: "from", value: from)) }
    let data = try await rawRequest(
      method: "GET",
      path: "/_matrix/client/v3/rooms/\(Self.escape(roomID))/messages",
      query: items
    )
    do {
      return try JSONDecoder().decode(MatrixMessagesResponse.self, from: data)
    } catch {
      throw MatrixError.decoding("messages — \(error.localizedDescription)")
    }
  }

  func roomState(roomID: String, type: String, stateKey: String = "") async throws -> MatrixJSON {
    let suffix = stateKey.isEmpty ? "" : "/\(Self.escape(stateKey))"
    return try await request(
      method: "GET",
      path: "/_matrix/client/v3/rooms/\(Self.escape(roomID))/state/\(Self.escape(type))\(suffix)"
    )
  }

  func joinedRooms() async throws -> [String] {
    let json = try await request(method: "GET", path: "/_matrix/client/v3/joined_rooms")
    return json["joined_rooms"]?.arrayValue?.compactMap(\.stringValue) ?? []
  }

  /// Crée un DM (invitation + `is_direct`). Utilisé pour le salon de gestion du bot.
  func createDM(with userID: String) async throws -> String {
    let body: MatrixJSON = .object([
      "is_direct": .bool(true),
      "preset": .string("trusted_private_chat"),
      "invite": .array([.string(userID)]),
    ])
    let json = try await request(method: "POST", path: "/_matrix/client/v3/createRoom", body: body)
    guard let roomID = json.string(at: "room_id") else {
      throw MatrixError.decoding("createRoom sans room_id")
    }
    return roomID
  }

  // MARK: - Envoi

  /// `txnId` idempotent : deux appels avec le même identifiant n'envoient qu'un message.
  @discardableResult
  func sendText(roomID: String, body text: String, transactionID: String = UUID().uuidString) async throws -> String? {
    guard !ledger.isUsed(transactionID) else { return nil }
    let json = try await request(
      method: "PUT",
      path: "/_matrix/client/v3/rooms/\(Self.escape(roomID))/send/m.room.message/\(Self.escape(transactionID))",
      body: .object(["msgtype": .string("m.text"), "body": .string(text)])
    )
    ledger.markUsed(transactionID)
    return json.string(at: "event_id")
  }

  /// Upload puis event `m.image` (ou `m.file` si le type n'est pas une image).
  @discardableResult
  func sendAttachment(
    roomID: String,
    fileURL: URL,
    transactionID: String = UUID().uuidString
  ) async throws -> String? {
    guard !ledger.isUsed(transactionID) else { return nil }
    let data: Data
    do {
      data = try Data(contentsOf: fileURL)
    } catch {
      throw MatrixError.transport("lecture de \(fileURL.lastPathComponent) impossible")
    }
    let filename = fileURL.lastPathComponent
    let mime = Self.mimeType(for: fileURL)
    let mxc = try await upload(data: data, filename: filename, contentType: mime)
    let msgtype = mime.hasPrefix("image/") ? "m.image" : (mime.hasPrefix("video/") ? "m.video" : "m.file")
    let json = try await request(
      method: "PUT",
      path: "/_matrix/client/v3/rooms/\(Self.escape(roomID))/send/m.room.message/\(Self.escape(transactionID))",
      body: .object([
        "msgtype": .string(msgtype),
        "body": .string(filename),
        "url": .string(mxc),
        "info": .object([
          "mimetype": .string(mime),
          "size": .number(Double(data.count)),
        ]),
      ])
    )
    ledger.markUsed(transactionID)
    return json.string(at: "event_id")
  }

  func upload(data: Data, filename: String, contentType: String) async throws -> String {
    guard let creds = credentials else { throw MatrixError.notConfigured }
    var components = URLComponents(
      url: creds.homeserver.appendingPathComponent("/_matrix/media/v3/upload"),
      resolvingAgainstBaseURL: false
    )
    components?.queryItems = [URLQueryItem(name: "filename", value: filename)]
    guard let url = components?.url else { throw MatrixError.invalidHomeserver(creds.homeserver.absoluteString) }

    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
    req.setValue(contentType, forHTTPHeaderField: "Content-Type")
    req.httpBody = data
    let json = try await perform(req)
    guard let mxc = json.string(at: "content_uri") else {
      throw MatrixError.decoding("upload sans content_uri")
    }
    return mxc
  }

  // MARK: - Média

  /// Télécharge un `mxc://` via l'endpoint authentifié (obligatoire depuis Matrix 1.11).
  func downloadMedia(mxcURI: String) async throws -> Data {
    guard let creds = credentials else { throw MatrixError.notConfigured }
    guard let (server, mediaID) = Self.parseMXC(mxcURI) else {
      throw MatrixError.decoding("URI média invalide : \(mxcURI)")
    }
    // v1 authentifié d'abord ; repli sur l'ancien endpoint pour les Synapse plus vieux.
    let paths = [
      "/_matrix/client/v1/media/download/\(Self.escape(server))/\(Self.escape(mediaID))",
      "/_matrix/media/v3/download/\(Self.escape(server))/\(Self.escape(mediaID))",
    ]
    var lastError: Error = MatrixError.transport("média indisponible")
    for path in paths {
      do {
        var req = URLRequest(url: creds.homeserver.appendingPathComponent(path))
        req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
          throw MatrixError.transport("réponse média inattendue")
        }
        if (200..<300).contains(http.statusCode) { return data }
        lastError = MatrixError.http(status: http.statusCode, errcode: nil, message: nil)
      } catch {
        lastError = error
      }
    }
    throw lastError
  }

  static func parseMXC(_ uri: String) -> (server: String, mediaID: String)? {
    guard uri.hasPrefix("mxc://") else { return nil }
    let rest = String(uri.dropFirst("mxc://".count))
    guard let slash = rest.firstIndex(of: "/") else { return nil }
    let server = String(rest[rest.startIndex..<slash])
    let mediaID = String(rest[rest.index(after: slash)...])
    guard !server.isEmpty, !mediaID.isEmpty else { return nil }
    return (server, mediaID)
  }

  // MARK: - Transport

  @discardableResult
  private func request(
    method: String,
    path: String,
    query: [URLQueryItem] = [],
    body: MatrixJSON? = nil,
    homeserverOverride: URL? = nil,
    authenticated: Bool = true
  ) async throws -> MatrixJSON {
    let data = try await rawRequest(
      method: method,
      path: path,
      query: query,
      body: body,
      homeserverOverride: homeserverOverride,
      authenticated: authenticated
    )
    if data.isEmpty { return .object([:]) }
    do {
      return try JSONDecoder().decode(MatrixJSON.self, from: data)
    } catch {
      throw MatrixError.decoding(path)
    }
  }

  private func rawRequest(
    method: String,
    path: String,
    query: [URLQueryItem] = [],
    body: MatrixJSON? = nil,
    homeserverOverride: URL? = nil,
    authenticated: Bool = true
  ) async throws -> Data {
    let base: URL
    if let homeserverOverride {
      base = homeserverOverride
    } else if let creds = credentials {
      base = creds.homeserver
    } else {
      throw MatrixError.notConfigured
    }

    var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
    if !query.isEmpty { components?.queryItems = query }
    guard let url = components?.url else {
      throw MatrixError.invalidHomeserver(base.absoluteString)
    }

    var req = URLRequest(url: url)
    req.httpMethod = method
    if authenticated {
      guard let token = credentials?.accessToken else { throw MatrixError.notConfigured }
      req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    if let body {
      req.setValue("application/json", forHTTPHeaderField: "Content-Type")
      req.httpBody = try? JSONEncoder().encode(body)
    }
    return try await performRaw(req)
  }

  private func perform(_ request: URLRequest) async throws -> MatrixJSON {
    let data = try await performRaw(request)
    if data.isEmpty { return .object([:]) }
    guard let json = try? JSONDecoder().decode(MatrixJSON.self, from: data) else {
      throw MatrixError.decoding(request.url?.path ?? "?")
    }
    return json
  }

  private func performRaw(_ request: URLRequest) async throws -> Data {
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch {
      throw MatrixError.transport(error.localizedDescription)
    }
    guard let http = response as? HTTPURLResponse else {
      throw MatrixError.transport("réponse HTTP inattendue")
    }
    guard (200..<300).contains(http.statusCode) else {
      let json = try? JSONDecoder().decode(MatrixJSON.self, from: data)
      throw MatrixError.http(
        status: http.statusCode,
        errcode: json?.string(at: "errcode"),
        message: json?.string(at: "error")
      )
    }
    return data
  }

  static func escape(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~")))
      ?? value
  }

  static func mimeType(for url: URL) -> String {
    switch url.pathExtension.lowercased() {
    case "jpg", "jpeg": "image/jpeg"
    case "png": "image/png"
    case "gif": "image/gif"
    case "heic": "image/heic"
    case "webp": "image/webp"
    case "mp4", "m4v": "video/mp4"
    case "mov": "video/quicktime"
    case "pdf": "application/pdf"
    default: "application/octet-stream"
    }
  }
}
