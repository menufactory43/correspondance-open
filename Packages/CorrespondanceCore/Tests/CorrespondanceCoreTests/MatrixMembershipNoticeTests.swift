import XCTest

@testable import CorrespondanceCore

/// Inviter cc doit se voir tout de suite : « cc a rejoint la conversation »
/// dans le fil, au /sync qui apporte son adhésion — pas seulement après une
/// relecture de l'historique. Trouvé en vrai : cc rejoignait sans un mot.
final class MatrixMembershipNoticeTests: XCTestCase {
  private let selfUserID = "@meffysto:correspondance.local"
  private let roomID = "!portail:correspondance.local"

  private func sync(events: String) throws -> MatrixSyncResponse {
    let json = "{\"next_batch\": \"s2\", \"rooms\": {\"join\": {\"\(roomID)\": {\"timeline\": {\"events\": [\(events)]}}}}}"
    return try JSONDecoder().decode(MatrixSyncResponse.self, from: Data(json.utf8))
  }

  private func member(_ id: String, user: String, sender: String, membership: String, ts: Int) -> String {
    "{\"type\": \"m.room.member\", \"event_id\": \"\(id)\", \"sender\": \"\(sender)\", \"state_key\": \"\(user)\", \"origin_server_ts\": \(ts), \"content\": {\"membership\": \"\(membership)\", \"displayname\": \"cc\"}}"
  }

  private func message(_ id: String, sender: String, body: String, ts: Int) -> String {
    "{\"type\": \"m.room.message\", \"event_id\": \"\(id)\", \"sender\": \"\(sender)\", \"origin_server_ts\": \(ts), \"content\": {\"msgtype\": \"m.text\", \"body\": \"\(body)\"}}"
  }

  func testLAdhesionDeCCDansLeSyncFaitUneLigneDEvenement() throws {
    let cc = "@cc:correspondance.local"
    let events = [
      member("$inv", user: cc, sender: selfUserID, membership: "invite", ts: 1_700_000_000_000),
      member("$join", user: cc, sender: cc, membership: "join", ts: 1_700_000_001_000),
    ].joined(separator: ", ")
    var rooms: [String: MatrixRoomModel] = [:]
    MatrixSyncParser(selfUserID: selfUserID).apply(try sync(events: events), to: &rooms)
    let systemLines = rooms[roomID]?.messagesByID.values.compactMap(\.systemEventText) ?? []
    XCTAssertEqual(systemLines, ["cc a rejoint la conversation"])
  }

  func testUnFantomeDePontNAnnonceRien() throws {
    let ghost = "@whatsapp_33600000000:correspondance.local"
    let events = member("$j", user: ghost, sender: ghost, membership: "join", ts: 1_700_000_000_000)
    var rooms: [String: MatrixRoomModel] = [:]
    MatrixSyncParser(selfUserID: selfUserID).apply(try sync(events: events), to: &rooms)
    XCTAssertTrue((rooms[roomID]?.messagesByID.values.compactMap(\.systemEventText) ?? []).isEmpty)
  }

  func testMaCommandeAuPontNEstPasUneBulle() throws {
    let bot = "@whatsappbot:correspondance.local"
    let events = [
      "{\"type\": \"m.bridge\", \"event_id\": \"$b\", \"sender\": \"\(bot)\", \"state_key\": \"\", \"origin_server_ts\": 1, \"content\": {\"protocol\": {\"id\": \"whatsapp\"}}}",
      message("$cmd", sender: selfUserID, body: "!wa set-relay", ts: 1_700_000_000_000),
      message("$ack", sender: bot, body: "Messages sent by users who haven't logged in will now be relayed through +33", ts: 1_700_000_001_000),
    ].joined(separator: ", ")
    var rooms: [String: MatrixRoomModel] = [:]
    MatrixSyncParser(selfUserID: selfUserID).apply(try sync(events: events), to: &rooms)
    let model = try XCTUnwrap(rooms[roomID])
    XCTAssertNil(model.messagesByID["$cmd"], "la commande n'est pas un message")
    XCTAssertEqual(model.messagesByID["$ack"]?.systemEventText, "Relais du pont allumé : cc parle ici à voix haute, depuis ton compte.")
  }
}
