import XCTest
@testable import CorrespondanceCore

/// Une proposition de « cc » entre dans le fil sans en devenir un message :
/// elle ne compte pas comme non-lu, elle ne résume pas la ligne d'inbox, et
/// elle ne fait pas remonter la conversation dans la file.
final class AgentProposalTests: XCTestCase {
  private let moi = "@meffysto:relais"
  private let salon = "!a:relais"

  private func sync(_ events: String, notifications: Int? = nil) throws -> MatrixSyncResponse {
    let unread = notifications.map { ",\"unread_notifications\":{\"notification_count\":\($0)}" } ?? ""
    let json = """
    {"next_batch":"s1","rooms":{"join":{"\(salon)":{
      "state":{"events":[
        {"type":"m.bridge","state_key":"","content":{"protocol":{"id":"whatsappgo"},"channel":{"id":"120@g.us"}}},
        {"type":"m.room.name","state_key":"","content":{"name":"Les voisins"}}
      ]},
      "timeline":{"events":[\(events)]}\(unread)}}}}
    """
    return try JSONDecoder().decode(MatrixSyncResponse.self, from: Data(json.utf8))
  }

  private func parse(_ events: [String], notifications: Int? = nil) throws -> MatrixRoomModel {
    let parser = MatrixSyncParser(selfUserID: moi)
    var rooms: [String: MatrixRoomModel] = [:]
    parser.apply(try sync(events.joined(separator: ","), notifications: notifications), to: &rooms)
    return try XCTUnwrap(rooms[salon])
  }

  private func message(_ id: String, _ body: String, at ts: Int) -> String {
    """
    {"type":"m.room.message","event_id":"\(id)","sender":"@whatsapp_lid-1:relais",
     "origin_server_ts":\(ts),"content":{"msgtype":"m.text","body":"\(body)"}}
    """
  }

  private func proposal(
    _ id: String = "$prop",
    _ body: String = "Je passe vers 18 h, ça vous va ?",
    at ts: Int = 1_800_000_500_000,
    agent: String = "cc",
    inReplyTo: String = "$m1"
  ) -> String {
    """
    {"type":"fr.correspondance.agent.proposal","event_id":"\(id)","sender":"@cc:relais",
     "origin_server_ts":\(ts),
     "content":{"body":"\(body)","agent":"\(agent)",
       "m.relates_to":{"m.in_reply_to":{"event_id":"\(inReplyTo)"}}}}
    """
  }

  // MARK: - Analyse

  func testLaPropositionDevientUnMessagePorteurDeBrouillon() throws {
    let model = try parse([proposal()])
    let message = try XCTUnwrap(model.messagesByID["$prop"])
    let brouillon = try XCTUnwrap(message.agentProposal)
    XCTAssertEqual(brouillon.agent, "cc")
    XCTAssertEqual(brouillon.text, "Je passe vers 18 h, ça vous va ?")
    XCTAssertEqual(brouillon.inReplyToEventID, "$m1")
    XCTAssertTrue(message.isAgentProposal)
    XCTAssertFalse(message.isFromMe)
    XCTAssertEqual(message.text, "")
  }

  func testSansChampAgentLeNomVientDeLExpediteur() throws {
    let model = try parse([proposal(agent: "")])
    XCTAssertEqual(model.messagesByID["$prop"]?.agentProposal?.agent, "cc")
  }

  func testUnePropositionVideNEntrePasDansLeFil() throws {
    let model = try parse([proposal("$prop", "")])
    XCTAssertNil(model.messagesByID["$prop"])
  }

  func testUneRedactionRetireLaProposition() throws {
    let model = try parse([
      proposal(),
      """
      {"type":"m.room.redaction","event_id":"$r","sender":"@cc:relais",
       "origin_server_ts":1800000600000,"redacts":"$prop","content":{}}
      """,
    ])
    XCTAssertNil(model.messagesByID["$prop"])
    XCTAssertTrue(model.pendingDeletions.contains("$prop"))
  }

  // MARK: - Ce qu'une proposition ne fait JAMAIS

  func testLaPropositionNeCompteJamaisCommeNonLu() throws {
    // Le Relais ne notifie pas un type d'event qu'aucune règle push ne vise :
    // le compteur reste celui que le salon portait.
    let model = try parse([message("$m1", "Tu viens ?", at: 1_800_000_000_000), proposal()], notifications: 1)
    XCTAssertEqual(model.unreadCount, 1)
    let apres = try parse([proposal("$p2", at: 1_800_000_900_000)], notifications: 0)
    XCTAssertEqual(apres.unreadCount, 0)
  }

  func testLApercuDeLInboxIgnoreLaProposition() throws {
    let model = try parse([
      message("$m1", "Tu viens ?", at: 1_800_000_000_000),
      proposal(at: 1_800_000_500_000),
    ])
    let conversation = try XCTUnwrap(model.conversation(selfUserID: moi))
    XCTAssertEqual(conversation.preview, "Tu viens ?")
    XCTAssertEqual(model.lastListedMessage?.id, "$m1")
  }

  func testLaPropositionNeFaitPasRemonterLeFilDansLaFile() throws {
    let model = try parse([
      message("$m1", "Tu viens ?", at: 1_800_000_000_000),
      proposal(at: 1_900_000_000_000),
    ])
    let conversation = try XCTUnwrap(model.conversation(selfUserID: moi))
    XCTAssertEqual(conversation.lastMessageAt, Date(timeIntervalSince1970: 1_800_000_000))
    XCTAssertEqual(model.lastEventAt, Date(timeIntervalSince1970: 1_800_000_000))
  }

  func testUnFilQuiNAQuUnePropositionNAToujoursRienADire() throws {
    let model = try parse([proposal()])
    let conversation = try XCTUnwrap(model.conversation(selfUserID: moi))
    XCTAssertEqual(conversation.preview, "Écrire sur WhatsApp…")
  }

  func testLApercuDUnePropositionEstMuet() {
    var message = ChatMessage(
      id: "$p", conversationID: "whatsapp:!a:relais", network: .whatsapp,
      text: "", sentAt: Date(), isFromMe: false
    )
    message.agentProposal = AgentProposal(agent: "cc", text: "Bonjour")
    XCTAssertEqual(message.sidebarPreviewText, "")
    XCTAssertFalse(message.hasVisibleBody)
    XCTAssertFalse(message.isEmojiOnly)
  }

  // MARK: - Masquage

  func testLeMasquageIciRetireLaProposition() throws {
    let model = try parse([
      message("$m1", "Tu viens ?", at: 1_800_000_000_000),
      proposal(),
    ])
    let visibles = HiddenMessageStore.visible(model.sortedMessages, hiddenIDs: ["$prop"])
    XCTAssertEqual(visibles.map(\.id), ["$m1"])
  }

  // MARK: - Fil

  func testLaPropositionSEcritSeuleDansLeFil() throws {
    let model = try parse([
      message("$m1", "Tu viens ?", at: 1_800_000_000_000),
      proposal(at: 1_800_000_010_000),
      message("$m2", "Alors ?", at: 1_800_000_020_000),
    ])
    let groupes = MessageGrouping.groups(for: model.sortedMessages, showsSenderNames: true)
    XCTAssertEqual(groupes.map { $0.messages.map(\.id) }, [["$m1"], ["$prop"], ["$m2"]])
    // Pas de nom d'auteur au-dessus d'une carte : elle porte le sien.
    XCTAssertNil(groupes[1].senderLabel)
  }
}
