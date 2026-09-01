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
    ))
    XCTAssertTrue(hote.isRunning)

    hote.stop()
    XCTAssertFalse(hote.isRunning, "l'arrêt est immédiat : rien ne survit à l'app")
  }

  func testUnProcessusQuiTombeRedemarre() async throws {
    let hote = AgentProcessHost()
    // Un palier court : on éprouve le redémarrage, pas la patience.
    hote.backoff = .init(premier: 0.1, plafond: 0.1, essaisMax: 5)
    let journal = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
      hote.stop()
      try? FileManager.default.removeItem(at: journal)
    }

    try hote.start(.init(
      executable: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "exit 1"],
      logURL: journal
    ))
    // Le processus meurt aussitôt ; on laisse le harnais le relancer deux fois.
    try await Task.sleep(for: .milliseconds(700))
    XCTAssertGreaterThanOrEqual(hote.redemarrages, 2, "il doit avoir été relancé")
  }

  func testApresTropDeChutesOnRenonceEtOnLeDit() async throws {
    let hote = AgentProcessHost()
    hote.backoff = .init(premier: 0.05, plafond: 0.05, essaisMax: 3)
    let journal = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
      hote.stop()
      try? FileManager.default.removeItem(at: journal)
    }

    try hote.start(.init(
      executable: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "exit 3"],
      logURL: journal
    ))
    try await Task.sleep(for: .milliseconds(800))
    XCTAssertFalse(hote.isRunning)
    let abandon = try XCTUnwrap(hote.abandon, "on doit dire pourquoi on a cessé")
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
    ))
    hote.stop()
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertEqual(hote.redemarrages, 0, "arrêter n'est pas tomber")
    XCTAssertFalse(hote.isRunning)
  }

  func testLeJournalEstEcritEtRetrouvable() async throws {
    let hote = AgentProcessHost()
    let journal = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
      hote.stop()
      try? FileManager.default.removeItem(at: journal)
    }

    try hote.start(.init(
      executable: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "echo bonjour-du-journal; sleep 5"],
      logURL: journal
    ))
    XCTAssertEqual(hote.logURL, journal, "les réglages doivent pouvoir l'ouvrir")
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

  // MARK: - Toutes les chutes ne se valent pas

  /// Un mot de passe refusé par le Relais ne se répare pas tout seul :
  /// relancer huit fois ne fait que remplir le journal en donnant l'illusion
  /// d'un plantage à répétition. C'était le dernier défaut connu.
  func testUnRefusDIdentifiantsNeSeRelancePas() async throws {
    let hote = AgentProcessHost()
    hote.backoff = .init(premier: 0.05, plafond: 0.05, essaisMax: 5)
    let journal = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
      hote.stop()
      try? FileManager.default.removeItem(at: journal)
    }

    try hote.start(.init(
      executable: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "exit \(AgentExit.identifiantsRefuses)"],
      logURL: journal
    ))
    try await Task.sleep(for: .milliseconds(500))

    XCTAssertEqual(hote.redemarrages, 0, "on ne relance pas ce qui ne se répare pas tout seul")
    XCTAssertFalse(hote.isRunning)
    let abandon = try XCTUnwrap(hote.abandon)
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
      hote.stop()
      try? FileManager.default.removeItem(at: journal)
    }

    try hote.start(.init(
      executable: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "exit \(AgentExit.dejaEnCours)"],
      logURL: journal
    ))
    try await Task.sleep(for: .milliseconds(500))

    XCTAssertEqual(hote.redemarrages, 0)
    XCTAssertTrue(hote.abandon?.contains("deux fois") == true, hote.abandon ?? "")
  }

  /// Une chute ordinaire, elle, se relance : le Relais pas encore prêt, un
  /// moteur qui trébuche. C'est le cas courant et il ne doit pas changer.
  func testUneChuteOrdinaireSeRelanceToujours() async throws {
    let hote = AgentProcessHost()
    hote.backoff = .init(premier: 0.05, plafond: 0.05, essaisMax: 5)
    let journal = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
      hote.stop()
      try? FileManager.default.removeItem(at: journal)
    }

    try hote.start(.init(
      executable: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "exit 1"],
      logURL: journal
    ))
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertGreaterThanOrEqual(hote.redemarrages, 1, "une erreur ordinaire se réessaie")
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
