import XCTest

@testable import CorrespondanceCore
@testable import CorrespondanceMatrixClient

/// Trouvé en vrai : la garde « un agent vit ailleurs » ne lisait que le status
/// de la room console, que le cc d'hier sur le NUC ne publiait pas — l'app a
/// activé un second cc, et les deux ont répondu. Le serveur, lui, voit les
/// sessions ; c'est sur elles que la décision se prend.
final class AgentSessionsTests: XCTestCase {
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  typealias Device = MatrixClient.UserDevice

  func device(_ name: String?, seenAgo: TimeInterval?, id: String = "ABCDEF") -> Device {
    Device(deviceID: id, displayName: name, lastSeen: seenAgo.map { now.addingTimeInterval(-$0) })
  }

  func testUnAgentDHierSansStatusEstQuandMemeVuParSaSession() {
    let devices = [device("Correspondance (agent)", seenAgo: 37)]
    XCTAssertEqual(AgentSessions.elsewhere(devices, here: "mon-mac", now: now), "Correspondance (agent), vue il y a 37 s")
  }

  func testMaPropreSessionNeCompteJamais() {
    let devices = [device(MatrixClient.agentDeviceDisplayName(host: "mon-mac"), seenAgo: 5)]
    XCTAssertNil(AgentSessions.elsewhere(devices, here: "mon-mac", now: now))
  }

  func testUneSessionDUneAutreMachineRefuse() {
    let devices = [device(MatrixClient.agentDeviceDisplayName(host: "umbrel"), seenAgo: 5)]
    XCTAssertEqual(AgentSessions.elsewhere(devices, here: "mon-mac", now: now), "Correspondance agent · umbrel, vue il y a 5 s")
  }

  func testUnCadavreNeBloquePas() {
    let devices = [device("Correspondance (agent)", seenAgo: 106_672), device("Correspondance (Mac)", seenAgo: nil)]
    XCTAssertNil(AgentSessions.elsewhere(devices, here: "mon-mac", now: now))
  }

  func testUneSessionSansNomEstNommeeParSonIdentifiant() {
    let devices = [device(nil, seenAgo: 10, id: "QHKAKFMBOB")]
    XCTAssertEqual(AgentSessions.elsewhere(devices, here: "mon-mac", now: now), "session QHKAKFMBOB, vue il y a 10 s")
  }

  func testLeCadavreEtLeVivantMelanges() {
    let devices = [
      device("Correspondance (Mac)", seenAgo: 106_672),
      device(MatrixClient.agentDeviceDisplayName(host: "mon-mac"), seenAgo: 96),
      device("Correspondance (agent)", seenAgo: 37),
    ]
    XCTAssertEqual(AgentSessions.elsewhere(devices, here: "mon-mac", now: now), "Correspondance (agent), vue il y a 37 s")
  }
}
