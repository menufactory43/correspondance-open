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

/// Où la mention est-elle encore obligatoire ? La question se décide seule,
/// hors de l'agent, parce qu'une erreur ici est soit une friction permanente,
/// soit un agent qui répond à tout ce qu'on écrit à quelqu'un d'autre.
final class MentionPolicyTests: XCTestCase {
  func testUnSalonQuiEstALuiNeDemandePasQuOnLeNomme() {
    XCTAssertFalse(MentionPolicy.requiresTrigger(binding: nil, isTeteATete: true, isConsole: false))
    XCTAssertFalse(MentionPolicy.requiresTrigger(binding: nil, isTeteATete: false, isConsole: true))
  }

  /// La note à soi, un fil bridgé : l'agent y est invité, il n'y est pas chez
  /// lui. Sans mention, il répondrait à ce qu'on écrit à quelqu'un d'autre.
  func testPartoutAilleursLaMentionResteObligatoire() {
    XCTAssertTrue(MentionPolicy.requiresTrigger(binding: nil, isTeteATete: false, isConsole: false))
    XCTAssertTrue(MentionPolicy.requiresTrigger(
      binding: AgentConfig.RoomBinding(cwd: "/tmp"), isTeteATete: false, isConsole: false
    ))
  }

  /// La config tranche, dans les deux sens : ouvrir un salon ordinaire…
  func testLaConfigPeutOuvrirUnSalonOrdinaire() {
    XCTAssertFalse(MentionPolicy.requiresTrigger(
      binding: AgentConfig.RoomBinding(mention: false), isTeteATete: false, isConsole: false
    ))
  }

  /// …comme refermer un tête-à-tête ou une console dont on veut la paix.
  func testLaConfigPeutRefermerUnTeteATete() {
    XCTAssertTrue(MentionPolicy.requiresTrigger(
      binding: AgentConfig.RoomBinding(mention: true), isTeteATete: true, isConsole: true
    ))
  }

  /// Le choix voyage par la console, comme le reste de la config.
  func testLeChoixTraverseLEventDeConfig() throws {
    var remote = AgentRemoteConfig(agent: "cc")
    remote.rooms = ["!r:relais": AgentConfig.RoomBinding(cwd: "/depot", mention: false)]
    let relu = try XCTUnwrap(AgentRemoteConfig(content: remote.content()))
    XCTAssertEqual(relu.rooms?["!r:relais"]?.mention, false)
    XCTAssertEqual(relu.rooms?["!r:relais"]?.cwd, "/depot")
    // Rien de dit : rien d'écrit, et le défaut reste au lecteur.
    var muet = AgentRemoteConfig(agent: "cc")
    muet.rooms = ["!r:relais": AgentConfig.RoomBinding(cwd: "/depot")]
    XCTAssertNil(try XCTUnwrap(AgentRemoteConfig(content: muet.content())).rooms?["!r:relais"]?.mention)
  }
}
