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

  func testUneCorrectionEnAttenteVenueDUnAutreNeSAppliquePas() throws {
    let model = try parse([
      edit("$2", sender: moi, target: "$1", text: "piraté", at: 1_800_000_060_000),
      message("$1", sender: elle, text: "a demian", at: 1_800_000_000_000),
    ])
    XCTAssertEqual(model.messagesByID["$1"]?.text, "a demian")
    XCTAssertNil(model.messagesByID["$1"]?.editedAt)
  }

  func testUnMessageCorrigeQuiRepasseGardeSaCorrection() throws {
    let parser = MatrixSyncParser(selfUserID: moi)
    var rooms: [String: MatrixRoomModel] = [:]
    let premier = """
    {"next_batch":"s1","rooms":{"join":{"!a:relais":{
      "state":{"events":[{"type":"m.bridge","state_key":"","content":{"protocol":{"id":"whatsappgo"}}}]},
      "timeline":{"events":[\(message("$1", sender: elle, text: "a demian", at: 1_800_000_000_000)),
        \(edit("$2", sender: elle, target: "$1", text: "à demain", at: 1_800_000_060_000))]}}}}}
    """
    parser.apply(try JSONDecoder().decode(MatrixSyncResponse.self, from: Data(premier.utf8)), to: &rooms)
    // Le sync suivant relivre l'original seul — une page de backfill, un sync initial.
    let relivraison = """
    {"next_batch":"s2","rooms":{"join":{"!a:relais":{
      "timeline":{"events":[\(message("$1", sender: elle, text: "a demian", at: 1_800_000_000_000))]}}}}}
    """
    parser.apply(try JSONDecoder().decode(MatrixSyncResponse.self, from: Data(relivraison.utf8)), to: &rooms)
    let message = try XCTUnwrap(rooms["!a:relais"]?.messagesByID["$1"])
    XCTAssertEqual(message.text, "à demain")
    XCTAssertNotNil(message.editedAt)
    XCTAssertEqual(message.editHistory, ["a demian"])
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

  /// La RÉCEPTION d'un `m.replace` vaut partout — un correspondant qui corrige
  /// son message le corrige chez nous, quel que soit le réseau. C'est l'ENVOI
  /// qui se restreint, et c'est `NetworkCapabilities` qui en décide seul : les
  /// quatre ponts remontent notre correction, iMessage passe par ailleurs. Le
  /// détail — et surtout les délais — se lit dans `NetworkCapabilitiesTests`.
  func testLEnvoiDUneCorrectionSuitLaTableDesCapacites() {
    XCTAssertEqual(
      MessageNetwork.allCases.filter(\.supportsEditing),
      [.signal, .whatsapp, .instagram, .messenger, .twitter, .selfNote, .agent]
    )
  }
}
