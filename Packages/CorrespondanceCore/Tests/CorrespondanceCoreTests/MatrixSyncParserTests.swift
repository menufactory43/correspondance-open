import XCTest
@testable import CorrespondanceCore

/// Parsing d'un `/sync` réel (fixture) → conversations et messages de l'inbox.
/// Aucun accès réseau : `MatrixSyncParser` et `MatrixRoomModel` sont purs.
final class MatrixSyncParserTests: XCTestCase {
  private let selfUserID = "@meffysto:correspondance.local"
  private let dmRoomID = "!dm-alice:correspondance.local"
  private let groupRoomID = "!groupe-vacances:correspondance.local"
  private let managementRoomID = "!gestion-whatsapp:correspondance.local"
  private let unknownBridgeRoomID = "!fil-inconnu:correspondance.local"

  // MARK: - Fixture

  private func loadSyncFixture() throws -> MatrixSyncResponse {
    let bundle = Bundle.module
    let url = try XCTUnwrap(
      bundle.url(forResource: "matrix-sync-whatsapp", withExtension: "json"),
      "fixture matrix-sync-whatsapp.json absente du bundle de test"
    )
    return try JSONDecoder().decode(MatrixSyncResponse.self, from: Data(contentsOf: url))
  }

  private func parsedRooms() throws -> [String: MatrixRoomModel] {
    var rooms: [String: MatrixRoomModel] = [:]
    MatrixSyncParser(selfUserID: selfUserID).apply(try loadSyncFixture(), to: &rooms)
    return rooms
  }

  // MARK: - Enveloppe

  func testSyncEnvelopeDecodes() throws {
    let response = try loadSyncFixture()
    XCTAssertEqual(response.nextBatch, "s72595_4483_1934")
    XCTAssertEqual(response.rooms?.join?.count, 4)
  }

  func testLeftRoomIsRemovedFromInbox() throws {
    var rooms: [String: MatrixRoomModel] = ["!fil-quitte:correspondance.local": MatrixRoomModel(roomID: "!fil-quitte:correspondance.local")]
    MatrixSyncParser(selfUserID: selfUserID).apply(try loadSyncFixture(), to: &rooms)
    XCTAssertNil(rooms["!fil-quitte:correspondance.local"])
  }

  // MARK: - Détection du réseau par salon

  func testNetworkIsResolvedPerRoomFromBridgeState() throws {
    let rooms = try parsedRooms()
    XCTAssertEqual(rooms[dmRoomID]?.network, .whatsapp)
    XCTAssertEqual(rooms[groupRoomID]?.network, .whatsapp)
    // Salon de gestion du bot : pas d'état `m.bridge` → pas un portail.
    XCTAssertNil(rooms[managementRoomID]?.network)
    // Protocole inconnu (`discord`) : ignoré plutôt que mal classé.
    XCTAssertNil(rooms[unknownBridgeRoomID]?.network)
  }

  func testOnlyBridgedRoomsBecomeConversations() throws {
    let rooms = try parsedRooms()
    let conversations = rooms.values
      .compactMap { $0.conversation(selfUserID: selfUserID) }
      .sorted { $0.id < $1.id }
    XCTAssertEqual(conversations.count, 2)
    XCTAssertTrue(conversations.allSatisfy { $0.network == .whatsapp })
    XCTAssertNil(rooms[managementRoomID]?.conversation(selfUserID: selfUserID))
    XCTAssertNil(rooms[unknownBridgeRoomID]?.conversation(selfUserID: selfUserID))
  }

  func testBridgeProtocolMapping() {
    XCTAssertEqual(MessageNetwork.fromBridgeProtocol("whatsapp"), .whatsapp)
    XCTAssertEqual(MessageNetwork.fromBridgeProtocol("WhatsApp"), .whatsapp)
    XCTAssertNil(MessageNetwork.fromBridgeProtocol("discord"))
    XCTAssertNil(MessageNetwork.fromBridgeProtocol(""))
  }

