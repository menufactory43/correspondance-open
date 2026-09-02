import CorrespondanceMatrixClient
import XCTest
@testable import CorrespondanceAgentKit

/// Un tête-à-tête marqué par l'app : tout message d'un propriétaire est une
/// demande, sans mention. Le reste ne bouge pas — ni fantôme, ni tiers.
final class TeteATeteTests: XCTestCase {
  private var config: AgentConfig {
    var config = AgentConfig(
      homeserver: URL(string: "http://relais:8008")!, user: "claude", password: "x",
      owners: ["@meffysto:correspondance.local"]
    )
    config.trigger = "@claude"
    return config
  }

  private func event(sender: String, body: String) -> MatrixEvent {
    MatrixEvent(
      type: "m.room.message", eventID: "$e", sender: sender,
      originServerTS: Date().timeIntervalSince1970 * 1000,
      content: .object(["msgtype": .string("m.text"), "body": .string(body)])
    )
  }

  func testSansMentionLeMessageEstUneDemandeDansUnTeteATete() {
    let since = Date().addingTimeInterval(-60)
    let demande = Trigger.request(
      from: event(sender: "@meffysto:correspondance.local", body: "quelle heure est-il ?"),
      roomID: "!r", config: config, notBefore: since, requiresTrigger: false
    )
    XCTAssertEqual(demande?.prompt, "quelle heure est-il ?")
    // La mention, si elle y est, se retire quand même.
    let mentionne = Trigger.request(
      from: event(sender: "@meffysto:correspondance.local", body: "@claude quelle heure ?"),
      roomID: "!r", config: config, notBefore: since, requiresTrigger: false
    )
    XCTAssertEqual(mentionne?.prompt, "quelle heure ?")
  }

  func testAilleursLaMentionResteObligatoire() {
    let since = Date().addingTimeInterval(-60)
    XCTAssertNil(Trigger.request(
      from: event(sender: "@meffysto:correspondance.local", body: "quelle heure est-il ?"),
      roomID: "!r", config: config, notBefore: since
    ))
  }

  func testUnTiersNeDeclencheRienMemeSansMentionRequise() {
    let since = Date().addingTimeInterval(-60)
    XCTAssertNil(Trigger.request(
      from: event(sender: "@whatsapp_336:correspondance.local", body: "salut"),
      roomID: "!r", config: config, notBefore: since, requiresTrigger: false
    ))
    XCTAssertNil(Trigger.request(
      from: event(sender: "@camille:correspondance.local", body: "salut"),
      roomID: "!r", config: config, notBefore: since, requiresTrigger: false
    ))
  }
}
