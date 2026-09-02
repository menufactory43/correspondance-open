import Foundation

/// La sauvegarde des clés de salon et la vérification d'appareil — la seconde
/// moitié du chantier E.
///
/// **Pourquoi c'est un protocole à part** de `MatrixCryptoEngine** : le
/// déchiffrement du `/sync` marche sans rien de tout ça (phase 2), et un moteur
/// qui ne saurait que déchiffrer reste utile. Le client demande donc ces
/// capacités par un `as?`, pas par une obligation.
///
/// Comme pour `MatrixCryptoEngine`, **le moteur ne fait jamais de réseau** : il
/// rend de la matière, c'est `MatrixClient` qui l'envoie.
public protocol MatrixCryptoSauvegarde: MatrixCryptoEngine {

  // MARK: Sauvegarde des clés

  /// Dérive la clé de sauvegarde depuis une phrase. Sans sel, la machine en
  /// tire un au hasard et le rend : c'est ce sel-là qu'il faut publier dans
  /// `auth_data`, sinon **aucun autre appareil ne pourra jamais redériver la
  /// même clé** et la phrase ne servira à rien.
  func cleDeSauvegarde(phrase: String, sel: String?, tours: Int32?) async throws
    -> MatrixCleDeSauvegarde

  /// Allume la sauvegarde pour cette version : à partir de là, la machine
  /// produit des requêtes `keysBackup`.
  func activerSauvegarde(_ cle: MatrixCleDeSauvegarde, version: String) async throws

  /// Garde la clé **privée** dans le magasin local, pour ne pas redemander la
  /// phrase à chaque envoi.
  func retenirCleDeRecuperation(_ cle: MatrixCleDeSauvegarde, version: String) async throws

  /// La prochaine fournée de clés à téléverser, ou `nil` quand tout est
  /// sauvegardé.
  func requeteDeSauvegarde() async throws -> MatrixCryptoRequest?

  /// Ce que le serveur nous rend de `GET /room_keys/keys`, réimporté dans la
  /// machine. C'est **l'étape qui fait disparaître la limite « first known
  /// index 1 »** : un appareil neuf lit enfin ce qui précède sa naissance.
  func importerDepuisSauvegarde(clesJSON: String, version: String) async throws
    -> MatrixImportDeCles

  /// La sauvegarde est-elle allumée sur cet appareil ?
  func sauvegardeActive() async -> Bool
  /// La version que cet appareil sauvegarde, s'il en sauvegarde une.
  func versionSauvegardee() async -> String?

  // MARK: Vérification d'appareil

  /// Crée les trois clés de signature croisée (maîtresse, self-signing,
  /// user-signing) et rend ce qu'il faut téléverser.
  func amorcerSignaturesCroisees() async throws -> MatrixAmorceSignatures
  func verifierIdentite(userID: String) async throws -> MatrixCryptoRequest
  func identiteVerifiee(userID: String) async -> Bool
  /// Ce que cet appareil détient des trois clés privées.
  func etatDesSignatures() async -> MatrixEtatSignatures
  /// Signe un appareil avec notre clé self-signing : il devient vérifié pour
  /// tous nos appareils.
  func verifierAppareil(userID: String, deviceID: String) async throws -> MatrixCryptoRequest
  /// Les appareils d'un compte, tels que la machine les connaît.
  func appareils(de userID: String) async throws -> [MatrixAppareil]
  /// Les clés privées de signature croisée, pour les porter à un appareil neuf.
  func exporterClesDeSignature() async throws -> MatrixExportSignatures?
  func importerClesDeSignature(_ export: MatrixExportSignatures) async throws

  // MARK: Le coffre

  /// Scelle un secret avec une clé dérivée de la phrase (le même sel et le
  /// même nombre de tours que la sauvegarde des clés : **une seule phrase, une
  /// seule dérivation**, sinon l'utilisateur en aurait deux à retenir).
  func sceller(_ clair: Data, phrase: String, sel: String, tours: Int32) async throws -> Data
  func desceller(_ scelle: Data, phrase: String, sel: String, tours: Int32) async throws -> Data
}

/// Une clé de sauvegarde et ce qu'il faut publier pour qu'une phrase suffise à
/// la retrouver ailleurs.
public struct MatrixCleDeSauvegarde: Sendable, Equatable {
  public var clePublique: String
  public var signatures: [String: [String: String]]
  /// Le sel et le nombre de tours PBKDF. `nil` quand la clé ne vient pas d'une
  /// phrase — alors seule la clé en base58 permet de la retrouver.
  public var sel: String?
  public var tours: Int32?