  // MARK: - Conversation directe

  func testDirectConversationFromBridgedRoom() throws {
    let room = try XCTUnwrap(try parsedRooms()[dmRoomID])
    let conversation = try XCTUnwrap(room.conversation(selfUserID: selfUserID))
    XCTAssertEqual(conversation.id, "whatsapp:\(dmRoomID)")
    XCTAssertEqual(conversation.network, .whatsapp)
    XCTAssertEqual(conversation.transportKey, dmRoomID)
    XCTAssertEqual(conversation.title, "Alice Martin")
    XCTAssertFalse(conversation.isGroup)
    XCTAssertEqual(conversation.unreadCount, 2)
    // Numéro exposé par l'état de bridge (`channel.id` en JID) — jamais déduit du MXID.
    XCTAssertEqual(conversation.address, "+33612345678")
    // Le dernier message du fil est désormais la réponse citée « orpheline ».
    XCTAssertEqual(conversation.preview, "Je confirme.")
    XCTAssertEqual(conversation.lastMessageAt, Date(timeIntervalSince1970: 1_756_400_700))
  }

  func testGhostLIDNeverYieldsAPhoneNumber() throws {
    let room = try XCTUnwrap(try parsedRooms()[groupRoomID])
    // Aucun membre du groupe n'expose de numéro et le JID est un `@g.us` : rien à extraire.
    XCTAssertNil(room.bridgePhoneNumber)
    XCTAssertNil(MatrixIdentity.phoneNumber(in: "lid-19876543210"))
    XCTAssertNil(MatrixIdentity.phoneNumber(in: "@whatsapp_lid-19876543210:correspondance.local"))
    XCTAssertTrue(MatrixIdentity.isGhost("@whatsapp_lid-19876543210:correspondance.local"))
    XCTAssertTrue(MatrixIdentity.isBridgeBot("@whatsappbot:correspondance.local"))
    XCTAssertFalse(MatrixIdentity.isBridgeBot("@whatsapp_lid-19876543210:correspondance.local"))
  }

  // MARK: - Salon groupe

  func testGroupRoomIsDetectedAndNamed() throws {
    let room = try XCTUnwrap(try parsedRooms()[groupRoomID])
    let conversation = try XCTUnwrap(room.conversation(selfUserID: selfUserID))
    XCTAssertTrue(conversation.isGroup)
    XCTAssertEqual(conversation.title, "Vacances 2026")
    // Moi, le bot et le membre parti sont exclus des correspondants.
    let remotes = room.remoteMembers(selfUserID: selfUserID).map(\.userID)
    XCTAssertEqual(
      remotes,
      ["@whatsapp_lid-11111111111:correspondance.local", "@whatsapp_lid-22222222222:correspondance.local"]
    )
  }

  // MARK: - Messages

  func testTextAndImageMessagesAreParsed() throws {
    let room = try XCTUnwrap(try parsedRooms()[dmRoomID])
    let messages = room.sortedMessages
    XCTAssertEqual(
      messages.map(\.id),
      ["$msg-alice-1", "$msg-moi-1", "$msg-alice-image", "$msg-alice-reponse", "$msg-alice-reponse-orpheline"]
    )
    XCTAssertTrue(messages.allSatisfy { $0.network == .whatsapp })
    XCTAssertTrue(messages.allSatisfy { $0.conversationID == "whatsapp:\(dmRoomID)" })

    XCTAssertEqual(messages[0].text, "On se voit demain ?")
    XCTAssertFalse(messages[0].isFromMe)
    XCTAssertTrue(messages[0].attachments.isEmpty)

    XCTAssertTrue(messages[1].isFromMe)
    XCTAssertEqual(messages[1].text, "Oui, 19 h au comptoir.")

    let image = messages[2]
    XCTAssertEqual(image.text, "")
    let attachment = try XCTUnwrap(image.attachments.first)
    XCTAssertEqual(attachment.id, "mxc://correspondance.local/AbCdEf123456")
    XCTAssertEqual(attachment.contentType, "image/jpeg")
    XCTAssertEqual(attachment.filename, "photo-terrasse.jpg")
    XCTAssertTrue(attachment.isImage)
  }

