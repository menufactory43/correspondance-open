import XCTest

@testable import CorrespondanceCore

/// La ligne de status d'un agent est **la seule preuve** qu'on ait d'un agent
/// distant : l'app n'a rien installé sur son hôte et ne peut pas y regarder.
/// Ce qui s'affiche à l'écran (« hermes, sur umbrel, prêts : claude, hermes »)
/// se lit donc ici, ou ne s'affiche pas.
final class AgentStatusLineTests: XCTestCase {
  private func status(_ ligne: String, at date: Date = Date()) -> MatrixBridgeService.AgentStatus {
    MatrixBridgeService.AgentStatus(engines: ligne, publishedAt: date)
  }

  func testLaLigneCompleteDonneLHoteLeMoteurEtLesPrets() {
    let ligne = status("cc tourne sur umbrel depuis 14 h 02 · moteur acp · prêts : claude, hermes")
    XCTAssertEqual(ligne.host, "umbrel")
    XCTAssertEqual(ligne.backend, "acp")
    XCTAssertEqual(ligne.enginesReady, ["claude", "hermes"])
  }

  /// L'agent poste aussi une ligne sans hôte (avant qu'on ne l'y mette). On
  /// rend `nil` : « on ne sait pas où » est vrai, « sur ce Mac » serait faux.
  func testSansHoteOnNInventePas() {
    let ligne = status("moteur claude · prêts : claude")
    XCTAssertNil(ligne.host)
    XCTAssertEqual(ligne.backend, "claude")
    XCTAssertEqual(ligne.enginesReady, ["claude"])
  }

  /// « aucun » n'est pas un moteur : un agent dont le scan ne trouve rien ne
  /// doit pas apparaître comme portant un moteur nommé « aucun ».
  func testAucunMoteurNEstPasUnMoteur() {
    XCTAssertEqual(status("moteur hermes · prêts : aucun").enginesReady, [])
  }

  func testUnStatusVieuxNEstPasFrais() {
    let vieux = status("moteur claude · prêts : claude", at: Date().addingTimeInterval(-7200))
    XCTAssertFalse(vieux.isFresh(), "deux heures de silence, on ne dit plus « vivant »")
    let recent = status("moteur claude · prêts : claude", at: Date().addingTimeInterval(-60))
    XCTAssertTrue(recent.isFresh())
  }

  /// Le seuil est large exprès : un agent qui n'a rien à faire ne poste rien,
  /// et on ne veut pas crier au loup.
  func testLeSeuilDeFraicheurEstLarge() {
    let status = status("moteur claude · prêts : claude", at: Date().addingTimeInterval(-3000))
    XCTAssertTrue(status.isFresh(), "cinquante minutes de silence, c'est encore normal")
  }
}
