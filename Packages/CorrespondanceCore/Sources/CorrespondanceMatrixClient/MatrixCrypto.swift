import Foundation

/// La frontière entre le client REST et une machine crypto Olm/Megolm.
///
/// Le client Matrix de Correspondance est du Foundation pur : il compile sous
/// Linux, où `cc` vit. La machine crypto, elle, est un XCFramework Apple. Cette
/// frontière existe pour que l'un n'entraîne jamais l'autre : sans moteur
/// branché (`setCrypto(nil)`, le défaut), pas une ligne de chiffrement ne
/// s'exécute et le client se comporte exactement comme avant.
///
/// L'implémentation vit dans `CorrespondanceMatrixCrypto`, cible qui n'existe
/// que le drapeau `CORRESPONDANCE_CRYPTO=1` levé (voir `Package.swift`).
///
/// **Qui appelle qui** : le moteur ne fait *jamais* de réseau. Il rend des
/// requêtes à envoyer ; c'est `MatrixClient` qui les poste et lui rapporte la
/// réponse. Cette inversion évite le cycle « le client appelle le moteur qui
/// rappelle le client » et garde le moteur testable sans serveur.
public protocol MatrixCryptoEngine: Sendable {
  /// Ce que le serveur doit savoir de nos clés au premier `/sync`.
  func absorberSync(
    evenementsToDevice: [MatrixJSON],
    appareilsChanges: [String],
    appareilsPartis: [String],
    comptesCleUnique: [String: Int],
    clesDeSecoursInutilisees: [String]?,
    prochainLot: String
  ) async throws -> MatrixCryptoSyncResult

  /// Les requêtes que la machine veut voir partir (upload de clés, requête de
  /// clés, réclamation, to-device, signatures).
  func requetesSortantes() async throws -> [MatrixCryptoRequest]

  /// La réponse du serveur, rendue à la machine — sans quoi elle rejoue la
  /// même requête indéfiniment.
  func marquerEnvoyee(id: String, genre: MatrixCryptoRequestKind, reponse: String) async throws

  /// `m.room.encrypted` → l'event en clair, en JSON.
  func dechiffrer(evenementJSON: String, salon: String) async throws -> String

  /// Le contenu d'un `m.room.encrypted` à envoyer.
  func chiffrer(salon: String, type: String, contenuJSON: String) async throws -> String

  /// La requête `keys/claim` qui ouvre une session Olm 1:1 avec les appareils
  /// dont on n'en a pas encore. **À appeler avant tout partage de clé** : sans
  /// elle, la machine ne peut chiffrer la clé pour personne et envoie à la
  /// place un `m.room_key.withheld` — le message part, et l'autre appareil ne
  /// le lira jamais.
  func sessionsManquantes(membres: [String]) async throws -> MatrixCryptoRequest?

  /// Les to-device qui portent la clé du salon aux appareils des membres.
  /// **C'est l'étape du partage entre appareils** : sans elle, la seconde
  /// session ne lit rien.
  func partagerCleDeSalon(salon: String, membres: [String]) async throws -> [MatrixCryptoRequest]

  /// Les comptes dont on veut suivre les appareils.
  func suivreUtilisateurs(_ utilisateurs: [String]) async throws

  /// Notre paire de clés publiques — pour le journal et les preuves.
  func clesDIdentite() async -> [String: String]
}

/// Ce que la machine retire d'un `/sync` : les `to_device` qu'elle a lus (les
/// `m.room.encrypted` d'appareil à appareil rendus en clair) et les clés de
/// salon qu'elle en a extraites.
public struct MatrixCryptoSyncResult: Sendable {
  public var toDevice: [String]
  public var clesDeSalon: [String]

  public init(toDevice: [String] = [], clesDeSalon: [String] = []) {
    self.toDevice = toDevice
    self.clesDeSalon = clesDeSalon
  }
}

/// Le genre d'une requête, tel que la machine crypto le nomme quand on lui
/// rapporte la réponse.
public enum MatrixCryptoRequestKind: Sendable, Equatable {
  case keysUpload
  case keysQuery
  case keysClaim
  case toDevice
  case signatureUpload
  case keysBackup
  case roomMessage
}

