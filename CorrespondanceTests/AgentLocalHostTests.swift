import CorrespondanceAgentKit
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

  /// Le correctif de la phase 4 : `CORRESPONDANCE_HOME` déplace **aussi** le
  /// dossier d'amorce de l'agent. Avant, un essai écrivait par-dessus l'amorce
  /// du cc de production ; `docs/MATRIX-SETUP.md` disait de sauter l'étape.
  func testUnEssaiDeplaceLeDossierDAmorce() {
    let essai = ["CORRESPONDANCE_HOME": "unclic"]
    XCTAssertEqual(
      AgentPaths.directory(agent: "cc", home: home, environment: essai).path(),
      "/Users/moi/.correspondance-agent-unclic")
    XCTAssertEqual(
      AgentPaths.directory(agent: "hermes", home: home, environment: essai).path(),
      "/Users/moi/.correspondance-hermes-unclic")
    // Sans la variable, rien ne change — la propriété qui ne se négocie pas.
    XCTAssertEqual(
      AgentPaths.directory(agent: "cc", home: home, environment: [:]).path(),
      "/Users/moi/.correspondance-agent")
  }

  /// L'app et l'agent calculent ce nom chacun de leur côté : ils doivent tomber
  /// sur la même chaîne, avec et sans essai, sinon l'agent lit une amorce qui
  /// n'existe pas et boucle sur une erreur de configuration.
  func testLApplicationEtLAgentNommentLeMemeDossier() {
    for environnement in [[:], ["CORRESPONDANCE_HOME": "unclic"], ["CORRESPONDANCE_HOME": "../ailleurs"]]
    as [[String: String]] {
      for agent in ["cc", "hermes"] {
        XCTAssertEqual(
          AgentPaths.folderName(agent: agent, environment: environnement),
          AgentHome.folderName(agent: agent, environment: environnement),
          "\(agent) / \(environnement)")
      }
    }
  }

  func testUnNomDEssaiNeFabriquePasDeChemin() {
    let dossier = AgentPaths.directory(
      agent: "cc", home: home, environment: ["CORRESPONDANCE_HOME": "../../etc"]
    ).path()
    XCTAssertFalse(dossier.contains(".."), dossier)
    XCTAssertTrue(dossier.hasPrefix("/Users/moi/.correspondance-agent-"), dossier)
  }

  func testUnNomDAgentNeFabriquePasDeChemin() {
    let dossier = AgentPaths.directory(agent: "../../etc", home: home).path()
    XCTAssertFalse(dossier.contains(".."), dossier)
    XCTAssertTrue(dossier.hasPrefix("/Users/moi/.correspondance-"), dossier)
  }

  func testLeLaunchAgentEstRangePasProposé() {
    // `SMAppService` reste dans le dépôt, derrière ce drapeau : l'enquête est
    // dans docs/AGENT.md, et quelqu'un y reviendra peut-être.
    XCTAssertFalse(AgentLocalHost.useLaunchAgent)
    XCTAssertEqual(AgentLocalHost.plistName(agent: "cc"), "app.correspondance.agent.plist")
  }

  func testChaqueEtatSeDitEnFrancais() {
    let etats: [AgentLocalHost.State] = [
      .absent, .actif, .introuvable, .incomplet,
      .silencieux(depuis: nil), .silencieux(depuis: Date().addingTimeInterval(-7200)),
      .abandonne(raison: "cc s'est arrêté 8 fois de suite."),
    ]
    for etat in etats {
      XCTAssertFalse(etat.labelFR.isEmpty)
    }
    XCTAssertTrue(
      AgentLocalHost.State.actif.labelFR.contains("Correspondance est ouverte"),
      "l'interface doit dire ce que « Ce Mac » achète vraiment"
    )
  }

  // MARK: - « Actif » est une conclusion, pas une lecture

  /// Le bug du premier essai réel : l'app affichait « actif » sur la foi d'un
  /// drapeau de macOS, alors qu'aucune amorce, aucun service et aucun compte
  /// n'existaient — et ne proposait plus que « Désactiver ».
  func testSansAmorceRienNEstActif() {
    let etat = AgentLocalHost.decide(
      binairePresent: true, processusVivant: true, amorcePresente: false, dernierStatus: Date()
    )
    XCTAssertEqual(etat, .incomplet, "un processus sans amorce ne peut pas se connecter")
    XCTAssertTrue(etat.labelFR.contains("amorce"), etat.labelFR)
  }

  func testProcessusVivantEtStatusRecent() {
    XCTAssertEqual(
      AgentLocalHost.decide(
        binairePresent: true, processusVivant: true, amorcePresente: true,
        dernierStatus: Date().addingTimeInterval(-60)
      ),
      .actif
    )
  }

  func testUnProcessusArreteNEstPasActifMemeAvecUnStatusRecent() {
    XCTAssertEqual(
      AgentLocalHost.decide(
        binairePresent: true, processusVivant: false, amorcePresente: true,
        dernierStatus: Date()
      ),
      .absent,
      "un status récent peut venir d'un agent qui tourne ailleurs"
    )
  }

  /// Un status vieux d'une heure se dit, il ne se tait pas.
  func testUnAgentMuetDepuisLongtempsNEstPasActif() {
    let vieux = Date().addingTimeInterval(-7200)
    let etat = AgentLocalHost.decide(
      binairePresent: true, processusVivant: true, amorcePresente: true, dernierStatus: vieux
    )
    XCTAssertEqual(etat, .silencieux(depuis: vieux))
    XCTAssertTrue(etat.labelFR.contains("muet"), etat.labelFR)
  }

  func testJusteDemarreIlNAPasEncoreParle() {
    XCTAssertEqual(
      AgentLocalHost.decide(
        binairePresent: true, processusVivant: true, amorcePresente: true, dernierStatus: nil
      ),
      .silencieux(depuis: nil)
    )
  }

  /// « Introuvable » se constate sur le disque, il ne se devine pas — et le
  /// message ne renvoie plus vers un fichier qui existe.
  func testSansBinaireOnDitCeQuOnAConstate() {
    XCTAssertEqual(
      AgentLocalHost.decide(
        binairePresent: false, processusVivant: true, amorcePresente: true, dernierStatus: Date()
      ),
      .introuvable
    )
    XCTAssertTrue(AgentLocalHost.aideIntrouvable.contains("est absent"), "on constate")
    XCTAssertTrue(AgentLocalHost.aideIntrouvable.contains("autre machine"), "et on donne une issue")
  }

  func testLAbandonPasseAvantLeReste() {
    let etat = AgentLocalHost.decide(
      binairePresent: true, processusVivant: false, amorcePresente: true,
      dernierStatus: Date(), abandon: "cc s'est arrêté 8 fois de suite."
    )
    XCTAssertEqual(etat, .abandonne(raison: "cc s'est arrêté 8 fois de suite."))
  }

  /// Le seuil est large exprès : un agent qui n'a rien à faire ne poste rien.
  func testLeSeuilDeSilenceEstLarge() {
    XCTAssertEqual(AgentLocalHost.State.silenceMax, 3600)
    XCTAssertEqual(
      AgentLocalHost.decide(
        binairePresent: true, processusVivant: true, amorcePresente: true,
        dernierStatus: Date().addingTimeInterval(-3000)
      ),
      .actif,
      "cinquante minutes de silence, c'est encore normal"
    )
  }

  // MARK: - Reprise au lancement

  func testVouluAvecAmorceEtBinaireOnRelance() {
    XCTAssertTrue(AgentLocalHost.shouldResume(wanted: true, amorcePresente: true, binairePresent: true))
  }

  func testUnArreterAnterieurEstRespecte() {
    XCTAssertFalse(AgentLocalHost.shouldResume(wanted: false, amorcePresente: true, binairePresent: true))
  }

  func testSansAmorceOnNeRelancePas() {
    XCTAssertFalse(AgentLocalHost.shouldResume(wanted: true, amorcePresente: false, binairePresent: true))
  }

  func testSansBinaireOnNeRelancePas() {
    XCTAssertFalse(AgentLocalHost.shouldResume(wanted: true, amorcePresente: true, binairePresent: false))
  }
}
