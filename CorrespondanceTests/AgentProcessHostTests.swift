import XCTest

import CorrespondanceAgentKit
import CorrespondanceMatrixClient

@testable import Correspondance

/// La surveillance du processus de l'agent : il démarre, il redémarre s'il
/// tombe, il s'arrête quand on le lui demande — et il finit par renoncer plutôt
/// que de tourner en boucle.
///
/// Les tests surveillent `/bin/sh`, pas l'agent : ce qu'on éprouve est le
/// harnais, pas ce qu'il lance.
@MainActor
final class AgentProcessHostTests: XCTestCase {

  // MARK: - Le palier de redémarrage (pur)

  func testLePremierRedemarrageEstRapidePuisOnEspace() {
    let palier = AgentProcessHost.Backoff(premier: 1, plafond: 60, essaisMax: 8)
    XCTAssertEqual(palier.delai(essai: 0), 0)
    XCTAssertEqual(palier.delai(essai: 1), 1)
    XCTAssertEqual(palier.delai(essai: 2), 2)
    XCTAssertEqual(palier.delai(essai: 3), 4)
    XCTAssertEqual(palier.delai(essai: 4), 8)
  }

  func testLeDelaiNeDepasseJamaisSonPlafond() {
    let palier = AgentProcessHost.Backoff(premier: 1, plafond: 60, essaisMax: 20)
    XCTAssertEqual(palier.delai(essai: 12), 60, "pas de boucle folle, pas d'attente d'une heure")
  }

  func testOnFinitParRenoncer() {
    let palier = AgentProcessHost.Backoff(essaisMax: 8)
    XCTAssertFalse(palier.renonce(apres: 7))
    XCTAssertTrue(palier.renonce(apres: 8), "réessayer cent fois ne répare rien")
  }

  // MARK: - Le vrai processus