/// Une requête que la machine crypto veut voir partir. Le corps est déjà en
/// JSON : la machine parle la même langue que l'API Matrix.
public struct MatrixCryptoRequest: Sendable, Equatable {
  public var id: String
  public var kind: MatrixCryptoRequestKind
  /// `m.room.encrypted`, `m.room_key_request`… pour un `toDevice`.
  public var eventType: String?
  public var body: String
  /// `keysQuery` ne donne pas de corps : il donne la liste des comptes.
  public var users: [String]
  /// La version de la sauvegarde, pour un `keysBackup`. **Sans elle, le
  /// `PUT /room_keys/keys` part sans `?version=` et le serveur répond
  /// `M_MISSING_PARAM`** : les clés ne sont jamais sauvegardées, et rien ne le
  /// dit côté client.
  public var version: String?

  public init(
    id: String, kind: MatrixCryptoRequestKind, eventType: String? = nil, body: String = "{}",
    users: [String] = [], version: String? = nil
  ) {
    self.id = id
    self.kind = kind
    self.eventType = eventType
    self.body = body
    self.users = users
    self.version = version
  }
}

/// Ce que le journal du `/sync` retient d'un tour de chiffrement — c'est la
/// preuve qu'on demande à la phase 2 : combien d'events chiffrés sont passés,
/// combien ont été lus, combien de clés de salon sont arrivées.
public struct MatrixCryptoJournal: Sendable, Equatable {
  public var evenementsChiffres = 0
  public var evenementsDechiffres = 0
  public var echecsDeDechiffrement = 0
  public var toDeviceRecus = 0
  public var clesDeSalonRecues = 0
  public var requetesEnvoyees: [String] = []

  public init() {}

  public var estVide: Bool {
    evenementsChiffres == 0 && toDeviceRecus == 0 && requetesEnvoyees.isEmpty
  }

  public var resume: String {
    "chiffrés \(evenementsChiffres) → lus \(evenementsDechiffres), échecs \(echecsDeDechiffrement)"
      + " · to_device \(toDeviceRecus), clés de salon \(clesDeSalonRecues)"
      + (requetesEnvoyees.isEmpty ? "" : " · requêtes " + requetesEnvoyees.joined(separator: ","))
  }
}

// MARK: - Le branchement dans le client

extension MatrixClient {

  /// Branche (ou débranche) la machine crypto. `nil` — le défaut — rend le
  /// client identique à celui d'avant la phase 2.
  public func setCrypto(_ engine: MatrixCryptoEngine?) {
    cryptoEngine = engine
  }

  public var chiffrementActif: Bool { cryptoEngine != nil }

  /// Le dernier tour de chiffrement, pour le journal.
  public var dernierJournalCrypto: MatrixCryptoJournal { journalCrypto }

  /// Ce que le client sait des salons chiffrés (alimenté par le `/sync` et par
  /// `marquerSalonChiffre`).
  public var salonsChiffres: Set<String> { salonsChiffresConnus }

  public func marquerSalonChiffre(_ roomID: String) {
    salonsChiffresConnus.insert(roomID)
  }

  /// Le salon porte-t-il un `m.room.encryption` ? Réponse mise en cache : un
  /// salon ne se déchiffre pas au milieu de sa vie.
  public func salonEstChiffre(_ roomID: String) async -> Bool {
    if salonsChiffresConnus.contains(roomID) { return true }
    if salonsClairsConnus.contains(roomID) { return false }
    do {
      let etat = try await roomState(roomID: roomID, type: "m.room.encryption")
      if etat.string(at: "algorithm") != nil {
        salonsChiffresConnus.insert(roomID)
        return true
      }
      salonsClairsConnus.insert(roomID)
      return false
    } catch {
      // 404 = pas de chiffrement. Toute autre erreur : on ne devine pas, on
      // considère le salon en clair — se tromper dans ce sens rend un message
      // lisible refusé par le serveur, pas un message en clair là où on
      // croyait chiffrer (le serveur refuse un `m.room.message` en clair dans
      // un salon chiffré… non : il l'accepte. D'où le cache, rafraîchi par le
      // `/sync` qui voit passer l'event d'état).
      salonsClairsConnus.insert(roomID)
      return false
    }
  }