  public init(
    clePublique: String, signatures: [String: [String: String]] = [:],
    sel: String? = nil, tours: Int32? = nil
  ) {
    self.clePublique = clePublique
    self.signatures = signatures
    self.sel = sel
    self.tours = tours
  }

  /// `auth_data` de `POST /room_keys/version`, tel que la spécification le veut.
  public var authData: MatrixJSON {
    var champs: [String: MatrixJSON] = [
      "public_key": .string(clePublique),
      "signatures": .object(signatures.mapValues { .object($0.mapValues(MatrixJSON.string)) }),
    ]
    if let sel, let tours {
      champs["private_key_salt"] = .string(sel)
      champs["private_key_iterations"] = .integer(Int(tours))
      champs["private_key_algorithm"] = .string("m.pbkdf2")
    }
    return .object(champs)
  }
}

public struct MatrixImportDeCles: Sendable, Equatable {
  public var importees: Int
  public var total: Int
  public init(importees: Int, total: Int) {
    self.importees = importees
    self.total = total
  }
}

public struct MatrixAmorceSignatures: Sendable, Equatable {
  public var cleMaitresse: String
  public var cleSelfSigning: String
  public var cleUserSigning: String
  /// La requête de signature à poster ensuite, et l'éventuel `keys/upload`.
  public var requetes: [MatrixCryptoRequest]
  public init(
    cleMaitresse: String, cleSelfSigning: String, cleUserSigning: String,
    requetes: [MatrixCryptoRequest]
  ) {
    self.cleMaitresse = cleMaitresse
    self.cleSelfSigning = cleSelfSigning
    self.cleUserSigning = cleUserSigning
    self.requetes = requetes
  }

  /// Le corps de `POST /keys/device_signing/upload`.
  public var corpsDeTeleversement: MatrixJSON {
    func lire(_ texte: String) -> MatrixJSON {
      (try? JSONDecoder().decode(MatrixJSON.self, from: Data(texte.utf8))) ?? .object([:])
    }
    return .object([
      "master_key": lire(cleMaitresse),
      "self_signing_key": lire(cleSelfSigning),
      "user_signing_key": lire(cleUserSigning),
    ])
  }
}

public struct MatrixEtatSignatures: Sendable, Equatable {
  public var maitresse: Bool
  public var selfSigning: Bool
  public var userSigning: Bool
  public init(maitresse: Bool, selfSigning: Bool, userSigning: Bool) {
    self.maitresse = maitresse
    self.selfSigning = selfSigning
    self.userSigning = userSigning
  }
  /// Cet appareil peut-il vérifier les autres ?
  public var complet: Bool { maitresse && selfSigning && userSigning }
}

public struct MatrixExportSignatures: Sendable, Equatable, Codable {
  public var maitresse: String?
  public var selfSigning: String?
  public var userSigning: String?
  public init(maitresse: String?, selfSigning: String?, userSigning: String?) {
    self.maitresse = maitresse
    self.selfSigning = selfSigning
    self.userSigning = userSigning
  }
}

/// Un appareil du compte, tel que l'écran « mes appareils » doit le montrer.
public struct MatrixAppareil: Sendable, Equatable {
  public var deviceID: String
  public var nom: String?
  public var clesEd25519: String?
  /// Vérifié par la signature croisée — le seul « vérifié » qui vaille pour
  /// les autres appareils.
  public var verifieParSignature: Bool
  /// Marqué de confiance à la main, sur cet appareil seulement.
  public var deConfianceLocalement: Bool
  public var estMoi: Bool

  public init(
    deviceID: String, nom: String? = nil, clesEd25519: String? = nil,
    verifieParSignature: Bool = false, deConfianceLocalement: Bool = false, estMoi: Bool = false
  ) {
    self.deviceID = deviceID
    self.nom = nom
    self.clesEd25519 = clesEd25519
    self.verifieParSignature = verifieParSignature
    self.deConfianceLocalement = deConfianceLocalement
    self.estMoi = estMoi
  }

  /// Ce que l'écran affiche, en une ligne.
  public var etatFR: String {
    if verifieParSignature { return "vérifié" }
    if deConfianceLocalement { return "de confiance sur cet appareil" }
    return "non vérifié"
  }
}

