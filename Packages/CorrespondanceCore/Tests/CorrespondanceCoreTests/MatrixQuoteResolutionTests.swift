import XCTest
@testable import CorrespondanceCore

/// Le pont Signal ne met dans une réponse que l'`event_id` cité — aucun texte de
/// repli. Une citation dont la cible n'est pas encore en main doit attendre,
/// pas disparaître : la cible arrive plus tard (trou comblé, page remontée en
/// arrière, ou event demandé au Relais) et la citation prend alors son texte.
final class MatrixQuoteResolutionTests: XCTestCase {
  private let selfUserID = "@meffysto:correspondance.local"
  private let roomID = "!groupe:correspondance.local"
  private let alice = "@signal_alice:correspondance.local"

  private func json(_ raw: String) -> MatrixJSON {
    try! JSONDecoder().decode(MatrixJSON.self, from: Data(raw.utf8))
  }

  private func member(_ userID: String, name: String) -> MatrixEvent {
    MatrixEvent(
      type: "m.room.member", eventID: "$m-\(name)", sender: userID, stateKey: userID,
      content: json("{\"membership\": \"join\", \"displayname\": \"\(name)\"}")
    )
  }

  private func text(_ id: String, _ body: String, ts: Double = 1700000000000, sender: String? = nil) -> MatrixEvent {
    MatrixEvent(
      type: "m.room.message", eventID: id, sender: sender ?? alice, originServerTS: ts,
      content: json("{\"msgtype\": \"m.text\", \"body\": \"\(body)\"}")
    )
  }

  /// Une réponse Signal : pas de repli « > … », juste la relation.
  private func reply(_ id: String, to target: String, _ body: String) -> MatrixEvent {
    MatrixEvent(
      type: "m.room.message", eventID: id, sender: "@signal_bob:correspondance.local", originServerTS: 1700000002000,
      content: json("{\"msgtype\": \"m.text\", \"body\": \"\(body)\", \"m.relates_to\": {\"m.in_reply_to\": {\"event_id\": \"\(target)\"}}}")
    )
  }

  func testReplyWhoseTargetIsUnknownWaitsInsteadOfVanishing() {
    let parser = MatrixSyncParser(selfUserID: selfUserID)
    var model = MatrixRoomModel(roomID: roomID)
    parser.applyMessages([reply("$r", to: "$cible", "Sympa sérieux !")], roomID: roomID, to: &model)

    let message = model.messagesByID["$r"]
    XCTAssertEqual(message?.text, "Sympa sérieux !")
    XCTAssertEqual(message?.replyTo?.messageID, "$cible")
    XCTAssertEqual(message?.replyTo?.awaitsTarget, true, "la citation attend sa cible")
    XCTAssertEqual(model.unresolvedQuoteMessageIDs, ["$r"])
    XCTAssertEqual(MatrixSyncParser.missingQuoteTargets(in: model), ["$cible"])
  }

  /// Une page remontée en arrière livre la réponse avant le message cité.
  func testQuoteResolvesWhenTargetArrivesLater() {
    let parser = MatrixSyncParser(selfUserID: selfUserID)
    var model = MatrixRoomModel(roomID: roomID)
    parser.applyMessages([member(alice, name: "Alice")], roomID: roomID, to: &model)
    parser.applyMessages([reply("$r", to: "$cible", "Sympa sérieux !")], roomID: roomID, to: &model)
    parser.applyMessages([text("$cible", "Regardez ça")], roomID: roomID, to: &model)

    let quote = model.messagesByID["$r"]?.replyTo
    XCTAssertEqual(quote?.text, "Regardez ça")
    XCTAssertEqual(quote?.senderName, "Alice")
    XCTAssertEqual(quote?.awaitsTarget, false)
    XCTAssertTrue(model.unresolvedQuoteMessageIDs.isEmpty)
    XCTAssertTrue(MatrixSyncParser.missingQuoteTargets(in: model).isEmpty)
  }

  /// Le cache disque garde une citation muette : au lancement suivant, elle se
  /// résout dès que la cible est là — semée elle aussi, ou revenue par le sync.
  func testPendingQuoteFromTheStoreResolvesAgainstItsTarget() {
    let parser = MatrixSyncParser(selfUserID: selfUserID)
    let conversationID = "signal:\(roomID)"
    let target = ChatMessage(
      id: "$cible", conversationID: conversationID, network: .signal, text: "Regardez ça",
      sentAt: Date(timeIntervalSince1970: 1_700_000_000), isFromMe: false, senderID: alice, senderName: "Alice"
    )
    let pending = ChatMessage(
      id: "$r", conversationID: conversationID, network: .signal, text: "Sympa sérieux !",
      sentAt: Date(timeIntervalSince1970: 1_700_000_002), isFromMe: false,
      replyTo: QuotedMessage(messageID: "$cible", senderName: "", text: "")
    )
    var model = MatrixRoomModel(roomID: roomID)
    model.network = .signal
    parser.hydrate(messages: [pending, target], reactions: [:], into: &model)
    XCTAssertEqual(model.messagesByID["$r"]?.replyTo?.text, "Regardez ça")
  }

  // MARK: - Aperçus de liens livrés par le pont

  func testBridgedLinkPreviewIsReadFromBeeperKey() {
    let content = json("""
    {"msgtype": "m.text", "body": "https://x.com/a/status/1\\nregarde",
     "com.beeper.linkpreviews": [{"matched_url": "https://x.com/a/status/1", "og:title": "Un titre",
       "og:description": "Une description", "og:image": "mxc://correspondance.local/abc", "og:image:type": "image/jpeg"}]}
    """)
    let preview = MatrixSyncParser.bridgedLinkPreview(in: content)
    XCTAssertEqual(preview?.url, "https://x.com/a/status/1")
    XCTAssertEqual(preview?.title, "Un titre")
    XCTAssertEqual(preview?.description, "Une description")
    XCTAssertEqual(preview?.imageMXC, "mxc://correspondance.local/abc")
    XCTAssertEqual(preview?.imageContentType, "image/jpeg")
    XCTAssertEqual(preview?.asLinkPreview?.domain, "x.com")
    XCTAssertEqual(preview?.asLinkPreview?.title, "Un titre")
  }

  func testBridgedLinkPreviewLandsOnTheMessage() {
    let parser = MatrixSyncParser(selfUserID: selfUserID)
    var model = MatrixRoomModel(roomID: roomID)
    let event = MatrixEvent(
      type: "m.room.message", eventID: "$l", sender: alice, originServerTS: 1700000000000,
      content: json("{\"msgtype\": \"m.text\", \"body\": \"https://www.lemonde.fr/x\", \"com.beeper.linkpreviews\": [{\"matched_url\": \"https://www.lemonde.fr/x\", \"og:title\": \"Le Monde\"}]}")
    )
    parser.applyMessages([event], roomID: roomID, to: &model)
    XCTAssertEqual(model.messagesByID["$l"]?.linkPreview?.title, "Le Monde")
    XCTAssertEqual(model.messagesByID["$l"]?.linkPreview?.asLinkPreview?.domain, "lemonde.fr")
    XCTAssertNil(MatrixSyncParser.bridgedLinkPreview(in: json("{\"msgtype\": \"m.text\", \"body\": \"x\"}")))
    // Sans titre ni vignette, pas de carte : mieux vaut le lien nu.
    XCTAssertNil(BridgedLinkPreview(url: "https://a.fr", description: "d").asLinkPreview)
  }
}
