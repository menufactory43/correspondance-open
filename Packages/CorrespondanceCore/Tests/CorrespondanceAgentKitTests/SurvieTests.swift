import XCTest

@testable import CorrespondanceAgentKit

/// Deux invariants, tous deux appris au prix fort sur une vraie machine :
/// l'agent meurt avec l'app **quelle que soit la façon dont elle meurt**, et
/// il n'y a **jamais deux agents vivants sur le même compte**.
final class SurvieTests: XCTestCase {

  // MARK: - L'agent meurt avec son parent

  func testLArgumentSeLitDesDeuxFacons() {
    XCTAssertEqual(ParentWatch.expectedParent(in: ["run", "--watch-parent", "4242"]), 4242)
    XCTAssertEqual(ParentWatch.expectedParent(in: ["run", "--watch-parent=4242"]), 4242)
    XCTAssertNil(ParentWatch.expectedParent(in: ["run"]))
    XCTAssertNil(ParentWatch.expectedParent(in: ["run", "--watch-parent"]), "un drapeau sans valeur")
    XCTAssertNil(ParentWatch.expectedParent(in: ["run", "--watch-parent", "pas-un-pid"]))
  }

  /// Sans argument, l'agent ne surveille personne : lancé par systemd sur le
  /// NUC, il n'a pas de parent à suivre et ne doit pas s'arrêter tout seul.
  func testSansArgumentAucuneSurveillance() {
    XCTAssertNil(ParentWatch.expectedParent(in: ["run", "--agent", "cc"]))
  }

  func testUnParentQuiChangeSignifieQuIlEstMort() {
    // Le noyau réattribue l'orphelin à launchd (1) ou à un sous-reaper.
    XCTAssertTrue(ParentWatch.isOrphan(expected: 4242, current: 1))
    XCTAssertFalse(ParentWatch.isOrphan(expected: 4242, current: 4242))
  }

  func testUneLectureAberranteNArretePasLAgent() {
    // On ne s'arrête jamais sur un 0 : mieux vaut continuer de tourner que
    // mourir sur une lecture douteuse.
    XCTAssertFalse(ParentWatch.isOrphan(expected: 4242, current: 0))
    XCTAssertFalse(ParentWatch.isOrphan(expected: 0, current: 1))
  }

  /// La mécanique complète, sans tuer de processus : le parent « meurt »,
  /// la surveillance s'en aperçoit et prévient.
  func testLaMortDuParentDeclencheLArret() async {
    let parentVivant = ParentSimule(pid: 4242)
    let arret = expectation(description: "l'agent s'arrête")

    let tache = ParentWatch.watch(
      expected: 4242,
      interval: .milliseconds(20),
      currentParent: { parentVivant.courant },
      onOrphan: { arret.fulfill() }
    )
    defer { tache.cancel() }

    // Le parent tient bon : rien ne se passe.
    try? await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(arret.expectedFulfillmentCount, 1)

    // Il meurt : l'enfant est réattribué à launchd.
    parentVivant.courant = 1
    await fulfillment(of: [arret], timeout: 2)
  }

  // MARK: - Jamais deux agents sur le même compte

  var moi: SingleInstance.Sighting {
    .init(host: "macbook", pid: 100, at: Date())
  }

  func testSansStatusOnDemarre() {
    XCTAssertEqual(SingleInstance.verdict(sighting: nil, moi: moi), .demarre)
  }

  /// Le cas d'un redémarrage après chute : c'est notre propre cadavre, et il
  /// ne doit pas nous empêcher de repartir.
  func testUnCadavreSurLaMemeMachineNeBloquePas() {
    let cadavre = SingleInstance.Sighting(host: "macbook", pid: 99, at: Date())
    let verdict = SingleInstance.verdict(
      sighting: cadavre, moi: moi, estVivant: { _ in false }
    )
    XCTAssertEqual(verdict, .demarre, "un redémarrage après crash doit marcher")
  }

  func testUnAgentVivantSurLaMemeMachineBloque() {
    let vivant = SingleInstance.Sighting(host: "macbook", pid: 99, at: Date())
    let verdict = SingleInstance.verdict(sighting: vivant, moi: moi, estVivant: { _ in true })
    guard case .refuse(let raison) = verdict else { return XCTFail("il fallait refuser") }
    XCTAssertTrue(raison.contains("99"), raison)
    XCTAssertTrue(raison.contains("Réglages"), "le refus doit dire quoi faire")
  }

  func testNotrePropreStatusNeNousBloqueJamais() {
    let nous = SingleInstance.Sighting(host: "macbook", pid: 100, at: Date())
    XCTAssertEqual(
      SingleInstance.verdict(sighting: nous, moi: moi, estVivant: { _ in true }),
      .demarre,
      "notre pid : c'est nous"
    )
  }

  /// Une autre machine : on ne peut pas sonder son pid, la fraîcheur tranche.
  func testUneAutreMachineRecenteBloque() {
    let nuc = SingleInstance.Sighting(host: "umbrel", pid: 7, at: Date().addingTimeInterval(-30))
    let verdict = SingleInstance.verdict(sighting: nuc, moi: moi, estVivant: { _ in true })
    guard case .refuse(let raison) = verdict else { return XCTFail("il fallait refuser") }
    XCTAssertTrue(raison.contains("umbrel"), raison)
    XCTAssertTrue(raison.contains("deux fois"), "on dit pourquoi c'est grave")
  }

  func testUneAutreMachineSilencieuseDepuisLongtempsNeBloquePas() {
    let vieux = SingleInstance.Sighting(host: "umbrel", pid: 7, at: Date().addingTimeInterval(-300))
    XCTAssertEqual(
      SingleInstance.verdict(sighting: vieux, moi: moi, estVivant: { _ in true }),
      .demarre,
      "cinq minutes de silence : on ne peut plus affirmer qu'il vit"
    )
  }

  func testLaFenetreEstDeDeuxMinutes() {
    XCTAssertEqual(SingleInstance.fenetre, 120)
  }

  // MARK: - Le status porte de quoi décider

  func testLeStatusPorteLaMachineEtLePid() {
    let contenu = AgentEvents.status(body: "prêt", agent: "cc", host: "umbrel", pid: 4242)
    let vu = AgentEvents.sighting(in: contenu, at: Date())
    XCTAssertEqual(vu?.host, "umbrel")
    XCTAssertEqual(vu?.pid, 4242)
    XCTAssertEqual(contenu.nonIntegerNumberPaths(), [], "un pid entier, jamais un flottant")
  }

  func testUnStatusDAvantCetteVersionNeDitRien() {
    let ancien = MatrixJSON.object(["body": .string("prêt"), "agent": .string("cc")])
    XCTAssertNil(
      AgentEvents.sighting(in: ancien, at: Date()),
      "sans machine ni pid, on ne conclut rien — la fenêtre de temps tranchera"
    )
  }
}

import CorrespondanceMatrixClient

/// Un parent qu'on peut faire mourir sans tuer de processus.
private final class ParentSimule: @unchecked Sendable {
  var courant: pid_t

  init(pid: pid_t) {
    courant = pid
  }
}
