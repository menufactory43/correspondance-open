import CorrespondanceMatrixClient
import XCTest

@testable import CorrespondanceAgentKit

/// Ce que `cc` doit garantir une fois la machine crypto branchée.
final class AgentChiffrementTests: XCTestCase {

  /// Le magasin de clés vit **sous le dossier d'amorce**, à côté de
  /// `config.json`. C'est ce qui le fait suivre `CORRESPONDANCE_HOME` sans
  /// qu'on ait à y penser : un essai ne mélange jamais ses clés avec celles du
  /// cc de production.
  func testLeMagasinDeClesVitSousLeDossierDAmorce() {
    let home = AgentHome.directory(
      agent: "cc", home: URL(fileURLWithPath: "/Users/x"),
      environment: ["CORRESPONDANCE_HOME": "unclic"])
    let magasin = AgentCryptoStore.dossier(
      home: home, userID: "@cc:unclic.local", deviceID: "8jBhGLCJ0V")
    XCTAssertEqual(
      magasin.path,
      "/Users/x/.correspondance-agent-unclic/crypto/_cc_unclic_local-8jBhGLCJ0V",
      "le magasin doit être sous le dossier d'amorce de l'essai, jamais sous celui de la prod")
  }

  /// Deux appareils du même compte ont deux magasins : c'est exactement ce que
  /// le partage de clés doit franchir, et les confondre corromprait les deux.
  func testDeuxAppareilsDuMemeCompteOntDeuxMagasins() {
    let home = URL(fileURLWithPath: "/tmp/h")
    XCTAssertNotEqual(
      AgentCryptoStore.dossier(home: home, userID: "@cc:s", deviceID: "AAA"),
      AgentCryptoStore.dossier(home: home, userID: "@cc:s", deviceID: "BBB"))
  }

  /// Un `m.room.encrypted` qui traverse le `/sync` sans avoir été lu, c'est un
  /// ordre perdu. La phase 4 l'a mesuré : cc restait muet, indiscernable d'un
  /// agent occupé. Le journal doit le dire — **une fois**, pas à chaque tour.
  func testUnMessageIllisibleSeDitUneFois() async {
    let lignes = LigneCollector()
    let agent = Agent(
      config: .example(), backend: BackendMuet(),
      stateURL: URL(fileURLWithPath: "/dev/null"),
      log: { ligne in lignes.ajouter(ligne) })
    let salon = MatrixSyncResponse.JoinedRoom(
      timeline: .init(events: [
        MatrixEvent(type: "m.room.encrypted", eventID: "$1", sender: "@moi:s"),
        MatrixEvent(type: "m.room.encrypted", eventID: "$2", sender: "@moi:s"),
      ]))
    await agent.signalerLesIllisibles(roomID: "!r:s", room: salon, moi: "@cc:s")
    await agent.signalerLesIllisibles(roomID: "!r:s", room: salon, moi: "@cc:s")
    let dites = lignes.tout().filter { $0.contains("que je ne sais pas lire") }
    XCTAssertEqual(dites.count, 1, "la même alerte ne doit pas remplir le journal à chaque /sync")
    XCTAssertTrue(dites[0].contains("2 message(s)"), "l'alerte doit dire combien : \(dites)")
  }

  /// Nos propres `m.room.encrypted` ne sont pas un problème : on ne se relit pas.
  func testNosProprresMessagesNeDeclenchentRien() async {
    let lignes = LigneCollector()
    let agent = Agent(
      config: .example(), backend: BackendMuet(),
      stateURL: URL(fileURLWithPath: "/dev/null"),
      log: { ligne in lignes.ajouter(ligne) })
    let salon = MatrixSyncResponse.JoinedRoom(
      timeline: .init(events: [
        MatrixEvent(type: "m.room.encrypted", eventID: "$1", sender: "@cc:s")
      ]))
    await agent.signalerLesIllisibles(roomID: "!r:s", room: salon, moi: "@cc:s")
    XCTAssertTrue(lignes.tout().isEmpty, "un agent ne s'alerte pas de ses propres envois")
  }
}

private final class LigneCollector: @unchecked Sendable {
  private let verrou = NSLock()
  private var lignes: [String] = []
  func ajouter(_ ligne: String) {
    verrou.lock()
    lignes.append(ligne)
    verrou.unlock()
  }
  func tout() -> [String] {
    verrou.lock()
    defer { verrou.unlock() }
    return lignes
  }
}

private struct BackendMuet: AgentBackend {
  func run(prompt: String, cwd: String?, sessionID: String?, permissionSpool: URL?) async throws
    -> AgentTurn
  {
    AgentTurn(text: "", sessionID: nil)
  }
}