/// Ce que l'app sait du chiffrement, en une valeur — c'est la ligne des
/// réglages : « chiffrement : actif · cet appareil : vérifié · sauvegarde : faite ».
public struct MatrixEtatChiffrement: Sendable, Equatable {
  public var actif: Bool
  public var appareilVerifie: Bool
  public var sauvegardeVersion: String?
  public var appareilID: String?

  public init(
    actif: Bool = false, appareilVerifie: Bool = false, sauvegardeVersion: String? = nil,
    appareilID: String? = nil
  ) {
    self.actif = actif
    self.appareilVerifie = appareilVerifie
    self.sauvegardeVersion = sauvegardeVersion
    self.appareilID = appareilID
  }

  public var resumeFR: String {
    guard actif else { return "chiffrement : inactif" }
    return "chiffrement : actif · cet appareil : \(appareilVerifie ? "vérifié" : "non vérifié")"
      + " · sauvegarde : \(sauvegardeVersion == nil ? "aucune" : "faite")"
  }
}

// MARK: - Le pilotage REST

extension MatrixClient {

  var sauvegarde: MatrixCryptoSauvegarde? { cryptoEngine as? MatrixCryptoSauvegarde }

  /// La version de sauvegarde que le Relais détient, avec son `auth_data`.
  /// `nil` quand il n'y en a aucune (404, ce qui n'est pas une erreur).
  public func versionDeSauvegarde() async throws -> (version: String, authData: MatrixJSON)? {
    do {
      let json = try await request(method: "GET", path: "/_matrix/client/v3/room_keys/version")
      guard let version = json.string(at: "version") else { return nil }
      return (version, json["auth_data"] ?? .object([:]))
    } catch let erreur as MatrixError {
      if case .http(let status, _, _) = erreur, status == 404 { return nil }
      throw erreur
    }
  }

  /// **Crée** la sauvegarde depuis une phrase, et téléverse tout ce que la
  /// machine détient déjà. Rend la version.
  ///
  /// Le sel et le nombre de tours partent dans `auth_data` : sans eux, la
  /// phrase ne redonnerait pas la même clé sur un autre appareil, et la
  /// sauvegarde serait un coffre dont on aurait jeté la serrure.
  @discardableResult
  public func creerSauvegarde(phrase: String, remplacerLExistante: Bool = false) async throws
    -> String
  {
    guard let moteur = sauvegarde else {
      throw MatrixError.decoding("sauvegarde : pas de machine crypto branchée")
    }
    // Le Relais n'autorise à écrire que dans **la dernière** version créée. En
    // créer une seconde sans supprimer la première laisse donc l'ancienne
    // vivante mais figée, et les clés cesseraient de partir sans un mot. On
    // exige donc que le remplacement soit demandé.
    if let (existante, _) = try await versionDeSauvegarde() {
      guard remplacerLExistante else {
        throw MatrixError.decoding(
          "sauvegarde : ce compte en a déjà une (version \(existante)) — la rejoindre avec la phrase, "
            + "ou demander explicitement à la remplacer (l'ancienne devient illisible)")
      }
      // On les retire **toutes**, pas seulement celle que le Relais nous rend.
      // Continuwuity ne rend pas la plus récente à `GET /room_keys/version` —
      // vérifié : quatre versions existaient, il en a nommé une différente à
      // chaque tour, dans le désordre. Et il refuse d'écrire ailleurs que dans
      // « la plus récemment créée ». Une seule suppression laisse donc un
      // compte où la sauvegarde échoue à chaque envoi, sans un mot.
      for _ in 0..<20 {
        guard let (version, _) = try await versionDeSauvegarde() else { break }
        try await supprimerSauvegarde(version: version)
      }
    }
    let cle = try await moteur.cleDeSauvegarde(phrase: phrase, sel: nil, tours: nil)
    let reponse = try await request(
      method: "POST", path: "/_matrix/client/v3/room_keys/version",
      body: .object([
        "algorithm": .string(Self.algorithmeDeSauvegarde),
        "auth_data": cle.authData,
      ])
    )
    guard let version = reponse.string(at: "version") else {
      throw MatrixError.decoding("sauvegarde : le Relais n'a pas rendu de version")
    }
    try await moteur.activerSauvegarde(cle, version: version)
    try await moteur.retenirCleDeRecuperation(cle, version: version)
    try await sauvegarderLesCles()
    return version
  }

