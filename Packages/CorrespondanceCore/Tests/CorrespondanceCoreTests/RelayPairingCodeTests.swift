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

/// Le jeton Tailcat dans le code d'appairage — et la rétro-compatibilité, qui
/// est toute la difficulté : un code d'hier doit se lire tel quel, et un code
/// d'aujourd'hui doit rester lisible par une app d'hier.
final class RelayPairingCodeTailcatTests: XCTestCase {

  private func code(tailcat: String?) -> RelayPairingCode {
    RelayPairingCode(
      homeserver: URL(string: "http://127.0.0.1:8010")!,
      serverName: "unclic.local", user: "essai", password: "s3cr3t",
      expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
      tailcat: tailcat)
  }

  func testUnCodeSansJetonSeRelitSansJeton() {
    let relu = RelayPairingCode(encoded: code(tailcat: nil).encoded())
    XCTAssertNotNil(relu)
    XCTAssertNil(relu?.tailcat)
  }

  func testLeJetonFaitLAllerRetour() {
    let jeton = "tco2FwWCDMWMaSLhgzXYPSUARziKjgONO6HWaaDZqpqsKA06"
    XCTAssertEqual(RelayPairingCode(encoded: code(tailcat: jeton).encoded())?.tailcat, jeton)
  }

  func testUnCodeDHierSeLitEncore() {
    // Le JSON exact qu'émettait l'installeur avant ce champ. Il n'a pas à être
    // réémis pour être lu : c'est ça, la rétro-compatibilité.
    let json = #"{"exp":1800000000,"homeserver":"http://127.0.0.1:8010","password":"s3cr3t","server":"unclic.local","user":"essai","v":1}"#
    let jeton = "correspondance://relais/" + Data(json.utf8).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    let relu = RelayPairingCode(encoded: jeton)
    XCTAssertEqual(relu?.serverName, "unclic.local")
    XCTAssertNil(relu?.tailcat)
  }

  func testUneAppDHierIgnoreLeChampSansSeCasser() {
    // L'app d'hier décode le même JSON et n'y cherche pas « tailcat ». On
    // rejoue sa lecture : tous les champs qu'elle connaît doivent être là.
    let encode = code(tailcat: "tcABC").encoded()
    var base64 = String(encode.dropFirst("correspondance://relais/".count))
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    while base64.count % 4 != 0 { base64 += "=" }
    let objet = try! JSONSerialization.jsonObject(with: Data(base64Encoded: base64)!) as! [String: Any]
    XCTAssertEqual(objet["homeserver"] as? String, "http://127.0.0.1:8010")
    XCTAssertEqual(objet["user"] as? String, "essai")
    XCTAssertEqual(objet["v"] as? Int, 1)
  }

  func testLesSixMotsNeChangentPasQuandLeJetonApparait() {
    // L'empreinte nomme le Relais, pas le jeton : quelqu'un qui a lu six mots
    // hier au téléphone doit retrouver les mêmes aujourd'hui.
    XCTAssertEqual(code(tailcat: nil).fingerprintWords(), code(tailcat: "tcABC").fingerprintWords())
  }

  #if os(macOS)
  func testLeDictionnaireSOCKSNaPasDeCleEnDouble() {
    // `kCFNetworkProxiesSOCKSEnable` **vaut** "SOCKSEnable" : les écrire tous
    // les deux tue le processus au démarrage, sans un mot utile.
    let dict = MandataireSOCKS.dictionnaire(port: 1080)
    XCTAssertEqual(dict.count, 3)
    XCTAssertEqual(dict["SOCKSPort"] as? Int, 1080)
    XCTAssertEqual(dict["SOCKSProxy"] as? String, "127.0.0.1")
  }
  #endif
}