  /// Déchiffre un `m.room.encrypted` isolé — celui qu'un push nomme, par
  /// exemple. Rend le clair, ou `nil` si la clé manque (ce qui doit se dire,
  /// pas se taire).
  ///
  /// Séparé du tour de `/sync` parce que l'extension de notification n'a pas de
  /// `/sync` : elle vit trente secondes, va chercher **un** événement et doit
  /// le lire.
  public func dechiffrerEvenement(_ evenement: MatrixJSON, salon: String) async -> MatrixJSON? {
    guard let moteur = cryptoEngine else { return nil }
    guard evenement.string(at: "type") == "m.room.encrypted" else { return evenement }
    guard let brut = try? JSONEncoder().encode(evenement),
          let texte = String(data: brut, encoding: .utf8),
          let clair = try? await moteur.dechiffrer(evenementJSON: texte, salon: salon),
          let json = try? JSONDecoder().decode(MatrixJSON.self, from: Data(clair.utf8))
    else { return nil }
    // Le clair de la machine n'a ni expéditeur ni horodatage : ils font foi
    // côté serveur, et c'est l'enveloppe qui les portait.
    var champs = json.objectValue ?? [:]
    for cle in ["sender", "event_id", "origin_server_ts", "room_id"] {
      if champs[cle] == nil, let valeur = evenement[cle] { champs[cle] = valeur }
    }
    return .object(champs)
  }

  // MARK: Le tour de chiffrement d'un /sync

  /// Absorbe la part chiffrement d'une réponse `/sync`, puis rend la réponse
  /// avec les `m.room.encrypted` remplacés par leur clair. Le reste du
  /// pipeline ne voit que des `m.room.message` ordinaires.
  func appliquerChiffrement(_ reponse: MatrixSyncResponse) async -> MatrixSyncResponse {
    guard let moteur = cryptoEngine else { return reponse }
    var journal = MatrixCryptoJournal()
    var sortie = reponse

    // 1. Ce que le serveur nous dit : to-device, appareils changés, clés à usage unique.
    let toDevice = reponse.toDevice?.events ?? []
    journal.toDeviceRecus = toDevice.count
    journalCryptoToDeviceBruts = toDevice.map {
      "type=\($0.string(at: "type") ?? "?") de=\($0.string(at: "sender") ?? "?") algo=\($0.string(at: "content.algorithm") ?? "?")"
    }
    do {
      let resultat = try await moteur.absorberSync(
        evenementsToDevice: toDevice,
        appareilsChanges: reponse.deviceLists?.changed ?? [],
        appareilsPartis: reponse.deviceLists?.left ?? [],
        comptesCleUnique: reponse.deviceOneTimeKeysCount ?? [:],
        clesDeSecoursInutilisees: reponse.deviceUnusedFallbackKeyTypes,
        prochainLot: reponse.nextBatch
      )
      journal.clesDeSalonRecues = resultat.clesDeSalon.count
      if !resultat.toDevice.isEmpty {
        journalCryptoToDevice = resultat.toDevice
      }
    } catch {
      journalCryptoErreur = "absorber le sync : \(error)"
    }

    // 2. Ce que la machine veut envoyer — jusqu'à ce qu'elle n'ait plus rien.
    journal.requetesEnvoyees = await viderLesRequetesSortantes()

    // 3. Les salons qui se déclarent chiffrés, vus dans l'état du /sync.
    for (roomID, salon) in reponse.rooms?.join ?? [:] {
      let evenements = (salon.state?.events ?? []) + (salon.timeline?.events ?? [])
      if evenements.contains(where: { $0.type == "m.room.encryption" && $0.stateKey != nil }) {
        salonsChiffresConnus.insert(roomID)
        salonsClairsConnus.remove(roomID)
      }
    }

    // 4. Le déchiffrement, en amont du pipeline.
    var salonsSortie = sortie.rooms?.join ?? [:]
    for (roomID, var salon) in salonsSortie {
      guard var evenements = salon.timeline?.events else { continue }
      var touche = false
      for index in evenements.indices where evenements[index].type == "m.room.encrypted" {
        journal.evenementsChiffres += 1
        guard let brut = Self.jsonDEvenement(evenements[index], roomID: roomID) else {
          journal.echecsDeDechiffrement += 1
          continue
        }
        do {
          let clair = try await moteur.dechiffrer(evenementJSON: brut, salon: roomID)
          if let remplace = Self.evenementDepuisClair(clair, original: evenements[index]) {
            evenements[index] = remplace
            journal.evenementsDechiffres += 1
            touche = true
          } else {
            journal.echecsDeDechiffrement += 1
          }
        } catch {
          // Clé pas encore reçue : l'event reste `m.room.encrypted`. Le
          // pipeline l'ignorera, et le prochain /sync qui apporte la clé le
          // rendra lisible — c'est le comportement voulu, pas une erreur.
          journal.echecsDeDechiffrement += 1
          journalCryptoErreur = "déchiffrer : \(error)"
        }
      }
      if touche {
        salon.timeline?.events = evenements
        salonsSortie[roomID] = salon
      }
    }
    if sortie.rooms != nil { sortie.rooms?.join = salonsSortie }

    journalCrypto = journal
    return sortie
  }

