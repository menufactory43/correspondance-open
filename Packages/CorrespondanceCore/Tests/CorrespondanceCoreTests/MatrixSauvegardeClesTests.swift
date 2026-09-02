@testable import CorrespondanceMatrixClient
import XCTest

/// Ce que la sauvegarde des clés doit garantir **avant** de toucher au réseau.
final class MatrixSauvegardeClesTests: XCTestCase {

  /// Le sel et le nombre de tours partent dans `auth_data`, sinon la phrase ne
  /// redonne pas la même clé ailleurs — et la sauvegarde devient un coffre dont
  /// on a jeté la serrure.
  func testLAuthDataPorteLeSelEtLesTours() throws {
    let cle = MatrixCleDeSauvegarde(
      clePublique: "PUB", signatures: ["@moi:s": ["ed25519:A": "sig"]],
      sel: "SEL", tours: 500_000)
    let auth = cle.authData
    XCTAssertEqual(auth.string(at: "public_key"), "PUB")
    XCTAssertEqual(auth.string(at: "private_key_salt"), "SEL")
    XCTAssertEqual(auth.value(at: "private_key_iterations")?.intValue, 500_000)
    XCTAssertEqual(auth.string(at: "private_key_algorithm"), "m.pbkdf2")
    XCTAssertEqual(auth.string(at: "signatures.@moi:s.ed25519:A"), "sig")
  }

  /// Une clé qui ne vient pas d'une phrase ne doit pas prétendre le contraire :
  /// publier un sel absent ferait échouer chaque appareil neuf, en silence.
  func testSansPhrasePasDeSelDansLAuthData() {
    let auth = MatrixCleDeSauvegarde(clePublique: "PUB").authData
    XCTAssertNil(auth.value(at: "private_key_salt"))
    XCTAssertNil(auth.value(at: "private_key_algorithm"))
  }

  /// Le corps de `keys/device_signing/upload` porte les trois clés, et les
  /// porte **en JSON**, pas en chaîne : la machine les rend sérialisées.
  func testLeCorpsDeTeleversementDeplieLesTroisCles() {
    let amorce = MatrixAmorceSignatures(
      cleMaitresse: #"{"user_id":"@moi:s","usage":["master"],"keys":{"ed25519:M":"m"}}"#,
      cleSelfSigning: #"{"keys":{"ed25519:S":"s"}}"#,
      cleUserSigning: #"{"keys":{"ed25519:U":"u"}}"#,
      requetes: [])
    let corps = amorce.corpsDeTeleversement
    XCTAssertEqual(corps.string(at: "master_key.keys.ed25519:M"), "m")
    XCTAssertEqual(corps.string(at: "self_signing_key.keys.ed25519:S"), "s")
    XCTAssertEqual(corps.string(at: "user_signing_key.keys.ed25519:U"), "u")
  }

  /// Un appareil signé par la clé croisée est « vérifié » ; un appareil marqué
  /// à la main ne l'est que **sur cet appareil**, et l'écran doit le dire.
  func testTroisEtatsDAppareilEtLeurPhrase() {
    XCTAssertEqual(MatrixAppareil(deviceID: "A", verifieParSignature: true).etatFR, "vérifié")
    XCTAssertEqual(
      MatrixAppareil(deviceID: "B", deConfianceLocalement: true).etatFR,
      "de confiance sur cet appareil")
    XCTAssertEqual(MatrixAppareil(deviceID: "C").etatFR, "non vérifié")
  }

  /// La ligne des réglages ne doit jamais dire « sauvegarde : faite » quand il
  /// n'y a pas de version.
  func testLaLigneDesReglagesDitLesTroisChoses() {
    XCTAssertEqual(MatrixEtatChiffrement().resumeFR, "chiffrement : inactif")
    XCTAssertEqual(
      MatrixEtatChiffrement(actif: true).resumeFR,
      "chiffrement : actif · cet appareil : non vérifié · sauvegarde : aucune")
    XCTAssertEqual(
      MatrixEtatChiffrement(actif: true, appareilVerifie: true, sauvegardeVersion: "12").resumeFR,
      "chiffrement : actif · cet appareil : vérifié · sauvegarde : faite")
  }

  /// Un appareil qui détient les trois clés privées peut signer les autres.
  func testLesTroisClesFontUnAppareilQuiPeutVerifier() {
    XCTAssertTrue(
      MatrixEtatSignatures(maitresse: true, selfSigning: true, userSigning: true).complet)
    XCTAssertFalse(
      MatrixEtatSignatures(maitresse: true, selfSigning: false, userSigning: true).complet)
  }

  /// Une requête de sauvegarde sans version ne doit pas partir : le serveur
  /// répondrait à côté, et rien ne serait sauvegardé.
  func testUneRequeteDeSauvegardeSansVersionEstUneErreur() async {
    let client = MatrixClient(credentials: nil)
    let requete = MatrixCryptoRequest(id: "1", kind: .keysBackup, body: "{}")
    do {
      _ = try await client.poster(requete)
      XCTFail("une sauvegarde sans version doit être refusée avant l'envoi")
    } catch let erreur as MatrixError {
      XCTAssertTrue(
        erreur.localizedDescription.contains("version"), erreur.localizedDescription)
    } catch {
      XCTFail("erreur inattendue : \(error)")
    }
  }
}
