import XCTest
@testable import CorrespondanceCore

/// Ce que cc dit de lui-même, et ce qu'il envoie en mon nom : l'avis devient
/// une ligne système avec son geste, le message piloté garde ma bulle et
/// porte la marque.
final class AgentNoticeTests: XCTestCase {
  private let moi = "@meffysto:relais"
  private let salon = "!a:relais"

  private func parse(_ events: [String]) throws -> MatrixRoomModel {
    let json = """
    {"next_batch":"s1","rooms":{"join":{"\(salon)":{
      "state":{"events":[
        {"type":"m.bridge","state_key":"","content":{"protocol":{"id":"whatsappgo"},"channel":{"id":"120@g.us"}}}
      ]},
      "timeline":{"events":[\(events.joined(separator: ","))]}}}}}
    """
    let response = try JSONDecoder().decode(MatrixSyncResponse.self, from: Data(json.utf8))
    let parser = MatrixSyncParser(selfUserID: moi)
    var rooms: [String: MatrixRoomModel] = [:]
    parser.apply(response, to: &rooms)
    return try XCTUnwrap(rooms[salon])
  }

  func testUnAvisDevientUneLigneSystemeAvecSonGeste() throws {
    let model = try parse([
      """
      {"type":"fr.correspondance.agent.notice","event_id":"$n1","sender":"@cc:relais",
       "origin_server_ts":1800000000000,
       "content":{"agent":"cc","body":"Mon moteur ne répond plus.","reason":"engine_offline","action":"rescan"}}
      """,
    ])
    let message = try XCTUnwrap(model.messagesByID["$n1"])
    let notice = try XCTUnwrap(message.agentNotice)
    XCTAssertEqual(notice.agent, "cc")
    XCTAssertEqual(notice.reason, "engine_offline")
    XCTAssertEqual(notice.action, .rescan)
    XCTAssertTrue(notice.isFailure)
    XCTAssertTrue(message.isSystemEvent, "l'inbox et l'iPhone le traitent en événement")
    XCTAssertEqual(message.systemEventText, "Mon moteur ne répond plus.")
    XCTAssertFalse(message.isFromMe)
  }

  func testPasserLaMainNEstPasUnePanne() {
    XCTAssertFalse(AgentNotice(agent: "cc", body: "Je te passe la main.", reason: "handover").isFailure)
    XCTAssertFalse(AgentNotice(agent: "cc", body: "…").isFailure)
    XCTAssertTrue(AgentNotice(agent: "cc", body: "…", reason: "timeout").isFailure)
  }

  func testUnMessagePiloteResteLeMienEtPorteLaMarque() throws {
    let model = try parse([
      """
      {"type":"m.room.message","event_id":"$p1","sender":"\(moi)","origin_server_ts":1800000000000,
       "content":{"msgtype":"m.text","body":"Oui, toujours disponible.","fr.correspondance.agent.piloted":true}}
      """,
      """
      {"type":"m.room.message","event_id":"$p2","sender":"\(moi)","origin_server_ts":1800000001000,
       "content":{"msgtype":"m.text","body":"Et celui-là, c'est moi."}}
      """,
    ])
    XCTAssertTrue(try XCTUnwrap(model.messagesByID["$p1"]).isPiloted)
    XCTAssertTrue(try XCTUnwrap(model.messagesByID["$p1"]).isFromMe)
    XCTAssertFalse(try XCTUnwrap(model.messagesByID["$p2"]).isPiloted)
  }

  func testUneLigneEnBaseSansLaCleSeRelitEncore() throws {
    // Les messages déjà rangés n'ont pas `piloted` : ils doivent se relire.
    let json = """
    {"id":"$x","conversationID":"whatsapp:!a:relais","network":"whatsapp","text":"salut",
     "sentAt":0,"isFromMe":true,"isPending":false,"attachments":[],"reactions":[],
     "editHistory":[],"isRetracted":false}
    """
    let message = try JSONDecoder().decode(ChatMessage.self, from: Data(json.utf8))
    XCTAssertFalse(message.isPiloted)
    XCTAssertNil(message.agentNotice)
  }
}