  /// Une modification ne fait pas un message de plus : elle corrige le sien,
  /// garde l'ancien texte dans son historique, et porte la mention « Modifié ».
  func testEditedMessageCorrectsTheOriginalInPlace() throws {
    let room = try XCTUnwrap(try parsedRooms()[groupRoomID])
    XCTAssertEqual(room.sortedMessages.map(\.id), ["$msg-groupe-1"])
    let message = try XCTUnwrap(room.sortedMessages.first)
    XCTAssertEqual(message.text, "J'ai réservé le gîte pour six.")
    XCTAssertEqual(message.editHistory, ["J'ai réservé le gîte."])
    XCTAssertNotNil(message.editedAt)
  }

  func testApplyingTheSameSyncTwiceIsIdempotent() throws {
    let parser = MatrixSyncParser(selfUserID: selfUserID)
    var rooms: [String: MatrixRoomModel] = [:]
    parser.apply(try loadSyncFixture(), to: &rooms)
    let first = rooms[dmRoomID]?.sortedMessages ?? []
    parser.apply(try loadSyncFixture(), to: &rooms)
    XCTAssertEqual(rooms[dmRoomID]?.sortedMessages, first)
    XCTAssertEqual(rooms.count, 4)
  }
}

// MARK: - Réactions

extension MatrixSyncParserTests {
  /// `m.reaction` rattachée à sa cible, jamais affichée comme un message.
  func testReactionsAreAttachedToTheirTargetMessage() throws {
    let room = try XCTUnwrap(try parsedRooms()[dmRoomID])
    // Une réaction n'est pas un message : le fil ne compte que ses cinq `m.room.message`.
    XCTAssertEqual(
      room.sortedMessages.map(\.id),
      ["$msg-alice-1", "$msg-moi-1", "$msg-alice-image", "$msg-alice-reponse", "$msg-alice-reponse-orpheline"]
    )

    let mine = try XCTUnwrap(room.sortedMessages.first { $0.id == "$msg-moi-1" })
    XCTAssertEqual(mine.reactions.map(\.emoji), ["❤️"])
    XCTAssertEqual(mine.reactions.first?.count, 1)
    XCTAssertFalse(try XCTUnwrap(mine.reactions.first).isMine)
    XCTAssertEqual(mine.reactions.first?.senders, ["Alice Martin"])
  }

  /// Ma propre réaction est marquée `isMine` : la pastille se montre active.
  func testMyOwnReactionIsFlagged() throws {
    let room = try XCTUnwrap(try parsedRooms()[dmRoomID])
    let target = try XCTUnwrap(room.sortedMessages.first { $0.id == "$msg-alice-1" })
    let mine = try XCTUnwrap(target.reactions.first { $0.emoji == "👍" })
    XCTAssertTrue(mine.isMine)
    XCTAssertEqual(mine.senders, ["Moi"])
    XCTAssertEqual(target.myReactionEmoji, "👍")
  }

  /// Retirer une réaction, c'est rédiger son event : elle disparaît des pastilles.
  func testRedactedReactionIsRemoved() throws {
    let room = try XCTUnwrap(try parsedRooms()[dmRoomID])
    let target = try XCTUnwrap(room.sortedMessages.first { $0.id == "$msg-alice-1" })
    XCTAssertFalse(target.reactions.contains { $0.emoji == "😂" })
    XCTAssertNil(room.reactionsByEventID["$rea-annulee"])
  }

  /// Deux personnes, un seul emoji : une pastille qui compte 2.
  func testSameEmojiFromTwoPeopleIsAggregated() throws {
    let room = try XCTUnwrap(try parsedRooms()[groupRoomID])
    let message = try XCTUnwrap(room.sortedMessages.first)
    let party = try XCTUnwrap(message.reactions.first { $0.emoji == "🎉" })
    XCTAssertEqual(party.count, 2)
    XCTAssertEqual(party.senders.count, 2)
    XCTAssertFalse(party.isMine)
  }