  /// Poste toutes les requêtes que la machine crypto réclame, et lui rapporte
  /// chaque réponse. Rend la liste des genres envoyés, pour le journal.
  @discardableResult
  func viderLesRequetesSortantes(toursMax: Int = 10) async -> [String] {
    guard let moteur = cryptoEngine else { return [] }
    var envoyees: [String] = []
    for _ in 0..<toursMax {
      let requetes: [MatrixCryptoRequest]
      do { requetes = try await moteur.requetesSortantes() } catch {
        journalCryptoErreur = "requêtes sortantes : \(error)"; break
      }
      if requetes.isEmpty { break }
      for requete in requetes {
        do {
          let reponse = try await poster(requete)
          try await moteur.marquerEnvoyee(id: requete.id, genre: requete.kind, reponse: reponse)
          envoyees.append(Self.nom(requete.kind))
        } catch {
          journalCryptoErreur = "\(Self.nom(requete.kind)) : \(error)"
        }
      }
    }
    return envoyees
  }

  /// La traduction « requête de la machine crypto » → « appel HTTP Matrix ».
  func poster(_ requete: MatrixCryptoRequest) async throws -> String {
    switch requete.kind {
    case .keysUpload:
      return try await posterJSON("POST", "/_matrix/client/v3/keys/upload", requete.body)
    case .keysQuery:
      let corps = MatrixJSON.object([
        "device_keys": .object(Dictionary(uniqueKeysWithValues: requete.users.map { ($0, MatrixJSON.array([])) })),
      ])
      return try await posterJSON("POST", "/_matrix/client/v3/keys/query", Self.texte(corps))
    case .keysClaim:
      return try await posterJSON("POST", "/_matrix/client/v3/keys/claim", requete.body)
    case .signatureUpload:
      return try await posterJSON("POST", "/_matrix/client/v3/keys/signatures/upload", requete.body)
    case .keysBackup:
      guard let version = requete.version else {
        throw MatrixError.decoding("sauvegarde des clés : la machine n'a pas donné de version")
      }
      // Même piège que `to_device` : la machine rend la carte des salons toute
      // nue, `/room_keys/keys` la veut sous `rooms`. Sans l'emballage,
      // `M_BAD_JSON: missing field rooms` — et pas une clé n'est sauvegardée.
      let salons = (try? JSONDecoder().decode(MatrixJSON.self, from: Data(requete.body.utf8))) ?? .object([:])
      return try await posterJSON(
        "PUT", "/_matrix/client/v3/room_keys/keys", Self.texte(.object(["rooms": salons])),
        query: [URLQueryItem(name: "version", value: version)])
    case .toDevice:
      // La machine crypto donne la **carte des destinataires** toute nue
      // (`{"@moi:…":{"APPAREIL":{…}}}`) ; `/sendToDevice` la veut sous la clé
      // `messages`. Sans cet emballage, Continuwuity répond
      // `M_BAD_JSON: missing field messages` — et la clé de salon ne part jamais.
      let type = requete.eventType ?? "m.room.encrypted"
      let messages = (try? JSONDecoder().decode(MatrixJSON.self, from: Data(requete.body.utf8))) ?? .object([:])
      let corps = Self.texte(.object(["messages": messages]))
      let chemin = "/_matrix/client/v3/sendToDevice/\(Self.escape(type))/\(Self.escape(requete.id))"
      return try await posterJSON("PUT", chemin, corps)
    case .roomMessage:
      // La machine ne nous en donne pas dans ce spike (verification par salon).
      return "{}"
    }
  }

  private func posterJSON(
    _ methode: String, _ chemin: String, _ corps: String, query: [URLQueryItem] = []
  ) async throws -> String {
    let json = (try? JSONDecoder().decode(MatrixJSON.self, from: Data(corps.utf8))) ?? .object([:])
    let data = try await rawRequest(method: methode, path: chemin, query: query, body: json)
    return data.isEmpty ? "{}" : (String(data: data, encoding: .utf8) ?? "{}")
  }

