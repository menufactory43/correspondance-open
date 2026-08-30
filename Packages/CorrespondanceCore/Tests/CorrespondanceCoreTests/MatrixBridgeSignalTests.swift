import XCTest
@testable import CorrespondanceCore

/// Le troisième pont. Signal vient de signal-cli, où un fil s'identifiait par un
/// numéro ou un identifiant de groupe en base64 ; il arrive désormais par le même
/// `/sync` que WhatsApp et Instagram, et rien de ces deux-là ne doit rester codé
/// en dur sur son chemin.
final class MatrixBridgeSignalTests: XCTestCase {
  private let selfUserID = "@meffysto:correspondance.local"
  private let dmRoomID = "!dm-alice:correspondance.local"
  private let groupRoomID = "!groupe-parrots:correspondance.local"
  private let managementRoomID = "!gestion-signal:correspondance.local"
  private let aliceGhost = "@signal_2f9d4c60-1a7b-4f3e-9c21-8ab5d0e77f10:correspondance.local"

  private func parsedRooms() throws -> [String: MatrixRoomModel] {
    let bundle = Bundle.module
    let url = try XCTUnwrap(
      bundle.url(forResource: "matrix-sync-signal", withExtension: "json"),
      "fixture matrix-sync-signal.json absente du bundle de test"
    )
    let response = try JSONDecoder().decode(MatrixSyncResponse.self, from: Data(contentsOf: url))
    var rooms: [String: MatrixRoomModel] = [:]
    MatrixSyncParser(selfUserID: selfUserID).apply(response, to: &rooms)
    return rooms
  }

  // MARK: - Réseau

  func testNetworkIsResolvedFromSignalBridgeState() throws {
    let rooms = try parsedRooms()
    XCTAssertEqual(rooms[dmRoomID]?.network, .signal)
    XCTAssertEqual(rooms[groupRoomID]?.network, .signal)
    // Salon de gestion : pas d'état `m.bridge` → pas un portail, pas une conversation.
    XCTAssertNil(rooms[managementRoomID]?.network)
    XCTAssertNil(rooms[managementRoomID]?.conversation(selfUserID: selfUserID))
  }

  /// Contrairement à ses deux voisins, mautrix-signal n'a pas de forme en `-go` :
  /// son `BeeperBridgeType` et son `NetworkID` valent tous deux « signal ».
  func testBridgeProtocolMappingHasNoGoSuffix() {
    XCTAssertEqual(MessageNetwork.fromBridgeProtocol("signal"), .signal)
    XCTAssertEqual(MessageNetwork.fromBridgeProtocol("Signal"), .signal)
    XCTAssertNil(MessageNetwork.fromBridgeProtocol("signalgo"))
  }

  func testGhostAndBotAreRecognised() {
    XCTAssertEqual(MatrixIdentity.network(ofGhost: aliceGhost), .signal)
    XCTAssertEqual(
      MatrixIdentity.network(ofBot: "@signalbot:correspondance.local"),
      .signal
    )
  }

  // MARK: - Conversations

  func testDirectConversationFromSignalRoom() throws {
    let room = try XCTUnwrap(try parsedRooms()[dmRoomID])
    let conversation = try XCTUnwrap(room.conversation(selfUserID: selfUserID))
    XCTAssertEqual(conversation.id, "signal:\(dmRoomID)")
    XCTAssertEqual(conversation.network, .signal)
    XCTAssertEqual(conversation.transportKey, dmRoomID)
    XCTAssertEqual(conversation.title, "Alice")
    XCTAssertFalse(conversation.isGroup)
    XCTAssertEqual(conversation.unreadCount, 2)
  }

  /// L'identité Signal est un UUID ACI, jamais un numéro. Il ne doit surtout pas
  /// être pris pour une adresse composable : ce serait ouvrir la porte à des
  /// fusions de contacts fondées sur rien.
  func testGhostUUIDIsNeverMistakenForAPhoneNumber() throws {
    let room = try XCTUnwrap(try parsedRooms()[dmRoomID])
    XCTAssertNil(room.bridgePhoneNumber)
    let conversation = try XCTUnwrap(room.conversation(selfUserID: selfUserID))
    XCTAssertEqual(conversation.address, dmRoomID)
    XCTAssertNil(PhoneNormalizer.identityKey(for: conversation.address))
    // Et l'UUID du ghost lui-même n'en produit pas davantage.
    XCTAssertNil(PhoneNormalizer.identityKey(for: aliceGhost))
  }

  /// mautrix accole « (Signal) » aux noms de ghosts : la liste ne doit pas l'afficher.
  func testSignalSuffixIsStrippedFromGhostNames() {
    XCTAssertEqual(MatrixIdentity.stripBridgeSuffix("Alice (Signal)"), "Alice")
  }