  func testUnProcessusQuiDureTourneEtSArrete() throws {
    let hote = AgentProcessHost()
    let journal = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: journal) }

    try hote.start(.init(
      executable: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "sleep 30"],
      logURL: journal
    ), agent: "essai")
    XCTAssertTrue(hote.isRunning(agent: "essai"))

    hote.stop(agent: "essai")
    XCTAssertFalse(hote.isRunning(agent: "essai"), "l'arrêt est immédiat : rien ne survit à l'app")
  }

  func testUnProcessusQuiTombeRedemarre() async throws {
    let hote = AgentProcessHost()
    // Un palier court : on éprouve le redémarrage, pas la patience.
    hote.backoff = .init(premier: 0.1, plafond: 0.1, essaisMax: 5)
    let journal = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
      hote.stop(agent: "essai")
      try? FileManager.default.removeItem(at: journal)
    }

    try hote.start(.init(
      executable: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "exit 1"],
      logURL: journal
    ), agent: "essai")
    // Le processus meurt aussitôt ; on laisse le harnais le relancer deux fois.
    try await Task.sleep(for: .milliseconds(700))
    XCTAssertGreaterThanOrEqual(hote.redemarrages(agent: "essai"), 2, "il doit avoir été relancé")
  }

  func testApresTropDeChutesOnRenonceEtOnLeDit() async throws {
    let hote = AgentProcessHost()
    hote.backoff = .init(premier: 0.05, plafond: 0.05, essaisMax: 3)
    let journal = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
      hote.stop(agent: "essai")
      try? FileManager.default.removeItem(at: journal)
    }

    try hote.start(.init(
      executable: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "exit 3"],
      logURL: journal
    ), agent: "essai")
    try await Task.sleep(for: .milliseconds(800))
    XCTAssertFalse(hote.isRunning(agent: "essai"))
    let abandon = try XCTUnwrap(hote.abandon(agent: "essai"), "on doit dire pourquoi on a cessé")
    XCTAssertTrue(abandon.contains("journal"), abandon)
  }

  func testUnArretVouluNeDeclenchePasDeRedemarrage() async throws {
    let hote = AgentProcessHost()
    hote.backoff = .init(premier: 0.05, plafond: 0.05, essaisMax: 5)
    let journal = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: journal) }

    try hote.start(.init(
      executable: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "sleep 30"],
      logURL: journal
    ), agent: "essai")
    hote.stop(agent: "essai")
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertEqual(hote.redemarrages(agent: "essai"), 0, "arrêter n'est pas tomber")
    XCTAssertFalse(hote.isRunning(agent: "essai"))
  }

  func testLeJournalEstEcritEtRetrouvable() async throws {
    let hote = AgentProcessHost()
    let journal = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
      hote.stop(agent: "essai")
      try? FileManager.default.removeItem(at: journal)
    }

    try hote.start(.init(
      executable: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "echo bonjour-du-journal; sleep 5"],
      logURL: journal
    ), agent: "essai")
    XCTAssertEqual(hote.logURL(agent: "essai"), journal, "les réglages doivent pouvoir l'ouvrir")
    try await Task.sleep(for: .milliseconds(300))
    let contenu = try String(contentsOf: journal, encoding: .utf8)
    XCTAssertTrue(contenu.contains("bonjour-du-journal"), contenu)
  }

  func testLeBinaireEmbarqueSeConstateSurLeDisque() {
    // Dans le bundle de test il n'y en a pas : la valeur est nil, et c'est
    // exactement ce qu'on veut — on regarde le fichier, on ne devine pas.
    let url = AgentProcessHost.Launch.embeddedAgentURL
    if let url {
      XCTAssertTrue(FileManager.default.isExecutableFile(atPath: url.path()))
    }
    XCTAssertEqual(AgentProcessHost.Launch.embeddedAgent(named: "cc") == nil, url == nil)
  }

  // MARK: - Plusieurs agents

  /// Un agent est un compte Matrix ; l'app en fait tourner plusieurs. Chacun a
  /// son processus, et arrêter l'un ne touche pas à l'autre — sans quoi
  /// « Arrêter hermes » tuerait cc en silence.
  func testDeuxAgentsTournentEtSArretentSeparement() throws {
    let hote = AgentProcessHost()
    let journalCC = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let journalHermes = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
      hote.stopAll()
      try? FileManager.default.removeItem(at: journalCC)
      try? FileManager.default.removeItem(at: journalHermes)
    }

    try hote.start(
      .init(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 30"], logURL: journalCC),
      agent: "cc"
    )
    try hote.start(
      .init(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 30"], logURL: journalHermes),
      agent: "hermes"
    )
    XCTAssertEqual(hote.agentsVivants, ["cc", "hermes"])
    XCTAssertEqual(hote.logURL(agent: "hermes"), journalHermes, "chacun son journal")

    hote.stop(agent: "hermes")
    XCTAssertTrue(hote.isRunning(agent: "cc"), "arrêter hermes ne touche pas à cc")
    XCTAssertFalse(hote.isRunning(agent: "hermes"))
    XCTAssertEqual(hote.agentsVivants, ["cc"])
  }

  /// L'app se ferme : **tout le monde** s'arrête. Le pluriel n'est pas
  /// décoratif — un agent orphelin continuerait de répondre au nom de
  /// quelqu'un après la fermeture.
  func testLaFermetureDeLAppArreteTousLesAgents() throws {
    let hote = AgentProcessHost()
    let journal = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: journal) }

    for nom in ["cc", "hermes", "goose"] {
      try hote.start(
        .init(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 30"], logURL: journal),
        agent: nom
      )
    }
    XCTAssertEqual(hote.agentsVivants.count, 3)
    hote.stopAll()
    XCTAssertTrue(hote.agentsVivants.isEmpty, "aucun agent ne survit à l'app")
  }

  /// Redémarrer un agent sous le même nom ne le lance pas deux fois : deux
  /// processus sur un compte, ce sont deux réponses au même message.
  func testRedemarrerUnAgentNeLeLancePasDeuxFois() throws {
    let hote = AgentProcessHost()
    let journal = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
      hote.stopAll()
      try? FileManager.default.removeItem(at: journal)
    }
    let lancement = AgentProcessHost.Launch(
      executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 30"], logURL: journal
    )
    try hote.start(lancement, agent: "cc")
    try hote.start(lancement, agent: "cc")
    XCTAssertEqual(hote.agentsVivants, ["cc"], "un agent, un processus")
  }

  // MARK: - Toutes les chutes ne se valent pas

  /// Un mot de passe refusé par le Relais ne se répare pas tout seul :
  /// relancer huit fois ne fait que remplir le journal en donnant l'illusion
  /// d'un plantage à répétition. C'était le dernier défaut connu.
  func testUnRefusDIdentifiantsNeSeRelancePas() async throws {
    let hote = AgentProcessHost()
    hote.backoff = .init(premier: 0.05, plafond: 0.05, essaisMax: 5)
    let journal = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
      hote.stop(agent: "essai")
      try? FileManager.default.removeItem(at: journal)
    }

    try hote.start(.init(
      executable: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "exit \(AgentExit.identifiantsRefuses)"],
      logURL: journal
    ), agent: "essai")
    try await Task.sleep(for: .milliseconds(500))

    XCTAssertEqual(hote.redemarrages(agent: "essai"), 0, "on ne relance pas ce qui ne se répare pas tout seul")
    XCTAssertFalse(hote.isRunning(agent: "essai"))
    let abandon = try XCTUnwrap(hote.abandon(agent: "essai"))
    XCTAssertTrue(abandon.contains("identifiants refusés"), abandon)
    XCTAssertTrue(abandon.contains("Réinstaller"), "le message doit donner l'issue")
  }

  /// Un second agent sur le même compte : même raisonnement, insister
  /// n'arrangerait rien.
  func testUnAgentDejaEnCoursNeSeRelancePas() async throws {
    let hote = AgentProcessHost()
    hote.backoff = .init(premier: 0.05, plafond: 0.05, essaisMax: 5)
    let journal = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
      hote.stop(agent: "essai")
      try? FileManager.default.removeItem(at: journal)
    }

    try hote.start(.init(
      executable: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "exit \(AgentExit.dejaEnCours)"],
      logURL: journal
    ), agent: "essai")
    try await Task.sleep(for: .milliseconds(500))

    XCTAssertEqual(hote.redemarrages(agent: "essai"), 0)
    XCTAssertTrue(hote.abandon(agent: "essai")?.contains("deux fois") == true, hote.abandon(agent: "essai") ?? "")
  }

  /// Une chute ordinaire, elle, se relance : le Relais pas encore prêt, un
  /// moteur qui trébuche. C'est le cas courant et il ne doit pas changer.
  func testUneChuteOrdinaireSeRelanceToujours() async throws {
    let hote = AgentProcessHost()
    hote.backoff = .init(premier: 0.05, plafond: 0.05, essaisMax: 5)
    let journal = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
      hote.stop(agent: "essai")
      try? FileManager.default.removeItem(at: journal)
    }

    try hote.start(.init(
      executable: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "exit 1"],
      logURL: journal
    ), agent: "essai")
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertGreaterThanOrEqual(hote.redemarrages(agent: "essai"), 1, "une erreur ordinaire se réessaie")
  }

  // MARK: - Le contrat de sortie

  func testUnRefusDuRelaisSeDistingueDUnePanne() {
    // 401/403 : le serveur a décidé. On ne réessaie pas.
    XCTAssertEqual(
      AgentExit.code(for: MatrixError.http(status: 403, errcode: "M_FORBIDDEN", message: nil)),
      AgentExit.identifiantsRefuses
    )
    XCTAssertEqual(
      AgentExit.code(for: MatrixError.http(status: 401, errcode: nil, message: nil)),
      AgentExit.identifiantsRefuses
    )
    // Une panne réseau, elle, se réessaie.
    XCTAssertEqual(AgentExit.code(for: MatrixError.transport("timeout")), AgentExit.erreur)
    XCTAssertEqual(
      AgentExit.code(for: MatrixError.http(status: 502, errcode: nil, message: nil)),
      AgentExit.erreur
    )
  }

  func testUnAgentDejaEnCoursASonPropreCode() {
    XCTAssertEqual(
      AgentExit.code(for: AgentError.dejaEnCours("cc tourne sur umbrel")),
      AgentExit.dejaEnCours
    )
  }

  func testSeulesLesErreursIrreparablesArretentLesRelances() {
    XCTAssertFalse(AgentExit.shouldRestart(after: AgentExit.identifiantsRefuses))
    XCTAssertFalse(AgentExit.shouldRestart(after: AgentExit.dejaEnCours))
    XCTAssertTrue(AgentExit.shouldRestart(after: AgentExit.erreur))
    XCTAssertTrue(AgentExit.shouldRestart(after: 139), "un plantage se relance")
  }
}