  /// Vide la file de sauvegarde : autant de `PUT /room_keys/keys` qu'il faut.
  /// Rend le nombre de fournées.
  @discardableResult
  public func sauvegarderLesCles(toursMax: Int = 20) async throws -> Int {
    guard let moteur = sauvegarde else { return 0 }
    var fournees = 0
    for _ in 0..<toursMax {
      guard let requete = try await moteur.requeteDeSauvegarde() else { break }
      let reponse = try await poster(requete)
      try await moteur.marquerEnvoyee(id: requete.id, genre: .keysBackup, reponse: reponse)
      fournees += 1
    }
    return fournees
  }

  /// **Rejoint** une sauvegarde existante avec la phrase, et réimporte tout.
  /// C'est le chemin d'un appareil neuf : il lit alors l'historique d'avant sa
  /// propre naissance, ce que la phase 2 ne savait pas faire.
  public func rejoindreSauvegarde(phrase: String) async throws -> MatrixImportDeCles {
    guard let moteur = sauvegarde else {
      throw MatrixError.decoding("sauvegarde : pas de machine crypto branchée")
    }
    guard let (version, authData) = try await versionDeSauvegarde() else {
      throw MatrixError.decoding("sauvegarde : ce Relais n'en héberge aucune")
    }
    guard let sel = authData.string(at: "private_key_salt"),
          let tours = authData.value(at: "private_key_iterations")?.intValue
    else {
      throw MatrixError.decoding(
        "sauvegarde : cette version n'a pas été faite depuis une phrase — il faut la clé en base58")
    }
    let cle = try await moteur.cleDeSauvegarde(phrase: phrase, sel: sel, tours: Int32(tours))
    guard cle.clePublique == authData.string(at: "public_key") else {
      // La phrase est fausse : on le dit **avant** de télécharger, plutôt que
      // de rendre zéro clé importée et de laisser croire à une sauvegarde vide.
      throw MatrixError.decoding("sauvegarde : cette phrase ne correspond pas à celle du Relais")
    }
    try await moteur.activerSauvegarde(cle, version: version)
    try await moteur.retenirCleDeRecuperation(cle, version: version)
    let clesJSON = try await rawRequest(
      method: "GET",
      path: "/_matrix/client/v3/room_keys/keys",
      query: [URLQueryItem(name: "version", value: version)], body: nil)
    let texte = String(data: clesJSON, encoding: .utf8) ?? "{}"
    return try await moteur.importerDepuisSauvegarde(clesJSON: texte, version: version)
  }

  /// Supprime une version de sauvegarde — pour les essais, et pour « repartir
  /// d'une phrase neuve ».
  public func supprimerSauvegarde(version: String) async throws {
    _ = try await rawRequest(
      method: "DELETE",
      path: "/_matrix/client/v3/room_keys/version/\(Self.escape(version))")
  }

  // MARK: Vérification

  /// Pose les trois clés de signature croisée sur le compte. À faire **une
  /// fois**, sur le premier appareil.
  public func amorcerSignaturesCroisees(motDePasse: String? = nil) async throws
    -> MatrixAmorceSignatures
  {
    guard let moteur = sauvegarde else {
      throw MatrixError.decoding("signatures croisées : pas de machine crypto branchée")
    }
    let amorce = try await moteur.amorcerSignaturesCroisees()
    try await televerserLesClesDeSignature(amorce.corpsDeTeleversement, motDePasse: motDePasse)
    for requete in amorce.requetes {
      let reponse = try await poster(requete)
      try await moteur.marquerEnvoyee(id: requete.id, genre: requete.kind, reponse: reponse)
    }
    return amorce
  }

