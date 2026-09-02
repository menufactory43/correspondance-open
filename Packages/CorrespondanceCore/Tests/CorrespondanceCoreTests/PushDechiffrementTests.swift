import XCTest

@testable import CorrespondanceCore
@testable import CorrespondanceMatrixClient

/// Le chemin que l'extension de notification emprunte, éprouvé **hors
/// extension**.
///
/// Le simulateur ne réveille pas une `UNNotificationServiceExtension` : il n'y
/// a pas de push. Ce qui est testable, et ce qui casserait en silence, c'est le
/// morceau du milieu — un `m.room.encrypted` isolé, rendu en clair, sans
/// `/sync` et sans modèle.
final class PushDechiffrementTests: XCTestCase {

  func testUnEvenementChiffreIsoleEstRenduEnClair() async {
    let client = MatrixClient(credentials: nil)
    await client.setCrypto(MoteurDEssai(clair: #"{"type":"m.room.message","content":{"body":"salut"}}"#))
    let chiffre = MatrixJSON.object([
      "type": .string("m.room.encrypted"),
      "event_id": .string("$1"),
      "sender": .string("@alice:s"),
      "origin_server_ts": .number(1_700_000_000_000),
      "content": .object(["algorithm": .string("m.megolm.v1.aes-sha2")]),
    ])
    let clair = await client.dechiffrerEvenement(chiffre, salon: "!r:s")
    XCTAssertEqual(clair?.string(at: "content.body"), "salut")
    // L'enveloppe fait foi : la machine ne rend ni auteur ni horodatage, et une
    // notification sans expéditeur ne sait plus qui a écrit.
    XCTAssertEqual(clair?.string(at: "sender"), "@alice:s")
    XCTAssertEqual(clair?.string(at: "event_id"), "$1")
  }

  /// Clé manquante : on rend `nil`, pour que l'appelant **dise** que le message
  /// est chiffré au lieu d'afficher un « Nouveau message » qui ferait croire à
  /// un Relais injoignable.
  func testSansLaCleOnRendNilPlutotQueDeDeviner() async {
    let client = MatrixClient(credentials: nil)
    await client.setCrypto(MoteurDEssai(clair: nil))
    let chiffre = MatrixJSON.object([
      "type": .string("m.room.encrypted"), "content": .object([:]),
    ])
    let clair = await client.dechiffrerEvenement(chiffre, salon: "!r:s")
    XCTAssertNil(clair)
  }

  /// Un événement en clair traverse sans être touché — c'est le cas de tous les
  /// portails de ponts d'aujourd'hui.
  func testUnEvenementEnClairPasseTelQuel() async {
    let client = MatrixClient(credentials: nil)
    await client.setCrypto(MoteurDEssai(clair: nil))
    let evenement = MatrixJSON.object([
      "type": .string("m.room.message"), "content": .object(["body": .string("coucou")]),
    ])
    let sortie = await client.dechiffrerEvenement(evenement, salon: "!r:s")
    XCTAssertEqual(sortie?.string(at: "content.body"), "coucou")
  }

  /// Sans machine crypto — un binaire sans le drapeau — rien ne se passe, et
  /// surtout rien ne plante.
  func testSansMachineCryptoRienNeSePasse() async {
    let client = MatrixClient(credentials: nil)
    let sortie = await client.dechiffrerEvenement(
      .object(["type": .string("m.room.encrypted")]), salon: "!r:s")
    XCTAssertNil(sortie)
  }

  /// Le texte du repli doit nommer la vraie cause : le Relais a répondu, c'est
  /// la clé qui manque.
  func testLeRepliDitQueLeMessageEstChiffre() {
    XCTAssertNotEqual(PushNotification.messageChiffreNonLu, PushNotification.fallbackBody)
    XCTAssertTrue(PushNotification.messageChiffreNonLu.contains("chiffré"))
  }

  /// Sans groupe possible, le dossier partagé retombe sur celui de l'app :
  /// rien ne change et rien ne casse.
  func testSansGroupePossibleOnRetombeSurLeDossierDeLApp() {
    XCTAssertEqual(
      CorrespondanceHome.sharedDirectory(groupePossible: false),
      CorrespondanceHome.directory())
    XCTAssertFalse(CorrespondanceHome.partageDisponible(groupePossible: false))
  }

  /// Le garde qui a coûté une lecture attentive : sur macOS hors bac à sable,
  /// `containerURL` rend un chemin pour un identifiant **inventé**. S'y fier
  /// déplacerait le magasin de clés de l'app Mac et laisserait les clés
  /// existantes orphelines.
  func testUnConteneurDeGroupeNEstPasUnePreuveDEntitlementSurMac() {
    #if os(macOS)
      XCTAssertNotNil(
        FileManager.default.containerURL(
          forSecurityApplicationGroupIdentifier: "group.qui.nexiste.pas"),
        "si ce jour arrive où macOS refuse un groupe inventé, la garde de "
          + "CorrespondanceHome.groupePossibleSurCettePlateforme peut se relâcher")
      XCTAssertFalse(
        CorrespondanceHome.groupePossibleSurCettePlateforme,
        "sur Mac, le partage par conteneur ne doit pas être tenté")
    #endif
  }
}

/// Une machine crypto qui ne chiffre rien : elle rend ce qu'on lui a dit de
/// rendre. Assez pour éprouver le branchement, sans XCFramework ni serveur.
private struct MoteurDEssai: MatrixCryptoEngine {
  var clair: String?

  func absorberSync(
    evenementsToDevice: [MatrixJSON], appareilsChanges: [String], appareilsPartis: [String],
    comptesCleUnique: [String: Int], clesDeSecoursInutilisees: [String]?, prochainLot: String
  ) async throws -> MatrixCryptoSyncResult { MatrixCryptoSyncResult() }
  func requetesSortantes() async throws -> [MatrixCryptoRequest] { [] }
  func marquerEnvoyee(id: String, genre: MatrixCryptoRequestKind, reponse: String) async throws {}
  func dechiffrer(evenementJSON: String, salon: String) async throws -> String {
    guard let clair else { throw MatrixError.decoding("clé absente") }
    return clair
  }
  func chiffrer(salon: String, type: String, contenuJSON: String) async throws -> String { "{}" }
  func sessionsManquantes(membres: [String]) async throws -> MatrixCryptoRequest? { nil }
  func partagerCleDeSalon(salon: String, membres: [String]) async throws -> [MatrixCryptoRequest] {
    []
  }
  func suivreUtilisateurs(_ utilisateurs: [String]) async throws {}
  func clesDIdentite() async -> [String: String] { [:] }
}