  func testGroupConversationFromSignalRoom() throws {
    let room = try XCTUnwrap(try parsedRooms()[groupRoomID])
    let conversation = try XCTUnwrap(room.conversation(selfUserID: selfUserID))
    XCTAssertTrue(conversation.isGroup)
    XCTAssertEqual(conversation.title, "Les Perroquets")
    XCTAssertEqual(conversation.unreadCount, 0)
  }

  // MARK: - Messages

  func testMessagesReactionsAndRepliesAreParsed() throws {
    let room = try XCTUnwrap(try parsedRooms()[dmRoomID])
    let messages = room.sortedMessages
    XCTAssertEqual(messages.map(\.text), ["On se voit demain ?", "Oui, vers 18h."])

    let incoming = try XCTUnwrap(messages.first)
    XCTAssertFalse(incoming.isFromMe)
    XCTAssertEqual(incoming.senderID, aliceGhost)

    // Ma réponse cite le message d'Alice, et porte son 👍.
    let mine = try XCTUnwrap(messages.last)
    XCTAssertTrue(mine.isFromMe)
    XCTAssertEqual(mine.replyTo?.messageID, "$msg-alice-1")
    XCTAssertEqual(mine.reactions.map(\.emoji), ["👍"])
  }

  // MARK: - Légendes de pièces jointes

  /// MSC2530 : `filename` porte le nom du fichier, `body` la légende. Sans cette
  /// lecture, le texte écrit sous une photo disparaissait de la bulle.
  func testCaptionUnderAnImageIsKept() throws {
    let event = Self.imageEvent(body: "d'ailleurs, demain, publication", filename: "image.jpg")
    var model = MatrixRoomModel(roomID: dmRoomID)
    model.network = .signal
    MatrixSyncParser(selfUserID: selfUserID).applyMessages([event], roomID: dmRoomID, to: &model)
    let message = try XCTUnwrap(model.sortedMessages.first)
    XCTAssertEqual(message.text, "d'ailleurs, demain, publication")
    XCTAssertEqual(message.attachments.first?.filename, "image.jpg")
  }

  /// Sans `filename`, `body` EST le nom du fichier : l'écrire sous la photo
  /// afficherait « 787306034_1768317604621271 » en guise de message.
  func testFilenameOnlyImageHasNoCaption() throws {
    let event = Self.imageEvent(body: "787306034_1768317604621271.jpg", filename: nil)
    var model = MatrixRoomModel(roomID: dmRoomID)
    model.network = .signal
    MatrixSyncParser(selfUserID: selfUserID).applyMessages([event], roomID: dmRoomID, to: &model)
    let message = try XCTUnwrap(model.sortedMessages.first)
    XCTAssertEqual(message.text, "")
    XCTAssertEqual(message.attachments.first?.filename, "787306034_1768317604621271.jpg")
  }

  /// Un pont qui répète le nom du fichier dans `body` ne fournit pas une légende.
  func testRepeatedFilenameIsNotACaption() throws {
    let event = Self.imageEvent(body: "qr.png", filename: "qr.png")
    var model = MatrixRoomModel(roomID: dmRoomID)
    model.network = .signal
    MatrixSyncParser(selfUserID: selfUserID).applyMessages([event], roomID: dmRoomID, to: &model)
    XCTAssertEqual(try XCTUnwrap(model.sortedMessages.first).text, "")
  }

  private static func imageEvent(body: String, filename: String?) -> MatrixEvent {
    var content: [String: Any] = [
      "msgtype": "m.image",
      "body": body,
      "url": "mxc://correspondance.local/photo-abc",
      "info": ["mimetype": "image/jpeg"],
    ]
    if let filename { content["filename"] = filename }
    let raw: [String: Any] = [
      "type": "m.room.message",
      "event_id": "$img-1",
      "sender": "@signal_2f9d4c60-1a7b-4f3e-9c21-8ab5d0e77f10:correspondance.local",
      "origin_server_ts": 1_756_600_100_000,
      "content": content,
    ]
    let data = try! JSONSerialization.data(withJSONObject: raw)
    return try! JSONDecoder().decode(MatrixEvent.self, from: data)
  }

  // MARK: - Connexion

  /// mautrix-signal n'a qu'un flow : le QR. Lui envoyer un numéro produirait une
  /// erreur du bot, d'où le garde-fou porté par le descripteur.
  func testSignalLoginOffersNoPhonePairing() throws {
    let signal = try XCTUnwrap(MessageNetwork.signal.bridge)
    XCTAssertEqual(signal.loginFlow, .qrCode)
    XCTAssertFalse(signal.supportsPhonePairing)
    XCTAssertEqual(signal.commandPrefix, "!signal")
  }
}
