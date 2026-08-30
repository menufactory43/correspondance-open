import XCTest
import CorrespondanceCore
@testable import Correspondance

/// Accusés de lecture WhatsApp : `m.receipt` de la section `ephemeral` du `/sync`.
final class ReadReceiptTests: XCTestCase {
  private let selfUserID = "@meffysto:correspondance.local"
  private let peerID = "@whatsapp_lid-19876543210:correspondance.local"
  private let roomID = "!dm:correspondance.local"

  /// Construit un `/sync` minimal : deux messages, puis un accusé optionnel.
  private func sync(readMarker: String?) throws -> MatrixSyncResponse {
    let receipt = readMarker.map { eventID in
      """
      ,"ephemeral":{"events":[{"type":"m.receipt","content":{"\(eventID)":{"m.read":{"\(peerID)":{"ts":1756400900000}}}}}]}
      """
    } ?? ""
    let json = """
    {"next_batch":"s1","rooms":{"join":{"\(roomID)":{
      "state":{"events":[
        {"type":"m.bridge","state_key":"whatsapp","content":{"protocol":{"id":"whatsapp"},"channel":{"id":"33612345678@s.whatsapp.net"},"com.beeper.room_type":"dm"}},
        {"type":"m.room.member","state_key":"\(peerID)","content":{"membership":"join","displayname":"Alice"}}
      ]},
      "timeline":{"events":[
        {"type":"m.room.message","event_id":"$recu","sender":"\(peerID)","origin_server_ts":1756400000000,"content":{"msgtype":"m.text","body":"Salut"}},
        {"type":"m.room.message","event_id":"$envoye","sender":"\(selfUserID)","origin_server_ts":1756400100000,"content":{"msgtype":"m.text","body":"Salut à toi"}}
      ]}\(receipt)
    }}}}
    """
    return try JSONDecoder().decode(MatrixSyncResponse.self, from: Data(json.utf8))
  }

  private func room(readMarker: String?) throws -> MatrixRoomModel {
    var rooms: [String: MatrixRoomModel] = [:]
    MatrixSyncParser(selfUserID: selfUserID).apply(try sync(readMarker: readMarker), to: &rooms)
    return try XCTUnwrap(rooms[roomID])
  }

  /// Sans accusé, un message sortant reste « Envoyé ».
  func testWithoutReceiptTheMessageIsOnlySent() throws {
    XCTAssertEqual(try room(readMarker: nil).delivery(selfUserID: selfUserID), .sent)
  }

  /// Le marqueur vaut « lu jusqu'ici » : posé sur mon message, il le marque vu.
  func testReceiptOnMyMessageMarksItRead() throws {
    let model = try room(readMarker: "$envoye")
    XCTAssertEqual(model.readMarkerByUser[peerID], "$envoye")
    XCTAssertEqual(model.delivery(selfUserID: selfUserID), .read)
  }

  /// Un marqueur resté sur un message plus ancien que le mien ne le marque pas vu.
  func testReceiptOnAnOlderMessageDoesNotMarkMineRead() throws {
    XCTAssertEqual(try room(readMarker: "$recu").delivery(selfUserID: selfUserID), .sent)
  }

  /// La coche remonte jusqu'à la conversation de l'inbox.
  func testConversationCarriesTheDeliveryState() throws {
    let conversation = try XCTUnwrap(try room(readMarker: "$envoye").conversation(selfUserID: selfUserID))
    XCTAssertEqual(conversation.lastDelivery, .read)
    XCTAssertTrue(conversation.lastMessageIsFromMe)
  }

  /// Le dernier message est entrant : aucune coche à afficher.
  func testIncomingLastMessageHasNoDelivery() throws {
    var model = try room(readMarker: nil)
    model.messagesByID.removeValue(forKey: "$envoye")
    let conversation = try XCTUnwrap(model.conversation(selfUserID: selfUserID))
    XCTAssertNil(conversation.lastDelivery)
    XCTAssertFalse(conversation.lastMessageIsFromMe)
  }

  /// Un salon sans message sortant n'a rien à accuser.
  func testNoOutgoingMessageMeansNoDelivery() throws {
    var model = try room(readMarker: "$envoye")
    model.messagesByID.removeValue(forKey: "$envoye")
    XCTAssertNil(model.delivery(selfUserID: selfUserID))
  }
}
