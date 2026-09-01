import XCTest

@testable import CorrespondanceCore

/// Le jeton qu'on colle dans un terminal pour installer l'agent ailleurs. Il
/// porte l'amorce : l'app ne lance aucun serveur qui pourrait la servir.
final class AgentBootstrapTokenTests: XCTestCase {
  func jeton(exp: Date = Date().addingTimeInterval(600)) -> AgentBootstrapToken {
    AgentBootstrapToken(
      homeserver: URL(string: "http://100.64.0.1:8008")!,
      user: "cc", password: "un-secret-très-long", owner: "@meffysto:correspondance.local",
      expiresAt: exp
    )
  }

  func testLAllerRetourConserveLAmorce() {
    let original = jeton()
    let relu = AgentBootstrapToken(encoded: original.encoded())
    XCTAssertEqual(relu?.homeserver, original.homeserver)
    XCTAssertEqual(relu?.user, "cc")
    XCTAssertEqual(relu?.password, "un-secret-très-long")
    XCTAssertEqual(relu?.owner, "@meffysto:correspondance.local")
    XCTAssertEqual(relu?.version, AgentBootstrapToken.currentVersion)
  }

  /// Un jeton se colle dans une ligne de commande : rien qui oblige à
  /// l'entourer de guillemets, rien qu'un client de messagerie découperait.
  func testLeJetonSeColleSansGuillemets() {
    let encode = jeton().encoded()
    XCTAssertFalse(encode.contains("+"))
    XCTAssertFalse(encode.contains("/"))
    XCTAssertFalse(encode.contains("="))
    XCTAssertFalse(encode.contains(" "))
    XCTAssertFalse(encode.isEmpty)
  }

  func testUnJetonPerimeSeVoit() {
    let vieux = jeton(exp: Date().addingTimeInterval(-1))
    XCTAssertTrue(vieux.isExpired())
    XCTAssertFalse(jeton().isExpired())
  }

  func testLaPeremptionSurvitALEncodage() {
    let exp = Date().addingTimeInterval(-1)
    let relu = AgentBootstrapToken(encoded: jeton(exp: exp).encoded())
    XCTAssertEqual(relu?.isExpired(), true, "l'installeur doit pouvoir refuser tout seul")
  }

  func testUnJetonAbimeNeSeLitPas() {
    XCTAssertNil(AgentBootstrapToken(encoded: "pas-un-jeton"))
    XCTAssertNil(AgentBootstrapToken(encoded: ""))
    // Un jeton coupé en deux par un copier-coller malheureux.
    let moitie = String(jeton().encoded().prefix(20))
    XCTAssertNil(AgentBootstrapToken(encoded: moitie))
  }

  func testLaCommandeTientSurUneLigne() {
    let commande = jeton().installCommand()
    XCTAssertTrue(commande.hasPrefix("curl -fsSL https://github.com/"))
    // Jamais `curl | sh` : un téléchargement raté y devient un succès silencieux.
    XCTAssertFalse(commande.contains("| sh"), commande)
    XCTAssertTrue(commande.contains(" && sh "), commande)
    XCTAssertFalse(commande.contains("\n"))
  }

  /// La durée de vie est courte parce que l'usage unique n'est pas
  /// vérifiable sans serveur : c'est la péremption qui borne la fuite.
  func testLaDureeDeVieEstCourte() {
    XCTAssertEqual(AgentBootstrapToken.lifetime, 600)
  }
}