  /// `POST /keys/device_signing/upload`, avec l'authentification interactive
  /// quand le serveur la réclame.
  ///
  /// **Le premier téléversement passe sans rien ; le second exige le mot de
  /// passe.** Un compte qui n'a pas encore de clés de signature les accepte
  /// telles quelles ; dès qu'il en a, remplacer la clé maîtresse serait
  /// remplacer l'identité du compte, et le serveur répond `401` avec un défi.
  /// La phase 2 n'avait vu que le premier cas, sur un compte vierge, et en
  /// avait conclu que la route « répond 200 ».
  private func televerserLesClesDeSignature(_ corps: MatrixJSON, motDePasse: String?) async throws {
    let chemin = "/_matrix/client/v3/keys/device_signing/upload"
    do {
      _ = try await rawRequest(method: "POST", path: chemin, body: corps)
      return
    } catch let erreur as MatrixError {
      guard case .http(let status, _, _) = erreur, status == 401 else { throw erreur }
      guard let motDePasse, let moi = await currentCredentials?.userID else {
        throw MatrixError.decoding(
          "signatures croisées : ce compte en a déjà, et les remplacer demande le mot de passe")
      }
      var avecAuth = corps.objectValue ?? [:]
      var auth: [String: MatrixJSON] = [
        "type": .string("m.login.password"),
        "password": .string(motDePasse),
        "identifier": .object(["type": .string("m.id.user"), "user": .string(moi)]),
      ]
      // La `session` du défi vient du corps du 401 — d'où `dernierCorpsDErreur`.
      if let session = dernierCorpsDErreur?.string(at: "session") {
        auth["session"] = .string(session)
      }
      avecAuth["auth"] = .object(auth)
      _ = try await rawRequest(method: "POST", path: chemin, body: .object(avecAuth))
    }
  }

  /// Signe un appareil : il devient vérifié pour tous les autres.
  public func verifierAppareil(userID: String, deviceID: String) async throws {
    guard let moteur = sauvegarde else {
      throw MatrixError.decoding("vérification : pas de machine crypto branchée")
    }
    let requete = try await moteur.verifierAppareil(userID: userID, deviceID: deviceID)
    let reponse = try await poster(requete)
    try await moteur.marquerEnvoyee(id: requete.id, genre: requete.kind, reponse: reponse)
  }

  /// Atteste l'identité d'un autre utilisateur — un agent — en la signant.
  ///
  /// Il faut d'abord **savoir** qui il est : sans `keys/query`, la machine ne
  /// connaît pas son identité et refuserait de signer un inconnu.
  public func verifierIdentite(userID: String) async throws {
    guard let moteur = sauvegarde else {
      throw MatrixError.decoding("vérification : pas de machine crypto branchée")
    }
    try await moteur.suivreUtilisateurs([userID])
    let requete = try await moteur.verifierIdentite(userID: userID)
    let reponse = try await poster(requete)
    try await moteur.marquerEnvoyee(id: requete.id, genre: requete.kind, reponse: reponse)
  }

  /// Avons-nous **nous-mêmes** de quoi signer ? Attester quelqu'un demande une
  /// clé user-signing ; sans elle la machine refuse, et le message qu'elle rend
  /// ne dit pas où est le manque.
  public func peutAttester() async -> Bool {
    guard let moteur = sauvegarde else { return false }
    return await moteur.etatDesSignatures().userSigning
  }

  /// Cette identité porte-t-elle déjà notre signature ? Silencieux : la question
  /// se pose à chaque ouverture des réglages, elle ne doit jamais lever.
  public func identiteVerifiee(userID: String) async -> Bool {
    guard let moteur = sauvegarde else { return false }
    try? await moteur.suivreUtilisateurs([userID])
    return await moteur.identiteVerifiee(userID: userID)
  }

  /// Les appareils du compte, pour l'écran qui les liste.
  public func appareilsDuCompte() async throws -> [MatrixAppareil] {
    guard let moteur = sauvegarde, let moi = await currentCredentials?.userID else { return [] }
    // Les clés des autres appareils viennent d'un `keys/query` : sans ce tour,
    // la machine ne connaît que le nôtre.
    try await moteur.suivreUtilisateurs([moi])
    await viderLesRequetesSortantes()
    return try await moteur.appareils(de: moi)
  }

  /// L'état à afficher dans les réglages, en un appel.
  public func etatDuChiffrement() async -> MatrixEtatChiffrement {
    guard cryptoEngine != nil else { return MatrixEtatChiffrement() }
    let appareil = await currentCredentials?.deviceID
    var etat = MatrixEtatChiffrement(actif: true, appareilID: appareil)
    guard let moteur = sauvegarde else { return etat }
    etat.sauvegardeVersion = await moteur.versionSauvegardee()
    // Deux façons d'être vérifié, et on retient les deux. Un appareil peut
    // porter la signature des autres (`crossSigningTrusted`), ou détenir
    // lui-même les clés privées de signature — c'est le cas de celui qui vient
    // de les reprendre du coffre, et il est alors vérifié *de fait*, même si le
    // `keys/query` n'a pas encore rapporté sa propre signature. Ne regarder que
    // la première ferait dire « non vérifié » à un appareil qui signe les autres.
    if await moteur.etatDesSignatures().complet {
      etat.appareilVerifie = true
    } else if let moi = await currentCredentials?.userID, let appareil,
       let mien = try? await moteur.appareils(de: moi).first(where: { $0.deviceID == appareil })
    {
      etat.appareilVerifie = mien.verifieParSignature
    }
    return etat
  }