  func testReplayingTheSyncDoesNotDuplicateReactions() throws {
    let parser = MatrixSyncParser(selfUserID: selfUserID)
    var rooms: [String: MatrixRoomModel] = [:]
    parser.apply(try loadSyncFixture(), to: &rooms)
    parser.apply(try loadSyncFixture(), to: &rooms)
    let message = try XCTUnwrap(rooms[groupRoomID]?.sortedMessages.first)
    XCTAssertEqual(message.reactions.first { $0.emoji == "🎉" }?.count, 2)
  }


  // MARK: - Arrivées et départs d'utilisateurs du Relais

  private func memberEvent(_ userID: String, membership: String, id: String, displayName: String? = nil, at: Double = 1_700_000_000_000) -> MatrixEvent {
    var content: [String: MatrixJSON] = ["membership": .string(membership)]
    if let displayName { content["displayname"] = .string(displayName) }
    return MatrixEvent(type: "m.room.member", eventID: id, sender: userID, stateKey: userID, originServerTS: at, content: .object(content))
  }

  func testAgentJoinBecomesASystemLine() {
    var model = MatrixRoomModel(roomID: "!note:correspondance.local")
    let parser = MatrixSyncParser(selfUserID: selfUserID)
    _ = parser.applyMessages([memberEvent("@cc:correspondance.local", membership: "join", id: "$join", displayName: "cc")], roomID: model.roomID, to: &model)
    XCTAssertEqual(model.messagesByID["$join"]?.systemEventText, "cc a rejoint la conversation")
    XCTAssertEqual(model.members["@cc:correspondance.local"]?.membership, "join")

    // Un second `join` (changement de nom) n'annonce rien de plus.
    _ = parser.applyMessages([memberEvent("@cc:correspondance.local", membership: "join", id: "$rename", displayName: "cc bot")], roomID: model.roomID, to: &model)
    XCTAssertNil(model.messagesByID["$rename"])

    _ = parser.applyMessages([memberEvent("@cc:correspondance.local", membership: "leave", id: "$leave")], roomID: model.roomID, to: &model)
    XCTAssertEqual(model.messagesByID["$leave"]?.systemEventText, "cc bot a quitté la conversation")
  }

  func testGhostsBotsAndSelfStaySilent() {
    var model = MatrixRoomModel(roomID: "!dm:correspondance.local")
    let parser = MatrixSyncParser(selfUserID: selfUserID)
    _ = parser.applyMessages([
      memberEvent("@whatsapp_33612345678:correspondance.local", membership: "join", id: "$ghost"),
      memberEvent("@whatsappbot:correspondance.local", membership: "join", id: "$bot"),
      memberEvent(selfUserID, membership: "join", id: "$me"),
    ], roomID: model.roomID, to: &model)
    XCTAssertTrue(model.messagesByID.isEmpty, "\(model.messagesByID.keys)")
  }


