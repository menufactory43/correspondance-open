import Foundation

/// Client Matrix Client-Server v3 en REST pur (`URLSession`). Pas de SDK, pas d'E2EE :
/// homeserver privé sur Tailscale, salons de bridge non chiffrés.
public actor MatrixClient {
  private var credentials: MatrixCredentials?
  private let session: URLSession
  /// `txnId` déjà consommés — un renvoi du même identifiant ne doit pas dupliquer le message.
  private var ledger = MatrixTransactionLedger()

  public init(credentials: MatrixCredentials? = nil) {
    self.credentials = credentials
    let config = URLSessionConfiguration.ephemeral
    // Le long-poll /sync tient 30 s côté serveur : la marge évite les faux timeouts.
    config.timeoutIntervalForRequest = 60
    config.timeoutIntervalForResource = 120
    config.waitsForConnectivity = false
    session = URLSession(configuration: config)
  }

  public var currentCredentials: MatrixCredentials? { credentials }
  public var isConfigured: Bool { credentials != nil }

  public func setCredentials(_ value: MatrixCredentials?) {
    credentials = value
  }

  // MARK: - Session

  /// `POST /login` — renvoie la session, à charge de l'appelant de la persister.
  public func login(homeserver: URL, user: String, password: String) async throws -> MatrixCredentials {
    let body: [String: MatrixJSON] = [
      "type": .string("m.login.password"),
      "identifier": .object(["type": .string("m.id.user"), "user": .string(user)]),
      "password": .string(password),
      "initial_device_display_name": .string(Platform.deviceDisplayName),
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

  public func whoami() async throws -> String {
    let json = try await request(method: "GET", path: "/_matrix/client/v3/account/whoami")
    guard let userID = json.string(at: "user_id") else {
      throw MatrixError.decoding("whoami sans user_id")
    }
    return userID
  }

  public func logout() async {
    _ = try? await request(method: "POST", path: "/_matrix/client/v3/logout", body: .object([:]))
    credentials = nil
  }

  /// Versions supportées — sert de test de joignabilité avant d'écrire un mot de passe.
  public func serverVersions(homeserver: URL) async throws -> [String] {
    let json = try await request(
      method: "GET",
      path: "/_matrix/client/versions",
      homeserverOverride: homeserver,
      authenticated: false
    )
    return json["versions"]?.arrayValue?.compactMap(\.stringValue) ?? []
  }

  // MARK: - Sync

  public func sync(
    since: String?,
    timeoutMilliseconds: Int = 30_000,
    filter: String? = nil
  ) async throws -> MatrixSyncResponse {
    var items = [
      URLQueryItem(name: "timeout", value: String(timeoutMilliseconds)),
      // Sans `since`, on veut l'état complet mais peu d'historique : le backfill du bridge fera le reste.
      URLQueryItem(name: "full_state", value: since == nil ? "true" : "false"),
    ]
    if let since { items.append(URLQueryItem(name: "since", value: since)) }
    if let filter { items.append(URLQueryItem(name: "filter", value: filter)) }
    let data = try await rawRequest(method: "GET", path: "/_matrix/client/v3/sync", query: items)
    do {
      return try JSONDecoder().decode(MatrixSyncResponse.self, from: data)
    } catch {
      throw MatrixError.decoding("sync — \(error.localizedDescription)")
    }
  }

  // MARK: - Salons

  public func roomMessages(
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

  public func roomState(roomID: String, type: String, stateKey: String = "") async throws -> MatrixJSON {
    let suffix = stateKey.isEmpty ? "" : "/\(Self.escape(stateKey))"
    return try await request(
      method: "GET",
      path: "/_matrix/client/v3/rooms/\(Self.escape(roomID))/state/\(Self.escape(type))\(suffix)"
    )
  }

  public func joinedRooms() async throws -> [String] {
    let json = try await request(method: "GET", path: "/_matrix/client/v3/joined_rooms")
    return json["joined_rooms"]?.arrayValue?.compactMap(\.stringValue) ?? []
  }

  /// Rejoint un salon (invitation en attente, ou salon quitté encore joignable).
  @discardableResult
  public func join(roomID: String) async throws -> String {
    let json = try await request(method: "POST", path: "/_matrix/client/v3/join/\(Self.escape(roomID))", body: .object([:]))
    return json.string(at: "room_id") ?? roomID
  }

  /// Quitte un salon. Côté pont, quitter le portail d'un groupe revient à quitter
  /// le groupe sur le réseau distant — c'est ainsi qu'on remplace `quitGroup`.
  public func leave(roomID: String) async throws {
    _ = try await request(
      method: "POST",
      path: "/_matrix/client/v3/rooms/\(Self.escape(roomID))/leave",
      body: .object([:])
    )
  }

  /// Crée un DM (invitation + `is_direct`). Utilisé pour le salon de gestion du bot.
  public func createDM(with userID: String) async throws -> String {
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

  /// Un salon privé dont je suis le seul membre — la note à soi. Aucune
  /// invitation : personne d'autre n'y entre, et rien n'est chiffré (le
  /// Relais est privé, cf. ADR 0001).
  public func createSelfRoom(name: String) async throws -> String {
    let body: MatrixJSON = .object([
      "preset": .string("private_chat"),
      "name": .string(name),
      "visibility": .string("private"),
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
  public func sendText(
    roomID: String,
    body text: String,
    replyToEventID: String? = nil,
    replyFallback: (sender: String, text: String)? = nil,
    transactionID: String = UUID().uuidString
  ) async throws -> String? {
    guard !ledger.isUsed(transactionID) else { return nil }
    var content: [String: MatrixJSON] = [
      "msgtype": .string("m.text"),
      "body": .string(text),
    ]
    if let replyToEventID {
      content["m.relates_to"] = .object([
        "m.in_reply_to": .object(["event_id": .string(replyToEventID)])
      ])
      // Repli de citation : les clients qui ne comprennent pas `m.in_reply_to`
      // (et le bridge, pour composer la citation WhatsApp) lisent le corps.
      if let replyFallback {
        content["body"] = .string("> <\(replyFallback.sender)> \(replyFallback.text)\n\n\(text)")
      }
    }
    let json = try await request(
      method: "PUT",
      path: "/_matrix/client/v3/rooms/\(Self.escape(roomID))/send/m.room.message/\(Self.escape(transactionID))",
      body: .object(content)
    )
    ledger.markUsed(transactionID)
    return json.string(at: "event_id")
  }

  /// Modifier un message déjà envoyé (MSC2676, `m.replace`).
  ///
  /// Trois morceaux obligatoires : le `body` de repli, préfixé d'une étoile,
  /// pour les clients qui ignorent la modification ; `m.new_content`, le vrai
  /// nouveau texte ; et la relation qui désigne la cible. Les ponts mautrix la
  /// traduisent en modification chez WhatsApp et Signal.
  @discardableResult
  public func sendEdit(
    roomID: String,
    targetEventID: String,
    newText: String,
    transactionID: String = UUID().uuidString
  ) async throws -> String? {
    guard !ledger.isUsed(transactionID) else { return nil }
    let json = try await request(
      method: "PUT",
      path: "/_matrix/client/v3/rooms/\(Self.escape(roomID))/send/m.room.message/\(Self.escape(transactionID))",
      body: .object([
        "msgtype": .string("m.text"),
        "body": .string("* \(newText)"),
        "m.new_content": .object([
          "msgtype": .string("m.text"),
          "body": .string(newText),
        ]),
        "m.relates_to": .object([
          "rel_type": .string("m.replace"),
          "event_id": .string(targetEventID),
        ]),
      ])
    )
    ledger.markUsed(transactionID)
    return json.string(at: "event_id")
  }

  /// `m.reaction` : une annotation sur un event existant.
  /// mautrix-whatsapp la relaie dans les deux sens (un seul emoji par personne).
  @discardableResult
  public func sendReaction(
    roomID: String,
    targetEventID: String,
    key: String,
    transactionID: String = UUID().uuidString
  ) async throws -> String? {
    let json = try await request(
      method: "PUT",
      path: "/_matrix/client/v3/rooms/\(Self.escape(roomID))/send/m.reaction/\(Self.escape(transactionID))",
      body: .object([
        "m.relates_to": .object([
          "rel_type": .string("m.annotation"),
          "event_id": .string(targetEventID),
          "key": .string(key),
        ])
      ])
    )
    return json.string(at: "event_id")
  }

  /// `POST /rooms/{id}/receipt/m.read/{eventId}` — marque le fil lu jusqu'à cet event.
  ///
  /// mautrix-whatsapp l'écoute par les transactions applicatives (MSC2409,
  /// `ephemeral_events: true` par défaut) : **aucun double puppeting n'est requis**,
  /// et il marque tout l'intervalle, pas seulement le dernier message.
  public func sendReadReceipt(roomID: String, eventID: String) async throws {
    _ = try await request(
      method: "POST",
      path: "/_matrix/client/v3/rooms/\(Self.escape(roomID))/receipt/m.read/\(Self.escape(eventID))",
      body: .object([:])
    )
  }

  /// `PUT /rooms/{r}/typing/{u}` — dire qu'on écrit, ou qu'on a fini.
  ///
  /// `timeout` est la durée pendant laquelle le serveur tient l'information
  /// pour vraie sans nouvelle nouvelle : on le renouvelle tant qu'on tape, et
  /// on envoie `typing: false` dès qu'on s'arrête (envoi, champ vidé, fil
  /// quitté) plutôt que de laisser expirer.
  public func sendTyping(roomID: String, isTyping: Bool, timeoutMilliseconds: Int = 20_000) async throws {
    let user = try userID()
    var content: [String: MatrixJSON] = ["typing": .bool(isTyping)]
    if isTyping { content["timeout"] = .number(Double(timeoutMilliseconds)) }
    _ = try await request(
      method: "PUT",
      path: "/_matrix/client/v3/rooms/\(Self.escape(roomID))/typing/\(Self.escape(user))",
      body: .object(content)
    )
  }

  /// Retire un event — c'est ainsi qu'on retire une réaction.
  @discardableResult
  public func redact(
    roomID: String,
    eventID: String,
    transactionID: String = UUID().uuidString
  ) async throws -> String? {
    let json = try await request(
      method: "PUT",
      path: "/_matrix/client/v3/rooms/\(Self.escape(roomID))/redact/\(Self.escape(eventID))/\(Self.escape(transactionID))",
      body: .object([:])
    )
    return json.string(at: "event_id")
  }

  /// Upload puis event `m.image` (ou `m.file` si le type n'est pas une image).
  @discardableResult
  public func sendAttachment(
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

  // MARK: - Sondages (MSC3381)

  /// Ma voix sur un sondage. Une réponse **remplace** la précédente : c'est le
  /// dernier `poll.response` de chacun qui compte, pas leur somme.
  ///
  /// Le type d'event est celui sous lequel le sondage est arrivé — répondre en
  /// `m.poll.response` à un sondage `org.matrix.msc3381.poll.start` produirait
  /// une voix que personne ne rattacherait à rien.
  @discardableResult
  public func sendPollResponse(
    roomID: String,
    pollEventID: String,
    answerIDs: [String],
    responseType: String = PollEventTypes.responseUnstable,
    transactionID: String = UUID().uuidString
  ) async throws -> String? {
    let json = try await request(
      method: "PUT",
      path: "/_matrix/client/v3/rooms/\(Self.escape(roomID))/send/\(Self.escape(responseType))/\(Self.escape(transactionID))",
      body: .object([
        "m.relates_to": .object([
          "rel_type": .string("m.reference"),
          "event_id": .string(pollEventID),
        ]),
        responseType: .object(["answers": .array(answerIDs.map { .string($0) })]),
      ])
    )
    return json.string(at: "event_id")
  }

  /// Poser un sondage. Le repli texte (`body`) est obligatoire : c'est ce que
  /// lisent les clients — et les réseaux — qui ne connaissent pas MSC3381.
  @discardableResult
  public func sendPollStart(
    roomID: String,
    question: String,
    answers: [String],
    maxSelections: Int = 1,
    startType: String = PollEventTypes.startUnstable,
    transactionID: String = UUID().uuidString
  ) async throws -> String? {
    guard !ledger.isUsed(transactionID) else { return nil }
    let cleaned = answers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    guard !cleaned.isEmpty else { throw MatrixError.decoding("un sondage sans réponse") }
    let textKey = startType == PollEventTypes.startStable
      ? PollEventTypes.textStable
      : PollEventTypes.textUnstable
    let fallback = ([question] + cleaned.enumerated().map { "\($0.offset + 1). \($0.element)" })
      .joined(separator: "\n")
    let json = try await request(
      method: "PUT",
      path: "/_matrix/client/v3/rooms/\(Self.escape(roomID))/send/\(Self.escape(startType))/\(Self.escape(transactionID))",
      body: .object([
        startType: .object([
          "kind": .string("org.matrix.msc3381.poll.disclosed"),
          "max_selections": .number(Double(max(maxSelections, 1))),
          "question": .object([textKey: .string(question)]),
          "answers": .array(cleaned.enumerated().map { index, text in
            .object(["id": .string("r\(index)"), textKey: .string(text)])
          }),
        ]),
        textKey: .string(fallback),
        "body": .string(fallback),
      ])
    )
    ledger.markUsed(transactionID)
    return json.string(at: "event_id")
  }

  /// Un **message vocal** : le même `m.audio` qu'un fichier audio, plus les
  /// deux clés qui disent « quelqu'un a parlé » (MSC3245) et à quoi ça
  /// ressemble (MSC1767). C'est ce que les ponts mautrix attendent pour
  /// produire un vocal — et non une pièce jointe — sur WhatsApp et Signal.
  @discardableResult
  public func sendVoiceMessage(
    roomID: String,
    fileURL: URL,
    voice: VoiceNote,
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
    let millis = Double(Int((voice.duration * 1000).rounded()))
    let json = try await request(
      method: "PUT",
      path: "/_matrix/client/v3/rooms/\(Self.escape(roomID))/send/m.room.message/\(Self.escape(transactionID))",
      body: .object([
        "msgtype": .string("m.audio"),
        "body": .string(filename),
        "url": .string(mxc),
        "info": .object([
          "mimetype": .string(mime),
          "size": .number(Double(data.count)),
          "duration": .number(millis),
        ]),
        VoiceNoteKeys.voice: .object([:]),
        VoiceNoteKeys.audio: .object([
          "duration": .number(millis),
          "waveform": .array(voice.encodedWaveform.map { .number(Double($0)) }),
        ]),
      ])
    )
    ledger.markUsed(transactionID)
    return json.string(at: "event_id")
  }

  public func upload(data: Data, filename: String, contentType: String) async throws -> String {
    guard let creds = credentials else { throw MatrixError.notConfigured }
    var components = URLComponents(url: creds.homeserver, resolvingAgainstBaseURL: false)
    var basePath = components?.percentEncodedPath ?? ""
    while basePath.hasSuffix("/") { basePath.removeLast() }
    components?.percentEncodedPath = basePath + "/_matrix/media/v3/upload"
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

  // MARK: - État de conversation (Relais)

  /// Le Relais est la source de vérité de l'état de conversation (ADR 0001) :
  /// épingles et archives en room tags, sourdine en push rule, brouillons,
  /// masquages et fusions en account data. Tout ce qui suit écrit ; la lecture
  /// se fait par `/sync` (`MatrixSyncParser.conversationState`).

  public static func tagPath(userID: String, roomID: String, tag: String) -> String {
    "/_matrix/client/v3/user/\(escape(userID))/rooms/\(escape(roomID))/tags/\(escape(tag))"
  }

  public static func roomAccountDataPath(userID: String, roomID: String, type: String) -> String {
    "/_matrix/client/v3/user/\(escape(userID))/rooms/\(escape(roomID))/account_data/\(escape(type))"
  }

  public static func accountDataPath(userID: String, type: String) -> String {
    "/_matrix/client/v3/user/\(escape(userID))/account_data/\(escape(type))"
  }

  public static func roomPushRulePath(roomID: String) -> String {
    "/_matrix/client/v3/pushrules/global/room/\(escape(roomID))"
  }

  /// Corps d'un `PUT` de tag. `order` absent = tag sans ordre, ce que nous
  /// écrivons toujours : l'inbox trie elle-même.
  public static func tagBody(order: Double?) -> MatrixJSON {
    guard let order else { return .object([:]) }
    return .object(["order": .number(order)])
  }

  /// Corps d'un `PUT` de push rule de salon. `actions: []` = muet.
  /// `["dont_notify"]` est déprécié depuis Matrix 1.7 : la liste vide dit la
  /// même chose et reste comprise des serveurs qui la traduisent encore.
  public static func mutePushRuleBody() -> MatrixJSON {
    .object(["actions": .array([])])
  }

  private func userID() throws -> String {
    guard let userID = credentials?.userID else { throw MatrixError.notConfigured }
    return userID
  }

  /// `PUT /user/{u}/rooms/{r}/tags/{tag}`.
  public func setRoomTag(roomID: String, tag: String, order: Double? = nil) async throws {
    let user = try userID()
    _ = try await request(
      method: "PUT",
      path: Self.tagPath(userID: user, roomID: roomID, tag: tag),
      body: Self.tagBody(order: order)
    )
  }

  /// `DELETE /user/{u}/rooms/{r}/tags/{tag}`.
  public func removeRoomTag(roomID: String, tag: String) async throws {
    let user = try userID()
    _ = try await request(
      method: "DELETE",
      path: Self.tagPath(userID: user, roomID: roomID, tag: tag)
    )
  }

  /// `PUT /user/{u}/rooms/{r}/account_data/{type}`.
  public func setRoomAccountData(roomID: String, type: String, content: MatrixJSON) async throws {
    let user = try userID()
    _ = try await request(
      method: "PUT",
      path: Self.roomAccountDataPath(userID: user, roomID: roomID, type: type),
      body: content
    )
  }

  /// `PUT /user/{u}/account_data/{type}`.
  public func setAccountData(type: String, content: MatrixJSON) async throws {
    let user = try userID()
    _ = try await request(
      method: "PUT",
      path: Self.accountDataPath(userID: user, type: type),
      body: content
    )
  }

  /// Muet côté Relais : plus aucune notification push pour ce salon.
  /// Démuter supprime la règle plutôt que de la réécrire — une règle « notifie »
  /// masquerait les règles d'ordre inférieur de l'utilisateur.
  public func setRoomPushRule(roomID: String, muted: Bool) async throws {
    if muted {
      _ = try await request(
        method: "PUT",
        path: Self.roomPushRulePath(roomID: roomID),
        body: Self.mutePushRuleBody()
      )
    } else {
      do {
        _ = try await request(method: "DELETE", path: Self.roomPushRulePath(roomID: roomID))
      } catch MatrixError.http(let status, _, _) where status == 404 {
        // Pas de règle à retirer : le salon n'était pas muet côté Relais.
      }
    }
  }

  // MARK: - Push (Sygnal → APNs)

  public static let pushersSetPath = "/_matrix/client/v3/pushers/set"

  /// L'`app_id` de l'iPhone. Il doit coïncider au caractère près avec la clé
  /// déclarée sous `apps:` dans `sygnal.yaml`, sinon Synapse appelle Sygnal
  /// pour rien (« no app configured »).
  public static let iOSPusherAppID = "com.correspondance.ios"

  /// `format: event_id_only` : la charge utile ne porte que `room_id` et
  /// `event_id`, jamais le texte. Le push RÉVEILLE, l'appareil lit — c'est la
  /// seule forme qui survivra à l'E2EE (décision 7 de PRODUCT.md).
  public static let eventIDOnlyFormat = "event_id_only"

  /// Corps d'un `POST /pushers/set`.
  ///
  /// `url` est celle que **Synapse** voit — `http://sygnal:5000/…`, un nom de
  /// service Docker qui ne résout que sur son réseau. Jamais une adresse que
  /// l'iPhone saurait joindre : il n'a rien à y faire.
  ///
  /// `append: false` : déclarer le pusher remplace celui du même couple
  /// (`app_id`, `pushkey`) au lieu de l'empiler. Un jeton APNs qui tourne
  /// laisserait sinon derrière lui autant de pushers morts que de rotations.
  public static func pusherBody(
    pushkey: String,
    sygnalURL: URL,
    appID: String = iOSPusherAppID,
    appDisplayName: String = "Correspondance",
    deviceDisplayName: String,
    lang: String = "fr"
  ) -> MatrixJSON {
    .object([
      "app_id": .string(appID),
      "app_display_name": .string(appDisplayName),
      "device_display_name": .string(deviceDisplayName),
      "pushkey": .string(pushkey),
      "kind": .string("http"),
      "lang": .string(lang),
      "append": .bool(false),
      "data": .object([
        "url": .string(sygnalURL.absoluteString),
        "format": .string(Self.eventIDOnlyFormat),
      ]),
    ])
  }

  /// Corps de suppression : le même couple (`app_id`, `pushkey`), `kind: null`.
  /// C'est ce que la déconnexion envoie — sans quoi le Relais continuerait de
  /// réveiller un téléphone qui n'a plus de session.
  public static func pusherRemovalBody(
    pushkey: String,
    appID: String = iOSPusherAppID
  ) -> MatrixJSON {
    .object([
      "app_id": .string(appID),
      "pushkey": .string(pushkey),
      "kind": .null,
    ])
  }

  /// Le jeton APNs tel que Sygnal l'attend : de l'hexadécimal minuscule, nu.
  public static func pushkey(fromAPNSToken token: Data) -> String {
    token.map { String(format: "%02x", $0) }.joined()
  }

  /// `POST /pushers/set` — déclare (ou remplace) le pusher de cet appareil.
  public func setPusher(
    pushkey: String,
    sygnalURL: URL,
    deviceDisplayName: String,
    appID: String = MatrixClient.iOSPusherAppID
  ) async throws {
    _ = try await request(
      method: "POST",
      path: Self.pushersSetPath,
      body: Self.pusherBody(
        pushkey: pushkey,
        sygnalURL: sygnalURL,
        appID: appID,
        deviceDisplayName: deviceDisplayName
      )
    )
  }

  /// `POST /pushers/set` avec `kind: null` — le Relais oublie cet appareil.
  public func removePusher(
    pushkey: String,
    appID: String = MatrixClient.iOSPusherAppID
  ) async throws {
    _ = try await request(
      method: "POST",
      path: Self.pushersSetPath,
      body: Self.pusherRemovalBody(pushkey: pushkey, appID: appID)
    )
  }

  public static func roomEventPath(roomID: String, eventID: String) -> String {
    "/_matrix/client/v3/rooms/\(escape(roomID))/event/\(escape(eventID))"
  }

  /// `GET /rooms/{r}/event/{e}` — un seul événement, par son identifiant.
  /// C'est tout ce dont l'extension de notification a besoin : le push lui
  /// donne le couple, elle va chercher le reste.
  public func roomEvent(roomID: String, eventID: String) async throws -> MatrixJSON {
    try await request(
      method: "GET",
      path: Self.roomEventPath(roomID: roomID, eventID: eventID)
    )
  }

  // MARK: - Média

  /// Télécharge un `mxc://` via l'endpoint authentifié (obligatoire depuis Matrix 1.11).
  public func downloadMedia(mxcURI: String) async throws -> Data {
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
        guard let url = Self.makeURL(base: creds.homeserver, path: path) else {
          throw MatrixError.invalidHomeserver(creds.homeserver.absoluteString)
        }
        var req = URLRequest(url: url)
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

  public static func parseMXC(_ uri: String) -> (server: String, mediaID: String)? {
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

    guard let url = Self.makeURL(base: base, path: path, query: query) else {
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

  /// Colle un chemin déjà percent-encodé (`escape`) au homeserver **sans** ré-encoder :
  /// `appendingPathComponent` transformerait `%21` en `%2521` et Synapse verrait un
  /// salon `%21…` inexistant (« User not in room »).
  public static func makeURL(base: URL, path: String, query: [URLQueryItem] = []) -> URL? {
    var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
    var basePath = components?.percentEncodedPath ?? ""
    while basePath.hasSuffix("/") { basePath.removeLast() }
    components?.percentEncodedPath = basePath + path
    if !query.isEmpty { components?.queryItems = query }
    return components?.url
  }

  public static func escape(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~")))
      ?? value
  }

  public static func mimeType(for url: URL) -> String {
    switch url.pathExtension.lowercased() {
    case "jpg", "jpeg": "image/jpeg"
    case "png": "image/png"
    case "gif": "image/gif"
    case "heic": "image/heic"
    case "webp": "image/webp"
    case "mp4", "m4v": "video/mp4"
    case "mov": "video/quicktime"
    case "pdf": "application/pdf"
    // Les vocaux : sans type audio, le pont range le fichier en pièce jointe.
    case "m4a", "aac": "audio/mp4"
    case "mp3": "audio/mpeg"
    case "ogg", "oga", "opus": "audio/ogg"
    case "wav": "audio/wav"
    case "caf": "audio/x-caf"
    default: "application/octet-stream"
    }
  }
}
