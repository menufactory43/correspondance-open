import XCTest

@testable import CorrespondanceCore

/// Le code d'appairage : ce qui remplace « retape cette URL et ce mot de passe ».
final class RelayPairingCodeTests: XCTestCase {
  func code(exp: Date = Date().addingTimeInterval(900)) -> RelayPairingCode {
    RelayPairingCode(
      homeserver: URL(string: "http://100.64.0.1:8008")!,
      serverName: "correspondance.local",
      user: "meffysto", password: "un-secret", expiresAt: exp
    )
  }

  func testLAllerRetourConserveTout() {
    let relu = RelayPairingCode(encoded: code().encoded())
    XCTAssertEqual(relu?.homeserver.absoluteString, "http://100.64.0.1:8008")
    XCTAssertEqual(relu?.serverName, "correspondance.local")
    XCTAssertEqual(relu?.user, "meffysto")
    XCTAssertEqual(relu?.password, "un-secret")
  }

  func testLIdentifiantSeFormeToutSeul() {
    XCTAssertEqual(code().userID, "@meffysto:correspondance.local")
    var deja = code()
    deja.user = "@meffysto:ailleurs.tld"
    XCTAssertEqual(deja.userID, "@meffysto:ailleurs.tld")
  }

  func testLeCodeEstUnLienQuonPeutScanner() {
    XCTAssertTrue(code().encoded().hasPrefix("correspondance://relais/"))
  }

  func testUnCodeCopieSansSonPrefixeSeLitQuandMeme() {
    let complet = code().encoded()
    let sansPrefixe = String(complet.dropFirst("correspondance://relais/".count))
    XCTAssertEqual(RelayPairingCode(encoded: sansPrefixe)?.user, "meffysto")
    // Et avec des espaces autour, comme un copier-coller en produit.
    XCTAssertEqual(RelayPairingCode(encoded: "  \(complet)\n")?.user, "meffysto")
  }

  func testUnCodePerimeSeVoit() {
    XCTAssertTrue(code(exp: Date().addingTimeInterval(-1)).isExpired())
    XCTAssertFalse(code().isExpired())
    let relu = RelayPairingCode(encoded: code(exp: Date().addingTimeInterval(-1)).encoded())
    XCTAssertEqual(relu?.isExpired(), true)
  }

  func testUnCodeAbimeNeSeLitPas() {
    XCTAssertNil(RelayPairingCode(encoded: "correspondance://relais/n-importe-quoi"))
    XCTAssertNil(RelayPairingCode(encoded: ""))
  }

  /// L'empreinte nomme le Relais, pas le jeton : un code réémis plus tard, ou
  /// avec un autre mot de passe, doit donner les mêmes mots — sinon on ne peut
  /// rien comparer avec quelqu'un au téléphone.
  func testLEmpreinteNommeLeRelaisPasLeJeton() {
    let mots = code().fingerprintWords()
    XCTAssertEqual(mots.count, 6)
    XCTAssertEqual(mots, code(exp: Date().addingTimeInterval(60)).fingerprintWords(),
                   "une autre péremption, le même Relais")

    var rotation = code()
    rotation.password = "un-autre-secret"
    XCTAssertEqual(rotation.fingerprintWords(), mots, "un mot de passe changé, le même Relais")

    var ailleurs = code()
    ailleurs.homeserver = URL(string: "http://100.64.0.2:8008")!
    XCTAssertNotEqual(ailleurs.fingerprintWords(), mots, "un autre Relais, d'autres mots")

    var autreCompte = code()
    autreCompte.user = "camille"
    XCTAssertNotEqual(autreCompte.fingerprintWords(), mots)
  }

  func testLesMotsSeLisentAVoixHaute() {
    for mot in RelayPairingCode.lexicon {
      XCTAssertFalse(mot.isEmpty)
      XCTAssertFalse(mot.contains(" "))
    }
    XCTAssertEqual(Set(RelayPairingCode.lexicon).count, RelayPairingCode.lexicon.count, "pas de doublon")
  }

  func testLaDureeDeVieLaisseLeTempsDeChangerDEcran() {
    XCTAssertEqual(RelayPairingCode.lifetime, 900)
  }
}
