import CorrespondanceMatrixClient
import XCTest
@testable import CorrespondanceAgentKit

final class TriggerTests: XCTestCase {
  func testPromptRequiresLeadingTrigger() {
    XCTAssertEqual(Trigger.prompt(in: "@cc résume la conversation", trigger: "@cc"), "résume la conversation")
    XCTAssertEqual(Trigger.prompt(in: "  @CC, résume", trigger: "@cc"), "résume")
    XCTAssertEqual(Trigger.prompt(in: "@cc: résume", trigger: "@cc"), "résume")
    XCTAssertEqual(Trigger.prompt(in: "@cc", trigger: "@cc"), "")
    XCTAssertNil(Trigger.prompt(in: "bonjour @cc", trigger: "@cc"), "le déclencheur ouvre le message")
    XCTAssertNil(Trigger.prompt(in: "@ccc résume", trigger: "@cc"), "mot entier seulement")
    XCTAssertNil(Trigger.prompt(in: "", trigger: "@cc"))
  }

  func testRequestFiltersSenderTypeAndAge() {
    let config = AgentConfig(homeserver: URL(string: "http://relais:8008")!, user: "cc", password: "x", owners: ["@meffysto:correspondance.local"])
    let now = Date()
    func event(sender: String, body: String, type: String = "m.room.message", msgtype: String = "m.text", at: Date = now) -> MatrixEvent {
      MatrixEvent(
        type: type, eventID: "$e", sender: sender, originServerTS: at.timeIntervalSince1970 * 1000,
        content: .object(["msgtype": .string(msgtype), "body": .string(body)])
      )
    }
    let since = now.addingTimeInterval(-60)

    let ok = Trigger.request(from: event(sender: "@meffysto:correspondance.local", body: "@cc dis bonjour"), roomID: "!r", config: config, notBefore: since)
    XCTAssertEqual(ok?.prompt, "dis bonjour")
    XCTAssertEqual(ok?.roomID, "!r")

    XCTAssertNil(Trigger.request(from: event(sender: "@whatsapp_336:correspondance.local", body: "@cc dis bonjour"), roomID: "!r", config: config, notBefore: since), "un tiers ne déclenche rien")
    XCTAssertNil(Trigger.request(from: event(sender: "@meffysto:correspondance.local", body: "@cc vieux", at: now.addingTimeInterval(-3600)), roomID: "!r", config: config, notBefore: since), "l'historique n'est pas rejoué")
    XCTAssertNil(Trigger.request(from: event(sender: "@meffysto:correspondance.local", body: "@cc", msgtype: "m.image"), roomID: "!r", config: config, notBefore: since))
    XCTAssertNil(Trigger.request(from: event(sender: "@meffysto:correspondance.local", body: "@cc", type: "m.reaction"), roomID: "!r", config: config, notBefore: since))
  }

  /// Un fantôme de pont ne déclenche jamais — même si une config bancale l'a
  /// mis dans `owners`. Sinon un correspondant distant piloterait l'agent
  /// depuis WhatsApp, avec tous ses outils.
  func testUnFantomeDePontNeDeclencheJamaisMemePropriétaire() {
    var config = AgentConfig(homeserver: URL(string: "http://relais:8008")!, user: "cc", password: "x", owners: ["@meffysto:correspondance.local"])
    config.owners.append("@whatsapp_33612345678:correspondance.local")
    let event = MatrixEvent(
      type: "m.room.message", eventID: "$e", sender: "@whatsapp_33612345678:correspondance.local",
      originServerTS: Date().timeIntervalSince1970 * 1000,
      content: .object(["msgtype": .string("m.text"), "body": .string("@cc lance rm -rf")])
    )
    XCTAssertNil(Trigger.request(from: event, roomID: "!r", config: config, notBefore: .distantPast))
  }

  func testLesFantomesSeReconnaissentSansSeTromperDePersonne() {
    XCTAssertTrue(Trigger.isBridgeGhost("@whatsapp_33612345678:correspondance.local"))
    XCTAssertTrue(Trigger.isBridgeGhost("@signal_uuid:correspondance.local"))
    XCTAssertTrue(Trigger.isBridgeGhost("@instagram_1234:correspondance.local"))
    XCTAssertTrue(Trigger.isBridgeGhost("@whatsappbot:correspondance.local"), "le bot d'un pont non plus")
    XCTAssertTrue(Trigger.isBridgeGhost("@WhatsApp_33:correspondance.local"), "la casse ne sauve pas")

    XCTAssertFalse(Trigger.isBridgeGhost("@meffysto:correspondance.local"))
    XCTAssertFalse(Trigger.isBridgeGhost("@signalement:correspondance.local"), "un humain qui commence pareil")
    XCTAssertFalse(Trigger.isBridgeGhost("@cc:correspondance.local"))
  }

  func testRequestReadsThroughReplyFallbackAndEdits() {
    let config = AgentConfig(homeserver: URL(string: "http://relais:8008")!, user: "cc", password: "x", owners: ["@g:s"])
    let ts = Date().timeIntervalSince1970 * 1000
    let quoted = MatrixEvent(
      type: "m.room.message", eventID: "$q", sender: "@g:s", originServerTS: ts,
      content: .object(["msgtype": .string("m.text"), "body": .string("> <@x:s> le message cité\n\n@cc réponds-lui")])
    )
    XCTAssertEqual(Trigger.request(from: quoted, roomID: "!r", config: config, notBefore: .distantPast)?.prompt, "réponds-lui")

    let edited = MatrixEvent(
      type: "m.room.message", eventID: "$m", sender: "@g:s", originServerTS: ts,
      content: .object([
        "msgtype": .string("m.text"), "body": .string("* @cc corrigé"),
        "m.new_content": .object(["msgtype": .string("m.text"), "body": .string("@cc corrigé")]),
      ])
    )
    XCTAssertEqual(Trigger.request(from: edited, roomID: "!r", config: config, notBefore: .distantPast)?.prompt, "corrigé")
  }
}