  // MARK: Le coffre : porter les clés de signature à un appareil neuf

  /// Où le coffre vit : l'account data du compte, donc synchronisé par le
  /// Relais vers tous les appareils, et **illisible pour lui** — il ne détient
  /// pas la phrase.
  public static let typeDuCoffre = "fr.correspondance.coffre.v1"

  /// Dépose les clés privées de signature croisée, scellées par la phrase.
  ///
  /// **Ce n'est pas le stockage secret de la spécification (4S).** C'est notre
  /// propre coffre, au même endroit (l'account data) et avec la même propriété
  /// (le Relais ne peut pas l'ouvrir), mais Element ne saura pas le lire. Le
  /// dire ici plutôt que de laisser croire à de l'interopérabilité.
  public func deposerLesSignaturesDansLeCoffre(phrase: String) async throws {
    guard let moteur = sauvegarde else {
      throw MatrixError.decoding("coffre : pas de machine crypto branchée")
    }
    guard let (_, auth) = try await versionDeSauvegarde(),
          let sel = auth.string(at: "private_key_salt"),
          let tours = auth.value(at: "private_key_iterations")?.intValue
    else {
      throw MatrixError.decoding(
        "coffre : il faut d'abord une sauvegarde faite depuis une phrase — c'est elle qui porte le sel")
    }
    guard let export = try await moteur.exporterClesDeSignature() else {
      throw MatrixError.decoding("coffre : cet appareil n'a pas les clés de signature croisée")
    }
    let clair = try JSONEncoder().encode(export)
    let scelle = try await moteur.sceller(clair, phrase: phrase, sel: sel, tours: Int32(tours))
    try await setAccountData(
      type: Self.typeDuCoffre,
      content: .object([
        "algorithme": .string("hkdf-sha256+aes-gcm"),
        "scelle": .string(scelle.base64EncodedString()),
      ]))
  }

  /// Reprend les clés du coffre avec la phrase : cet appareil devient capable
  /// de se signer lui-même, donc **vérifié**, sans comparer d'émojis.
  public func reprendreLesSignaturesDuCoffre(phrase: String) async throws {
    guard let moteur = sauvegarde else {
      throw MatrixError.decoding("coffre : pas de machine crypto branchée")
    }
    guard let (_, auth) = try await versionDeSauvegarde(),
          let sel = auth.string(at: "private_key_salt"),
          let tours = auth.value(at: "private_key_iterations")?.intValue
    else {
      throw MatrixError.decoding("coffre : aucune sauvegarde faite depuis une phrase sur ce Relais")
    }
    guard let moi = await currentCredentials?.userID else { throw MatrixError.notConfigured }
    let coffre = try await request(
      method: "GET", path: Self.accountDataPath(userID: moi, type: Self.typeDuCoffre))
    guard let texte = coffre.string(at: "scelle"), let scelle = Data(base64Encoded: texte) else {
      throw MatrixError.decoding("coffre : rien de déposé sur ce compte")
    }
    let clair = try await moteur.desceller(scelle, phrase: phrase, sel: sel, tours: Int32(tours))
    let export = try JSONDecoder().decode(MatrixExportSignatures.self, from: clair)
    try await moteur.importerClesDeSignature(export)
    // Se signer soi-même : c'est ce qui fait passer cet appareil de « non
    // vérifié » à « vérifié » aux yeux de tous les autres.
    if let moi = await currentCredentials?.userID, let mon = await currentCredentials?.deviceID {
      _ = try? await appareilsDuCompte()
      try await verifierAppareil(userID: moi, deviceID: mon)
      // La signature ne se voit pas tant qu'un `keys/query` ne l'a pas
      // rapportée : sans ce second tour, l'appareil qui vient de se signer se
      // dirait « non vérifié » à lui-même — et l'écran mentirait.
      _ = try? await appareilsDuCompte()
    }
  }

  public static let algorithmeDeSauvegarde = "m.megolm_backup.v1.curve25519-aes-sha2"
}
