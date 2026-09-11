import XCTest
@testable import CorrespondanceCore

/// L'accusé de lecture se pose sur le DERNIER événement du fil, pas sur le
/// dernier message visible : le serveur compte les notifications après
/// l'accusé, et une suppression arrivée après le dernier message visible
/// laissait « 2 non lus » pour toujours (groupe Signal, 11 sept.).
final class LatestEventTests: XCTestCase {
  private let moi = "@meffysto:relais"
  private let lui = "@signal_186ab242:relais"

  private func parse(_ events: [String], into rooms: inout [String: MatrixRoomModel]) throws {
    let json = """
    {"next_batch":"s1","rooms":{"join":{"!a:relais":{
      "state":{"events":[{"type":"m.bridge","state_key":"","content":{"protocol":{"id":"signal"}}}]},
      "timeline":{"events":[\(events.joined(separator: ","))]}}}}}
    """
    MatrixSyncParser(selfUserID: moi)
      .apply(try JSONDecoder().decode(MatrixSyncResponse.self, from: Data(json.utf8)), to: &rooms)
  }

  private func message(_ id: String, at ts: Int) -> String {
    """
    {"type":"m.room.message","event_id":"\(id)","sender":"\(lui)","origin_server_ts":\(ts),
     "content":{"msgtype":"m.text","body":"salut"}}
    """
  }

  private func redaction(_ id: String, of target: String, at ts: Int) -> String {
    """
    {"type":"m.room.redaction","event_id":"\(id)","sender":"\(lui)","origin_server_ts":\(ts),
     "redacts":"\(target)","content":{}}
    """
  }

  func testLaSuppressionDuDernierMessageEstLeDernierEvenement() throws {
    var rooms: [String: MatrixRoomModel] = [:]
    try parse([message("$m", at: 1_789_124_087_139), redaction("$r", of: "$m", at: 1_789_124_192_755)], into: &rooms)
    let room = try XCTUnwrap(rooms["!a:relais"])
    XCTAssertTrue(room.sortedMessages.isEmpty, "le message supprimé ne se voit plus")
    XCTAssertEqual(room.latestEventID, "$r", "mais c'est bien sur la suppression que l'accusé doit se poser")
  }

  func testLeDernierEvenementSuitLesPassesDeSync() throws {
    var rooms: [String: MatrixRoomModel] = [:]
    try parse([message("$1", at: 1_000)], into: &rooms)
    try parse([message("$2", at: 2_000)], into: &rooms)
    XCTAssertEqual(rooms["!a:relais"]?.latestEventID, "$2")
    // Une page d'historique remontée à l'envers ne fait pas reculer le repère.
    var model = try XCTUnwrap(rooms["!a:relais"])
    model.noteEvent(id: "$0", at: Date(timeIntervalSince1970: 0.5))
    XCTAssertEqual(model.latestEventID, "$2")
  }
}
