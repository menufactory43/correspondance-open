import XCTest
@testable import CorrespondanceAgentKit

/// Ce que le scan raconte — la ligne de status et le rapport de `doctor` —
/// sans lancer le moindre binaire : on fabrique les résultats.
final class EngineScanTests: XCTestCase {
  private func scan(claude: Bool, hermes: Bool) -> EngineScan {
    EngineScan(engines: [
      .init(name: "claude", path: claude ? "/usr/local/bin/claude" : nil, version: claude ? "2.1.0" : nil),
      .init(name: "hermes", path: hermes ? "/home/g/.local/bin/hermes" : nil, version: nil),
    ])
  }

  func testLaLigneDeStatusDitLeMoteurEtLesPresents() {
    XCTAssertEqual(scan(claude: true, hermes: true).statusLine(backend: .hermes),
                   "moteur hermes · prêts : claude, hermes")
    XCTAssertEqual(scan(claude: true, hermes: false).statusLine(backend: .claude),
                   "moteur claude · prêts : claude")
    XCTAssertEqual(scan(claude: false, hermes: false).statusLine(backend: .claude),
                   "moteur claude · prêts : aucun")
  }

  func testLeRapportDitOuEtQuelleVersion() {
    let report = scan(claude: true, hermes: false).reportFR(backend: .claude)
    XCTAssertTrue(report.contains("✓ claude — /usr/local/bin/claude (2.1.0)"))
    XCTAssertTrue(report.contains("✗ hermes — introuvable"))
    XCTAssertTrue(report.contains("moteur configuré : claude — prêt"))
  }

  func testLeRapportCrieQuandLeMoteurConfigureManque() {
    let report = scan(claude: true, hermes: false).reportFR(backend: .hermes)
    XCTAssertTrue(report.contains("moteur configuré : hermes — ABSENT"))
    XCTAssertFalse(scan(claude: true, hermes: false).isPresent(.hermes))
    XCTAssertTrue(scan(claude: true, hermes: false).isPresent(.claude))
  }

  // MARK: - Quand le moteur n'est pas là

  /// Le défaut qu'on répare : l'agent se taisait. On écrivait « @cc … », rien
  /// ne revenait, et il fallait aller lire un journal sur une autre machine
  /// pour apprendre que le moteur n'avait jamais été installé.
  func testUnMoteurAbsentDitOuEtQuoiFaire() {
    let message = EngineScan.absenceFR(engine: "hermes", host: "umbrel")
    XCTAssertTrue(message.contains("hermes"), message)
    XCTAssertTrue(message.contains("umbrel"), "il faut dire sur quelle machine")
    XCTAssertTrue(message.contains("~/.local/bin"), "et le geste qui répare")
    XCTAssertTrue(message.contains("Réglages"), "ou l'autre issue")
  }

  /// Un moteur qu'on ne connaît pas garde une réponse utile : l'endroit et
  /// l'autre issue. Un message vide serait un silence de plus.
  func testUnMoteurInconnuDitQuandMemeOuEtLAutreIssue() {
    let message = EngineScan.absenceFR(engine: "moteur-du-futur", host: "umbrel")
    XCTAssertTrue(message.contains("moteur-du-futur"), message)
    XCTAssertTrue(message.contains("umbrel"), message)
    XCTAssertTrue(message.contains("Réglages"), message)
  }
}
