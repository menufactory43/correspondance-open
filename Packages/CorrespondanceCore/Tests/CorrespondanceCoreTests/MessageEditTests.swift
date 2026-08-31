import XCTest
@testable import CorrespondanceCore

/// Une modification (`m.replace`) n'est pas un message de plus : elle corrige
/// celui qu'elle vise, dans n'importe quel ordre d'arrivée.
final class MessageEditTests: XCTestCase {
  private let moi = "@meffysto:relais"
  private let elle = "@whatsapp_lid-1:relais"

  private func parse(_ events: [String]) throws -> MatrixRoomModel {
    let json = """
    {"next_batch":"s1","rooms":{"join":{"!a:relais":{
      "state":{"events":[{"type":"m.bridge","state_key":"","content":{"protocol":{"id":"whatsappgo"}}}]},
      "timeline":{"events":[\(events.joined(separator: ","))]}}}}}
    """
    let parser = MatrixSyncParser(selfUserID: moi)
    var rooms: [String: MatrixRoomModel] = [:]
    parser.apply(try JSONDecoder().decode(MatrixSyncResponse.self, from: Data(json.utf8)), to: &rooms)
    return try XCTUnwrap(rooms["!a:relais"])
  }

  private func message(_ id: String, sender: String, text: String, at ts: Int) -> String {
    """
    {"type":"m.room.message","event_id":"\(id)","sender":"\(sender)","origin_server_ts":\(ts),
     "content":{"msgtype":"m.text","body":"\(text)"}}
    """
  }

  private func edit(_ id: String, sender: String, target: String, text: String, at ts: Int) -> String {
    """
    {"type":"m.room.message","event_id":"\(id)","sender":"\(sender)","origin_server_ts":\(ts),
     "content":{"msgtype":"m.text","body":"* \(text)",
       "m.new_content":{"msgtype":"m.text","body":"\(text)"},
       "m.relates_to":{"rel_type":"m.replace","event_id":"\(target)"}}}
    """
  }

  func testLaModificationCorrigeLeMessageSansEnCreerUnAutre() throws {
    let model = try parse([
      message("$1", sender: elle, text: "a demian", at: 1_800_000_000_000),
      edit("$2", sender: elle, target: "$1", text: "à demain", at: 1_800_000_060_000),
    ])
    XCTAssertEqual(model.messagesByID.count, 1)
    let message = try XCTUnwrap(model.messagesByID["$1"])
    XCTAssertEqual(message.text, "à demain")
    XCTAssertNotNil(message.editedAt)
    XCTAssertEqual(message.editHistory, ["a demian"])
  }

  func testUneModificationArriveeAvantSaCibleLAttend() throws {
    let model = try parse([
      edit("$2", sender: elle, target: "$1", text: "à demain", at: 1_800_000_060_000),
      message("$1", sender: elle, text: "a demian", at: 1_800_000_000_000),
    ])
    XCTAssertEqual(model.messagesByID["$1"]?.text, "à demain")
    XCTAssertTrue(model.pendingEdits.isEmpty)
  }

  func testSeuleLaDerniereCorrectionCompte() throws {
    let model = try parse([
      message("$1", sender: elle, text: "un", at: 1_800_000_000_000),
      edit("$2", sender: elle, target: "$1", text: "deux", at: 1_800_000_010_000),
      edit("$3", sender: elle, target: "$1", text: "trois", at: 1_800_000_020_000),
    ])
    XCTAssertEqual(model.messagesByID["$1"]?.text, "trois")
    XCTAssertEqual(model.messagesByID["$1"]?.editHistory, ["un", "deux"])
  }

  func testUneCorrectionPlusAncienneArriveeApresNeDefaitPasLaDerniere() throws {
    let model = try parse([
      message("$1", sender: elle, text: "un", at: 1_800_000_000_000),
      edit("$3", sender: elle, target: "$1", text: "trois", at: 1_800_000_020_000),
      edit("$2", sender: elle, target: "$1", text: "deux", at: 1_800_000_010_000),
    ])
    XCTAssertEqual(model.messagesByID["$1"]?.text, "trois")
  }

  func testPersonneNeCorrigeLeMessageDUnAutre() throws {
    let model = try parse([
      message("$1", sender: elle, text: "un", at: 1_800_000_000_000),
      edit("$2", sender: moi, target: "$1", text: "pirate", at: 1_800_000_010_000),
    ])
    XCTAssertEqual(model.messagesByID["$1"]?.text, "un")
    XCTAssertNil(model.messagesByID["$1"]?.editedAt)
  }

  func testLeRepliEtoileNEstJamaisCeQuOnAffiche() throws {
    let sansNewContent = """
    {"type":"m.room.message","event_id":"$2","sender":"\(elle)","origin_server_ts":1800000060000,
     "content":{"msgtype":"m.text","body":"* à demain",
       "m.relates_to":{"rel_type":"m.replace","event_id":"$1"}}}
    """
    let model = try parse([
      message("$1", sender: elle, text: "a demian", at: 1_800_000_000_000),
      sansNewContent,
    ])
    XCTAssertEqual(model.messagesByID["$1"]?.text, "à demain")
  }

  // MARK: - La capacité, réseau par réseau

  func testSeulsLesReseauxQuiSaventLeFaireLeProposent() {
    XCTAssertTrue(MessageNetwork.whatsapp.supportsEditing)
    XCTAssertTrue(MessageNetwork.signal.supportsEditing)
    // Meta n'expose aucune modification de DM Instagram : le pont n'a rien à
    // relayer, et une correction ne se verrait que chez nous.
    XCTAssertFalse(MessageNetwork.instagram.supportsEditing)
    XCTAssertTrue(MessageNetwork.selfNote.supportsEditing)
    // iMessage sait le faire, mais par l'automatisation Messages, pas ici.
    XCTAssertFalse(MessageNetwork.iMessage.supportsEditing)
  }
}
