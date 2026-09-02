import Foundation

/// Ce que le **serveur** sait d'un appareil : son nom, sa dernière activité,
/// l'adresse d'où il a parlé la dernière fois.
///
/// C'est l'autre moitié de `MatrixAppareil`, qui vient de la machine crypto et
/// ne connaît que les clés. Les deux ne se recouvrent pas : la machine crypto
/// ignore quand un appareil s'est manifesté, et le serveur ignore s'il est
/// vérifié. L'écran des réglages a besoin des deux, donc `MatrixAppareilVu`
/// les recolle — par `deviceID`, la seule clé commune.
public struct MatrixAppareilServeur: Sendable, Equatable {
  public var deviceID: String
  public var nom: String?
  /// `last_seen_ts`, en millisecondes depuis l'époque. Synapse ne l'écrit
  /// qu'une fois par dix minutes (cf. la garde du second `cc`, commit
  /// `60c600a`) : une session vivante peut donc paraître vieille de dix
  /// minutes, et l'écran ne doit pas en conclure qu'elle dort.
  public var derniereActiviteMS: Int?
  public var derniereAdresse: String?

  public init(
    deviceID: String, nom: String? = nil, derniereActiviteMS: Int? = nil,
    derniereAdresse: String? = nil
  ) {
    self.deviceID = deviceID
    self.nom = nom
    self.derniereActiviteMS = derniereActiviteMS
    self.derniereAdresse = derniereAdresse
  }

  public var derniereActivite: Date? {
    derniereActiviteMS.map { Date(timeIntervalSince1970: Double($0) / 1000) }
  }
}

/// Un appareil du compte tel que l'écran le montre : ce que le serveur en
/// sait, plus ce que la machine crypto en sait.
public struct MatrixAppareilVu: Sendable, Equatable, Identifiable {
  public var deviceID: String
  public var nom: String?
  public var derniereActivite: Date?
  public var derniereAdresse: String?
  public var verifieParSignature: Bool
  public var deConfianceLocalement: Bool
  public var estMoi: Bool
  /// Vrai quand la machine crypto n'a rien à dire de cet appareil — parce
  /// qu'elle n'est pas branchée, ou qu'il n'a jamais publié de clés. « On ne
  /// sait pas » n'est pas « non vérifié », et l'écran doit pouvoir le dire.
  public var etatCryptoInconnu: Bool

  public var id: String { deviceID }

  public init(
    deviceID: String, nom: String? = nil, derniereActivite: Date? = nil,
    derniereAdresse: String? = nil, verifieParSignature: Bool = false,
    deConfianceLocalement: Bool = false, estMoi: Bool = false, etatCryptoInconnu: Bool = false
  ) {
    self.deviceID = deviceID
    self.nom = nom
    self.derniereActivite = derniereActivite
    self.derniereAdresse = derniereAdresse
    self.verifieParSignature = verifieParSignature
    self.deConfianceLocalement = deConfianceLocalement
    self.estMoi = estMoi
    self.etatCryptoInconnu = etatCryptoInconnu
  }

  /// Ce que l'écran affiche à droite du nom.
  public var etatFR: String {
    if estMoi && verifieParSignature { return "cet appareil · vérifié" }
    if estMoi { return "cet appareil" }
    if verifieParSignature { return "vérifié" }
    if deConfianceLocalement { return "de confiance sur cet appareil" }
    if etatCryptoInconnu { return "état inconnu" }
    return "non vérifié"
  }

  /// « il y a 3 min », « il y a 2 j », ou rien quand le serveur ne l'a jamais vu.
  public func activiteFR(maintenant: Date = Date()) -> String? {
    guard let derniereActivite else { return nil }
    let secondes = Int(maintenant.timeIntervalSince(derniereActivite))
    if secondes < 0 { return "à l'instant" }
    if secondes < 120 { return "à l'instant" }
    if secondes < 3600 { return "il y a \(secondes / 60) min" }
    if secondes < 86_400 { return "il y a \(secondes / 3600) h" }
    return "il y a \(secondes / 86_400) j"
  }

