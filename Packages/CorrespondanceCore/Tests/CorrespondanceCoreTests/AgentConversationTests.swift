import CorrespondanceMatrixClient
import XCTest
@testable import CorrespondanceCore

/// Un salon natif marqué `agent` devient un fil ; sans marqueur, il n'est rien.
final class AgentConversationTests: XCTestCase {
  private let me = "@meffysto:correspondance.local"

  private func marker(kind: String) -> MatrixEvent {
    MatrixEvent(
      type: AgentWire.conversationType, eventID: "$m", sender: me, stateKey: "",
      originServerTS: 1_700_000_000_000,
      content: .object([AgentWire.ConversationKey.kind: .string(kind)])
    )
  }

  private func member(_ userID: String, name: String, membership: String = "join") -> MatrixEvent {
    MatrixEvent(
      type: "m.room.member", eventID: "$\(userID)", sender: userID, stateKey: userID,
      originServerTS: 1_700_000_000_000,
      content: .object(["membership": .string(membership), "displayname": .string(name)])
    )
  }

  func testLeMarqueurFaitDuSalonUnTeteATeteAvecLAgent() throws {
    MatrixIdentity.registerAgents(["claude"])
    var model = MatrixRoomModel(roomID: "!a:s")
    let parser = MatrixSyncParser(selfUserID: me)
    parser.applyState(
      [marker(kind: "agent"), member(me, name: "meffysto"), member("@claude:correspondance.local", name: "claude", membership: "invite")],
      roomID: "!a:s", to: &model
    )
    XCTAssertEqual(model.network, .agent)
    let conversation = try XCTUnwrap(model.conversation(selfUserID: me))
    XCTAssertEqual(conversation.id, "agent:!a:s")
    XCTAssertEqual(conversation.title, "claude")
    XCTAssertFalse(conversation.isGroup)
    XCTAssertEqual(model.agentNames(selfUserID: me), ["claude"])
  }

  func testSansMarqueurUnSalonNatifNEstPasUnFil() {
    var model = MatrixRoomModel(roomID: "!b:s")
    MatrixSyncParser(selfUserID: me).applyState([member(me, name: "meffysto")], roomID: "!b:s", to: &model)
    XCTAssertNil(model.network)
    XCTAssertNil(model.conversation(selfUserID: me))
  }

  func testUnAgentDeLAnnuaireEstReconnuCommeAgent() {
    MatrixIdentity.registerAgents(["grok"])
    XCTAssertTrue(MatrixIdentity.isAgent("@grok:correspondance.local"))
    XCTAssertTrue(MatrixIdentity.isAgent("@cc:correspondance.local"), "le repli reste")
    XCTAssertFalse(MatrixIdentity.isAgent("@camille:correspondance.local"))
  }
}