  /// Une page d'historique remontée APRÈS le présent rejoue l'invitation d'un
  /// fantôme, encore nommé par son numéro : elle ne doit pas écraser le nom
  /// courant ni ramener l'adhésion à « invite » — c'est ce que l'iPhone
  /// montrait le 22 sept. (« +262692090323 » pour « Grand mere »).
  func testOlderStateFromHistoryNeverOverwritesNewerState() {
    var model = MatrixRoomModel(roomID: "!groupe:correspondance.local")
    let parser = MatrixSyncParser(selfUserID: selfUserID)
    let ghost = "@whatsapp_lid-1:correspondance.local"
    // Le présent : le renommage du 11 septembre, lu dans la timeline.
    _ = parser.applyMessages(
      [memberEvent(ghost, membership: "join", id: "$rename", displayName: "Grand mere (WA)", at: 1_789_112_391_000)],
      roomID: model.roomID, to: &model)
    XCTAssertEqual(model.members[ghost]?.displayName, "Grand mere")
    // Le passé : l'invitation du 5 septembre, dans une page `/messages`.
    _ = parser.applyMessages(
      [memberEvent(ghost, membership: "invite", id: "$invite", displayName: "+262692090323 (WA)", at: 1_788_619_664_000)],
      roomID: model.roomID, to: &model)
    XCTAssertEqual(model.members[ghost]?.displayName, "Grand mere")
    XCTAssertEqual(model.members[ghost]?.membership, "join")
    // Un état plus récent, lui, passe toujours.
    _ = parser.applyMessages(
      [memberEvent(ghost, membership: "join", id: "$rename2", displayName: "Mamie (WA)", at: 1_790_000_000_000)],
      roomID: model.roomID, to: &model)
    XCTAssertEqual(model.members[ghost]?.displayName, "Mamie")
  }

  /// Les dates d'état survivent au magasin : sans elles, la première page
  /// d'historique après un relancement referait le dégât.
  func testStateTimestampsSurviveTheStore() throws {
    var model = MatrixRoomModel(roomID: "!groupe:correspondance.local")
    model.network = .whatsapp
    let parser = MatrixSyncParser(selfUserID: selfUserID)
    let ghost = "@whatsapp_lid-1:correspondance.local"
    _ = parser.applyMessages(
      [memberEvent(ghost, membership: "join", id: "$rename", displayName: "Grand mere (WA)", at: 1_789_112_391_000)],
      roomID: model.roomID, to: &model)
    let stored = StoredRoom(model: model, selfUserID: selfUserID)
    let data = try JSONEncoder().encode(stored.state)
    let restored = try JSONDecoder().decode(StoredRoom.State.self, from: data)
    XCTAssertEqual(restored.stateAppliedAt?.count, 1)
    // Une ligne d'avant, sans la clé, se relit encore.
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    json.removeValue(forKey: "stateAppliedAt")
    let legacy = try JSONDecoder().decode(StoredRoom.State.self, from: JSONSerialization.data(withJSONObject: json))
    XCTAssertNil(legacy.stateAppliedAt)
  }

  /// Le pont renomme un fantôme (« +33675993742 » → « Maman maison ») : les
  /// messages déjà rangés portent l'ancien nom, le salon porte le nouveau.
  /// Le fil et l'aperçu se lisent avec le nom du moment.
  func testStoredMessagesTakeTheCurrentMemberName() {
    var model = MatrixRoomModel(roomID: "!groupe:correspondance.local")
    let ghost = "@whatsapp_lid-1:correspondance.local"
    model.members[ghost] = .init(displayName: "Maman maison", membership: "join")
    model.messagesByID["$1"] = ChatMessage(
      id: "$1", conversationID: "whatsapp:!groupe:correspondance.local", network: .whatsapp,
      text: "Il lui faudrait un garage", sentAt: Date(timeIntervalSince1970: 1_000),
      isFromMe: false, senderID: ghost, senderName: "+33675993742"
    )
    XCTAssertEqual(model.sortedMessages.first?.senderName, "Maman maison")
    XCTAssertEqual(model.lastListedMessage?.senderName, "Maman maison")

    // La citation d'une réponse relit le nom du message cité, pas celui figé
    // à l'arrivée de la réponse.
    model.messagesByID["$2"] = ChatMessage(
      id: "$2", conversationID: "whatsapp:!groupe:correspondance.local", network: .whatsapp,
      text: "Oui", sentAt: Date(timeIntervalSince1970: 2_000),
      isFromMe: false, senderID: "@whatsapp_lid-2:correspondance.local", senderName: "Papa",
      replyTo: QuotedMessage(messageID: "$1", senderName: "+33675993742", text: "Il lui faudrait un garage")
    )
    XCTAssertEqual(model.sortedMessages.last?.replyTo?.senderName, "Maman maison")
  }
}
