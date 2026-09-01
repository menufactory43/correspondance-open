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
    let etats: [AgentLocalHost.State] = [
      .absent, .actif, .attenteApprobation, .introuvable, .incomplet,
      .silencieux(depuis: nil), .silencieux(depuis: Date().addingTimeInterval(-7200)),
    ]
    for etat in etats {
      XCTAssertFalse(etat.labelFR.isEmpty)
    }
    XCTAssertTrue(
      AgentLocalHost.State.attenteApprobation.labelFR.contains("Éléments d'ouverture"),
      "l'écran doit dire où cliquer, pas « autorisation requise »"
    )
  }

  // MARK: - « Actif » est une conclusion, pas une lecture

  /// Le bug trouvé au premier essai réel : macOS répondait « enregistré » alors
  /// qu'aucune amorce, aucun service et aucun compte n'existaient. L'app
  /// affichait « actif sur ce Mac » et ne proposait plus que « Désactiver » —
  /// aucun moyen d'activer quoi que ce soit.
  func testUnDrapeauSansAmorceNEstPasActif() {
    let etat = AgentLocalHost.decide(
      flagEnregistre: true, demandeApprobation: false, plistPresent: true,
      amorcePresente: false, dernierStatus: Date()
    )
    XCTAssertEqual(etat, .incomplet, "un service enregistré sans amorce est cassé, pas actif")
    XCTAssertTrue(etat.labelFR.contains("moitié"), etat.labelFR)
  }

  func testToutEstLaEtLAgentAParleRecemment() {
    let etat = AgentLocalHost.decide(
      flagEnregistre: true, demandeApprobation: false, plistPresent: true,
      amorcePresente: true, dernierStatus: Date().addingTimeInterval(-60)
    )
    XCTAssertEqual(etat, .actif)
  }

  /// Un status vieux d'une heure se dit, il ne se tait pas.
  func testUnAgentMuetDepuisLongtempsNEstPasActif() {
    let vieux = Date().addingTimeInterval(-7200)
    let etat = AgentLocalHost.decide(
      flagEnregistre: true, demandeApprobation: false, plistPresent: true,
      amorcePresente: true, dernierStatus: vieux
    )
    XCTAssertEqual(etat, .silencieux(depuis: vieux))
    XCTAssertTrue(etat.labelFR.contains("muet"), etat.labelFR)
  }

  func testToutEstLaMaisLAgentNAJamaisParle() {
    let etat = AgentLocalHost.decide(
      flagEnregistre: true, demandeApprobation: false, plistPresent: true,
      amorcePresente: true, dernierStatus: nil
    )
    XCTAssertEqual(etat, .silencieux(depuis: nil))
  }

  func testSansDrapeauCEstAbsent() {
    XCTAssertEqual(
      AgentLocalHost.decide(
        flagEnregistre: false, demandeApprobation: false, plistPresent: true,
        amorcePresente: false, dernierStatus: nil
      ),
      .absent
    )
    // Même avec une amorce restée sur le disque : rien n'est enregistré.
    XCTAssertEqual(
      AgentLocalHost.decide(
        flagEnregistre: false, demandeApprobation: false, plistPresent: true,
        amorcePresente: true, dernierStatus: Date()
      ),
      .absent
    )
  }

  func testLApprobationPasseAvantToutLeReste() {
    let etat = AgentLocalHost.decide(
      flagEnregistre: false, demandeApprobation: true, plistPresent: true,
      amorcePresente: false, dernierStatus: nil
    )
    XCTAssertEqual(etat, .attenteApprobation, "on montre l'approbation, on ne l'espère pas")
  }

  func testSansPlistRienNEstPossible() {
    XCTAssertEqual(
      AgentLocalHost.decide(
        flagEnregistre: true, demandeApprobation: false, plistPresent: false,
        amorcePresente: true, dernierStatus: Date()
      ),
      .introuvable
    )
    XCTAssertFalse(AgentLocalHost.aideIntrouvable.isEmpty, "même là, on dit quoi faire")
  }

  /// Le seuil est large exprès : un agent qui n'a rien à faire ne poste rien.
  func testLeSeuilDeSilenceEstLarge() {
    XCTAssertEqual(AgentLocalHost.State.silenceMax, 3600)
    let limite = Date().addingTimeInterval(-3000)
    XCTAssertEqual(
      AgentLocalHost.decide(
        flagEnregistre: true, demandeApprobation: false, plistPresent: true,
        amorcePresente: true, dernierStatus: limite
      ),
      .actif,
      "cinquante minutes de silence, c'est encore normal"
    )
  }
}