  // MARK: L'envoi dans un salon chiffré

  /// Chiffre un contenu pour un salon, après avoir porté la clé aux appareils
  /// des membres. Rend le contenu `m.room.encrypted` à envoyer.
  func chiffrerPourEnvoi(roomID: String, type: String, content: MatrixJSON) async throws -> MatrixJSON {
    guard let moteur = cryptoEngine else { return content }
    let membres = try await membresRejoints(roomID: roomID)
    try await moteur.suivreUtilisateurs(membres)
    // Les clés d'appareil des membres doivent être connues avant le partage :
    // `updateTrackedUsers` produit un `keysQuery` qu'il faut vider maintenant.
    await viderLesRequetesSortantes()
    // Les sessions Olm 1:1 d'abord — c'est l'étape qui manquait, et son absence
    // ne se voit qu'à l'autre bout, sous la forme d'un `m.room_key.withheld`.
    if let claim = try await moteur.sessionsManquantes(membres: membres) {
      let reponse = try await poster(claim)
      try await moteur.marquerEnvoyee(id: claim.id, genre: claim.kind, reponse: reponse)
    }
    let requetes = try await moteur.partagerCleDeSalon(salon: roomID, membres: membres)
    for requete in requetes {
      let reponse = try await poster(requete)
      try await moteur.marquerEnvoyee(id: requete.id, genre: requete.kind, reponse: reponse)
    }
    let chiffre = try await moteur.chiffrer(salon: roomID, type: type, contenuJSON: Self.texte(content))
    guard let json = try? JSONDecoder().decode(MatrixJSON.self, from: Data(chiffre.utf8)) else {
      throw MatrixError.decoding("contenu chiffré illisible")
    }
    return json
  }

  /// `GET /rooms/{id}/joined_members` — à qui la clé doit aller.
  public func membresRejoints(roomID: String) async throws -> [String] {
    let json = try await request(
      method: "GET",
      path: "/_matrix/client/v3/rooms/\(Self.escape(roomID))/joined_members"
    )
    return (json["joined"]?.objectValue?.keys).map { Array($0).sorted() } ?? []
  }

  // MARK: Outils

  static func nom(_ kind: MatrixCryptoRequestKind) -> String {
    switch kind {
    case .keysUpload: return "keys/upload"
    case .keysQuery: return "keys/query"
    case .keysClaim: return "keys/claim"
    case .toDevice: return "to_device"
    case .signatureUpload: return "signatures/upload"
    case .keysBackup: return "room_keys"
    case .roomMessage: return "room_message"
    }
  }

  static func texte(_ json: MatrixJSON) -> String {
    guard let data = try? JSONEncoder().encode(json) else { return "{}" }
    return String(data: data, encoding: .utf8) ?? "{}"
  }

  /// L'event tel que la machine crypto l'attend : le JSON complet, `room_id`
  /// compris.
  static func jsonDEvenement(_ evenement: MatrixEvent, roomID: String) -> String? {
    var champs: [String: MatrixJSON] = [
      "type": .string(evenement.type),
      "content": evenement.content ?? .object([:]),
      "room_id": .string(roomID),
    ]
    if let id = evenement.eventID { champs["event_id"] = .string(id) }
    if let sender = evenement.sender { champs["sender"] = .string(sender) }
    if let ts = evenement.originServerTS { champs["origin_server_ts"] = .number(ts) }
    return texte(.object(champs))
  }

  /// Le clair rendu par la machine, remis dans la coquille de l'event chiffré —
  /// on garde `event_id`, `sender` et l'horodatage du serveur, qui font foi.
  static func evenementDepuisClair(_ clairJSON: String, original: MatrixEvent) -> MatrixEvent? {
    guard let clair = try? JSONDecoder().decode(MatrixJSON.self, from: Data(clairJSON.utf8)),
          let type = clair.string(at: "type")
    else { return nil }
    return MatrixEvent(
      type: type,
      eventID: original.eventID,
      sender: original.sender,
      stateKey: original.stateKey,
      originServerTS: original.originServerTS,
      content: clair["content"] ?? .object([:]),
      redacts: original.redacts
    )
  }
}
