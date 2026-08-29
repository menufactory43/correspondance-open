import XCTest
@testable import Correspondance

/// Citations : repli Matrix, quotes Signal, `thread_originator_guid` iMessage.
final class QuotedReplyTests: XCTestCase {
  // MARK: - Repli de citation Matrix

  /// Sans ce nettoyage, chaque réponse WhatsApp recopierait le message d'origine.
  func testReplyFallbackIsStrippedFromTheBody() {
    let body = "> <@meffysto:serveur> Oui, 19 h au comptoir.\n\nParfait, à tout à l'heure."
    XCTAssertEqual(QuotedMessage.strippingReplyFallback(body), "Parfait, à tout à l'heure.")
  }

  func testMultiLineFallbackIsStripped() {
    let body = "> <@x:s> ligne un\n> ligne deux\n\nMa réponse."
    XCTAssertEqual(QuotedMessage.strippingReplyFallback(body), "Ma réponse.")
  }

  /// Un message qui commence par une citation Markdown volontaire n'est pas amputé
  /// tant qu'il n'y a pas de `m.in_reply_to` : le nettoyage n'est appelé que là.
  func testBodyWithoutFallbackIsUntouched() {
    XCTAssertEqual(QuotedMessage.strippingReplyFallback("Bonjour"), "Bonjour")
  }

  func testFallbackSenderAndTextAreRecovered() {
    let body = "> <@whatsapp_lid-123:serveur> Message d'avant\n\nJe confirme."
    XCTAssertEqual(MatrixSyncParser.fallbackQuotedSender(in: body), "whatsapp_lid-123")
    XCTAssertEqual(MatrixSyncParser.fallbackQuotedText(in: body), "Message d'avant")
  }

  // MARK: - Fixture /sync

  private let selfUserID = "@meffysto:correspondance.local"
  private let dmRoomID = "!dm-alice:correspondance.local"

  private func parsedRooms() throws -> [String: MatrixRoomModel] {
    let bundle = Bundle(for: Self.self)
    let url = try XCTUnwrap(bundle.url(forResource: "matrix-sync-whatsapp", withExtension: "json"))
    let response = try JSONDecoder().decode(MatrixSyncResponse.self, from: Data(contentsOf: url))
    var rooms: [String: MatrixRoomModel] = [:]
    MatrixSyncParser(selfUserID: selfUserID).apply(response, to: &rooms)
    return rooms
  }

  func testInReplyToIsResolvedAgainstTheThread() throws {
    let room = try XCTUnwrap(try parsedRooms()[dmRoomID])
    let reply = try XCTUnwrap(room.sortedMessages.first { $0.id == "$msg-alice-reponse" })
    // Le corps affiché ne garde pas le repli.
    XCTAssertEqual(reply.text, "Parfait, à tout à l'heure.")
    let quote = try XCTUnwrap(reply.replyTo)
    XCTAssertEqual(quote.messageID, "$msg-moi-1")
    XCTAssertEqual(quote.senderName, "Moi")
    XCTAssertEqual(quote.text, "Oui, 19 h au comptoir.")
  }

  /// Cible hors de la fenêtre : on se rabat sur ce que le repli dit.
  func testReplyToUnknownMessageFallsBackToTheQuotedBody() throws {
    let room = try XCTUnwrap(try parsedRooms()[dmRoomID])
    let reply = try XCTUnwrap(room.sortedMessages.first { $0.id == "$msg-alice-reponse-orpheline" })
    XCTAssertEqual(reply.text, "Je confirme.")
    let quote = try XCTUnwrap(reply.replyTo)
    XCTAssertEqual(quote.text, "Message d'avant")
    XCTAssertEqual(quote.senderName, "whatsapp_lid-19876543210")
  }

  func testMessagesWithoutReplyHaveNoQuote() throws {
    let room = try XCTUnwrap(try parsedRooms()[dmRoomID])
    XCTAssertNil(room.sortedMessages.first { $0.id == "$msg-alice-1" }?.replyTo)
  }

  // MARK: - iMessage

  private func message(_ id: String, _ text: String, fromMe: Bool, sender: String?, replyTo: String? = nil) -> ChatMessage {
    ChatMessage(
      id: id,
      conversationID: "imessage:chat1",
      network: .iMessage,
      text: text,
      sentAt: Date(timeIntervalSince1970: 1_756_400_000),
      isFromMe: fromMe,
      senderID: sender,
      replyTo: replyTo.map { QuotedMessage(messageID: $0, senderName: "", text: "") }
    )
  }

  /// `thread_originator_guid` ne donne que le GUID : auteur et texte viennent du fil.
  func testIMessageQuotesAreResolvedFromTheThread() throws {
    let resolved = IMessageDatabase.resolvingQuotes(in: [
      message("A", "On se voit demain ?", fromMe: false, sender: "+33612345678"),
      message("B", "Oui !", fromMe: true, sender: nil, replyTo: "A"),
    ])
    let quote = try XCTUnwrap(resolved[1].replyTo)
    XCTAssertEqual(quote.messageID, "A")
    XCTAssertEqual(quote.senderName, "+33612345678")
    XCTAssertEqual(quote.text, "On se voit demain ?")
  }

  /// Cible hors de la fenêtre chargée : une citation vide n'apprend rien, on l'enlève.
  func testIMessageQuoteWithoutTargetIsDropped() {
    let resolved = IMessageDatabase.resolvingQuotes(in: [
      message("B", "Oui !", fromMe: true, sender: nil, replyTo: "jamais-chargé")
    ])
    XCTAssertNil(resolved[0].replyTo)
  }

  func testIMessageReplyToMyOwnMessageSaysMoi() throws {
    let resolved = IMessageDatabase.resolvingQuotes(in: [
      message("A", "Je pars", fromMe: true, sender: nil),
      message("B", "OK", fromMe: false, sender: "+33612345678", replyTo: "A"),
    ])
    XCTAssertEqual(try XCTUnwrap(resolved[1].replyTo).senderName, "Moi")
  }

  // MARK: - Citation vide

  func testEmptyQuoteIsDetected() {
    XCTAssertTrue(QuotedMessage(messageID: "x", senderName: "  ", text: "").isEmpty)
    XCTAssertFalse(QuotedMessage(messageID: "x", senderName: "Alice", text: "").isEmpty)
  }
}
