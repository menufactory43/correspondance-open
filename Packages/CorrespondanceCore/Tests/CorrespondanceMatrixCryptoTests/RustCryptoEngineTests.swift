import XCTest
import CorrespondanceMatrixClient

@testable import CorrespondanceMatrixCrypto

/// La machine crypto, sans réseau : ce qu'elle sait faire toute seule.
/// La preuve du partage de clés entre appareils, elle, demande un Relais —
/// elle est dans `docs/spike-un-clic/phase-2.md`, preuve B.
final class RustCryptoEngineTests: XCTestCase {

  private func moteur(_ device: String = "APPAREIL1") throws -> RustCryptoEngine {
    let dossier = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("crypto-test-\(UUID().uuidString)", isDirectory: true)
    return try RustCryptoEngine(userID: "@essai:unclic.local", deviceID: device, dossier: dossier)
  }

  func testLaMachineSAmorceAvecSesClesDIdentite() async throws {
    let m = try moteur()
    let cles = await m.clesDIdentite()
    XCTAssertNotNil(cles["curve25519"])
    XCTAssertNotNil(cles["ed25519"])
  }

  /// Une machine neuve veut d'abord publier ses clés d'appareil : sans ce
  /// `keys/upload`, aucun autre appareil ne peut lui parler.
  func testUneMachineNeuveVeutTeleverserSesCles() async throws {
    let m = try moteur()
    let requetes = try await m.requetesSortantes()
    XCTAssertTrue(requetes.contains { $0.kind == .keysUpload }, "attendu un keys/upload, vu \(requetes.map(\.kind))")
  }

  /// Le magasin persiste : deux moteurs sur le même dossier ont la même identité.
  func testLeMagasinSurvitAUnRedemarrage() async throws {
    let dossier = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("crypto-test-\(UUID().uuidString)", isDirectory: true)
    let un = try RustCryptoEngine(userID: "@essai:unclic.local", deviceID: "AAA", dossier: dossier)
    let clesUn = await un.clesDIdentite()
    let deux = try RustCryptoEngine(userID: "@essai:unclic.local", deviceID: "AAA", dossier: dossier)
    let clesDeux = await deux.clesDIdentite()
    XCTAssertEqual(clesUn, clesDeux)
  }

  /// Deux sessions du même compte ont deux magasins distincts — c'est
  /// exactement ce que le partage de clés doit franchir.
  func testDeuxSessionsOntDeuxDossiers() {
    let base = URL(fileURLWithPath: "/tmp/base")
    let a = RustCryptoEngine.dossierParDefaut(base: base, userID: "@essai:unclic.local", deviceID: "AAA")
    let b = RustCryptoEngine.dossierParDefaut(base: base, userID: "@essai:unclic.local", deviceID: "BBB")
    XCTAssertNotEqual(a, b)
    XCTAssertFalse(a.path.contains(":"), "le MXID ne doit pas entrer tel quel dans un chemin")
  }

  /// Le traducteur requête-crypto → appel Matrix, pour les cinq genres qu'on
  /// poste réellement.
  func testLaTraductionDesRequetes() {
    XCTAssertEqual(RustCryptoEngine.traduire(.keysUpload(requestId: "1", body: "{}")).kind, .keysUpload)
    XCTAssertEqual(RustCryptoEngine.traduire(.keysQuery(requestId: "2", users: ["@a:b"])).users, ["@a:b"])
    let td = RustCryptoEngine.traduire(.toDevice(requestId: "3", eventType: "m.room.encrypted", body: "{}"))
    XCTAssertEqual(td.eventType, "m.room.encrypted")
  }
}
