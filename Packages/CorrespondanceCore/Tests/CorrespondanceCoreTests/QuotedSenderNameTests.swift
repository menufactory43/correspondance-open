import XCTest
@testable import CorrespondanceCore

/// Une citation porte un NOM, jamais l'identifiant d'un pont.
///
/// `@whatsapp_lid-19876543210:correspondance.local` est une clé de base de
/// données ; l'écrire au-dessus d'une bulle ne dit à personne qui a parlé. Le
/// parseur cherche donc, dans l'ordre : le message cité s'il est chargé, le
/// MXID du repli résolu contre les membres du salon, puis — en tête-à-tête —
/// le titre du fil. À défaut : rien plutôt qu'un identifiant.
final class QuotedSenderNameTests: XCTestCase {
  private let selfUserID = "@meffysto:correspondance.local"

  // MARK: - Le repli ne rend plus qu'un MXID

  func testFallbackYieldsTheMXIDNotALocalpart() {
    let body = "> <@whatsapp_lid-123:serveur> Message d'avant\n\nJe confirme."
    XCTAssertEqual(MatrixSyncParser.fallbackQuotedSenderID(in: body), "@whatsapp_lid-123:serveur")
    XCTAssertEqual(MatrixSyncParser.fallbackQuotedText(in: body), "Message d'avant")
  }

  func testBodyWithoutFallbackHasNoSenderID() {
    XCTAssertNil(MatrixSyncParser.fallbackQuotedSenderID(in: "Je confirme."))
  }

  // MARK: - Sur la fixture réelle

  /// La cible est perdue (event jamais reçu), mais son auteur habite le salon :
  /// c'est son nom d'affichage qui s'écrit, pas `whatsapp_lid-19876543210`.
  func testOrphanQuoteIsNamedFromTheRoomMembers() throws {
    let bundle = Bundle.module
    let url = try XCTUnwrap(bundle.url(forResource: "matrix-sync-whatsapp", withExtension: "json"))
    let response = try JSONDecoder().decode(MatrixSyncResponse.self, from: Data(contentsOf: url))
    var rooms: [String: MatrixRoomModel] = [:]
    MatrixSyncParser(selfUserID: selfUserID).apply(response, to: &rooms)

    let room = try XCTUnwrap(rooms["!dm-alice:correspondance.local"])
    let orphan = try XCTUnwrap(room.messagesByID["$msg-alice-reponse-orpheline"])
    XCTAssertEqual(orphan.replyTo?.senderName, "Alice Martin")
    XCTAssertEqual(orphan.replyTo?.text, "Message d'avant")

    // Une citation dont la cible est chargée et vient de moi dit « Moi ».
    let answered = try XCTUnwrap(room.messagesByID["$msg-alice-reponse"])
    XCTAssertEqual(answered.replyTo?.senderName, "Moi")
  }

  // MARK: - Auteur inconnu du salon

  /// En tête-à-tête, il n'y a qu'une personne en face : le titre du fil suffit.
  func testUnknownQuotedAuthorFallsBackToTheThreadTitleInADM() throws {
    let rooms = try parse(json: Self.room(
      roomID: "!dm-bruno:correspondance.local",
      roomType: "dm",
      members: [("@whatsapp_lid-111:correspondance.local", "Bruno")]
    ))
    let room = try XCTUnwrap(rooms["!dm-bruno:correspondance.local"])
    let reply = try XCTUnwrap(room.messagesByID["$reponse"])
    XCTAssertEqual(reply.replyTo?.senderName, "Bruno")
  }

  /// Dans un groupe, aucun repli n'est honnête : douze personnes y parlent.
  /// La citation garde alors son seul texte.
  func testUnknownQuotedAuthorStaysAnonymousInAGroup() throws {
    let rooms = try parse(json: Self.room(
      roomID: "!groupe:correspondance.local",
      roomType: "group",
      members: [
        ("@whatsapp_lid-111:correspondance.local", "Bruno"),
        ("@whatsapp_lid-222:correspondance.local", "Carla"),
      ]
    ))
    let room = try XCTUnwrap(rooms["!groupe:correspondance.local"])
    let reply = try XCTUnwrap(room.messagesByID["$reponse"])
    XCTAssertEqual(reply.replyTo?.senderName, "")
    XCTAssertEqual(reply.replyTo?.text, "Message d'avant")
  }

  // MARK: - Outils

  private func parse(json: String) throws -> [String: MatrixRoomModel] {
    let response = try JSONDecoder().decode(
      MatrixSyncResponse.self,
      from: XCTUnwrap(json.data(using: .utf8))
    )
    var rooms: [String: MatrixRoomModel] = [:]
    MatrixSyncParser(selfUserID: selfUserID).apply(response, to: &rooms)
    return rooms
  }

  /// Un salon minimal : son état de pont, ses membres, et une réponse qui cite
  /// un event jamais reçu, signé d'un ghost qui n'habite pas le salon.
  private static func room(
    roomID: String,
    roomType: String,
    members: [(String, String)]
  ) -> String {
    let memberEvents = members.map { id, name in
      """
      {"type":"m.room.member","state_key":"\(id)","sender":"\(id)",
       "event_id":"$membre-\(name)","origin_server_ts":1756400000000,
       "content":{"membership":"join","displayname":"\(name)"}}
      """
    }.joined(separator: ",")
    let author = members[0].0
    return """
    {"next_batch":"s1","rooms":{"join":{"\(roomID)":{
      "state":{"events":[
        {"type":"m.bridge","state_key":"whatsapp","sender":"@whatsappbot:correspondance.local",
         "event_id":"$pont","origin_server_ts":1756400000000,
         "content":{"protocol":{"id":"whatsapp"},"com.beeper.room_type":"\(roomType)"}},
        \(memberEvents)
      ]},
      "timeline":{"events":[
        {"type":"m.room.message","event_id":"$reponse","sender":"\(author)",
         "origin_server_ts":1756400600000,
         "content":{"msgtype":"m.text",
           "body":"> <@whatsapp_lid-999:correspondance.local> Message d'avant\\n\\nJe confirme.",
           "m.relates_to":{"m.in_reply_to":{"event_id":"$jamais-recu"}}}}
      ]}
    }}}}
    """
  }
}