  /// Recolle les deux moitiés. L'ordre est celui de l'écran : cet appareil en
  /// premier, puis les plus récemment vus.
  public static func fusionner(
    serveur: [MatrixAppareilServeur],
    crypto: [MatrixAppareil],
    appareilCourant: String?
  ) -> [MatrixAppareilVu] {
    let parID = Dictionary(crypto.map { ($0.deviceID, $0) }, uniquingKeysWith: { a, _ in a })
    let vus = serveur.map { s -> MatrixAppareilVu in
      let c = parID[s.deviceID]
      return MatrixAppareilVu(
        deviceID: s.deviceID,
        nom: s.nom ?? c?.nom,
        derniereActivite: s.derniereActivite,
        derniereAdresse: s.derniereAdresse,
        verifieParSignature: c?.verifieParSignature ?? false,
        deConfianceLocalement: c?.deConfianceLocalement ?? false,
        estMoi: s.deviceID == appareilCourant,
        etatCryptoInconnu: c == nil
      )
    }
    return vus.sorted { a, b in
      if a.estMoi != b.estMoi { return a.estMoi }
      switch (a.derniereActivite, b.derniereActivite) {
      case let (x?, y?): return x > y
      case (nil, _?): return false
      case (_?, nil): return true
      case (nil, nil): return a.deviceID < b.deviceID
      }
    }
  }
}

/// Ce que « Déconnecter cet appareil » peut rencontrer : le serveur exige
/// presque toujours le mot de passe (interactive auth), et le dire est plus
/// utile qu'un « échec ».
public enum MatrixDeconnexionAppareil: Sendable, Equatable {
  case faite
  /// Le serveur veut une authentification : le mot de passe du compte.
  case motDePasseRequis(session: String)
}

extension MatrixClient {

  /// `GET /_matrix/client/v3/devices` — la liste que le serveur tient, la
  /// seule qui porte la dernière activité.
  public func appareilsDuServeur() async throws -> [MatrixAppareilServeur] {
    let reponse = try await request(method: "GET", path: "/_matrix/client/v3/devices")
    guard let liste = reponse["devices"]?.arrayValue else { return [] }
    return liste.compactMap { entree in
      guard let id = entree["device_id"]?.stringValue else { return nil }
      return MatrixAppareilServeur(
        deviceID: id,
        nom: entree["display_name"]?.stringValue,
        derniereActiviteMS: entree["last_seen_ts"]?.intValue,
        derniereAdresse: entree["last_seen_ip"]?.stringValue
      )
    }
  }

  /// La liste complète pour l'écran : le serveur, plus la machine crypto quand
  /// elle est branchée. Sans machine, on rend quand même la liste — un écran
  /// qui ne montre rien parce que le chiffrement est absent serait un mensonge
  /// de plus.
  public func appareilsAAfficher() async throws -> [MatrixAppareilVu] {
    let serveur = try await appareilsDuServeur()
    let crypto = (try? await appareilsDuCompte()) ?? []
    return MatrixAppareilVu.fusionner(
      serveur: serveur, crypto: crypto,
      appareilCourant: currentCredentials?.deviceID
    )
  }

  /// `DELETE /_matrix/client/v3/devices/{id}` — sans mot de passe d'abord,
  /// parce qu'un serveur peut ne rien demander ; avec, si le premier tour
  /// rend un 401 et sa session d'authentification.
  ///
  /// Le mot de passe ne part **que** sur demande du serveur : le proposer
  /// d'emblée l'enverrait à un serveur qui ne l'exigeait pas.
  public func deconnecterAppareil(_ deviceID: String, motDePasse: String? = nil) async throws
    -> MatrixDeconnexionAppareil
  {
    let chemin = "/_matrix/client/v3/devices/\(deviceID)"
    guard let userID = currentCredentials?.userID else { throw MatrixError.notConfigured }

    // Le premier tour, sans rien. Le `401` d'une authentification interactive
    // n'est pas une erreur : c'est le serveur qui demande le mot de passe, et
    // sa `session` arrive dans le corps — que `MatrixError.http` ne porte pas,
    // d'où `dernierCorpsDErreur`.
    let session: String
    do {
      _ = try await rawRequest(method: "DELETE", path: chemin, body: nil)
      return .faite
    } catch let MatrixError.http(status, _, _) where status == 401 {
      guard let defi = dernierCorpsDErreur?["session"]?.stringValue else { throw MatrixError.decoding(chemin) }
      session = defi
    }
    guard let motDePasse else { return .motDePasseRequis(session: session) }

    let auth: MatrixJSON = .object([
      "type": .string("m.login.password"),
      "session": .string(session),
      "identifier": .object(["type": .string("m.id.user"), "user": .string(userID)]),
      "password": .string(motDePasse),
    ])
    _ = try await rawRequest(method: "DELETE", path: chemin, body: .object(["auth": auth]))
    return .faite
  }
}
