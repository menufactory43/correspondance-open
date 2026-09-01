import XCTest

@testable import Correspondance

/// L'app et l'agent calculent le dossier d'amorce chacun de leur côté — l'app
/// ne peut pas dépendre de l'AgentKit (`Process` n'existe pas sur iOS). Ces
/// tests tiennent les deux calculs ensemble : si l'un change, celui-ci tombe.
@MainActor
final class AgentLocalHostTests: XCTestCase {
  let home = URL(fileURLWithPath: "/Users/moi")

  func testLAgentParDefautGardeSonAncienDossier() {
    // Doit correspondre à `AgentHome.directory` côté agent, à la lettre : c'est
    // là que l'app écrit l'amorce et que l'agent va la lire.
    XCTAssertEqual(AgentPaths.directory(agent: "cc", home: home).path(), "/Users/moi/.correspondance-agent")
  }

  func testUnSecondAgentAUnDossierBienASoi() {
    XCTAssertEqual(AgentPaths.directory(agent: "hermes", home: home).path(), "/Users/moi/.correspondance-hermes")
  }

  func testUnNomDAgentNeFabriquePasDeChemin() {
    let dossier = AgentPaths.directory(agent: "../../etc", home: home).path()
    XCTAssertFalse(dossier.contains(".."), dossier)
    XCTAssertTrue(dossier.hasPrefix("/Users/moi/.correspondance-"), dossier)
  }

  func testLeNomDuPlistEstCeluiQueLeBundlePorte() {
    // `SMAppService.agent(plistName:)` ne cherche que dans
    // Contents/Library/LaunchAgents/ et ne pardonne pas une faute de frappe.
    XCTAssertEqual(AgentLocalHost.plistName(agent: "cc"), "app.correspondance.agent.plist")
  }

  func testChaqueEtatDuServiceSeDitEnFrancais() {
    for etat: AgentLocalHost.State in [.absent, .actif, .attenteApprobation, .introuvable] {
      XCTAssertFalse(etat.labelFR.isEmpty)
    }
    XCTAssertTrue(
      AgentLocalHost.State.attenteApprobation.labelFR.contains("Éléments d'ouverture"),
      "l'écran doit dire où cliquer, pas « autorisation requise »"
    )
  }
}
