import XCTest
@testable import Correspondance

/// Le second pont : un `/sync` Instagram (fixture) doit traverser exactement le même
/// chemin que WhatsApp — état `m.bridge`, ghosts, bot — sans que rien de WhatsApp
/// ne soit codé en dur en route.
final class MatrixBridgeInstagramTests: XCTestCase {
  private let selfUserID = "@meffysto:correspondance.local"
  private let dmRoomID = "!dm-malo:correspondance.local"
  private let groupRoomID = "!groupe-atelier:correspondance.local"
  private let managementRoomID = "!gestion-instagram:correspondance.local"

  private func parsedRooms() throws -> [String: MatrixRoomModel] {
    let bundle = Bundle(for: Self.self)
    let url = try XCTUnwrap(
      bundle.url(forResource: "matrix-sync-instagram", withExtension: "json"),
      "fixture matrix-sync-instagram.json absente du bundle de test"
    )
    let response = try JSONDecoder().decode(MatrixSyncResponse.self, from: Data(contentsOf: url))
    var rooms: [String: MatrixRoomModel] = [:]
    MatrixSyncParser(selfUserID: selfUserID).apply(response, to: &rooms)
    return rooms
  }

  // MARK: - Réseau et conversations

  func testNetworkIsResolvedFromInstagramBridgeState() throws {
    let rooms = try parsedRooms()
    XCTAssertEqual(rooms[dmRoomID]?.network, .instagram)
    XCTAssertEqual(rooms[groupRoomID]?.network, .instagram)
    // Salon de gestion : pas d'état `m.bridge` → pas un portail, pas une conversation.
    XCTAssertNil(rooms[managementRoomID]?.network)
    XCTAssertNil(rooms[managementRoomID]?.conversation(selfUserID: selfUserID))
  }

  /// `protocol.id` porte le `BeeperBridgeType` de mautrix (`instagramgo`), mais les
  /// versions plus anciennes y mettaient le nom nu : les deux doivent tomber juste.
  func testBridgeProtocolMappingAcceptsBothSpellings() {
    XCTAssertEqual(MessageNetwork.fromBridgeProtocol("instagramgo"), .instagram)
    XCTAssertEqual(MessageNetwork.fromBridgeProtocol("Instagram"), .instagram)
    XCTAssertEqual(MessageNetwork.fromBridgeProtocol("whatsappgo"), .whatsapp)
    XCTAssertEqual(MessageNetwork.fromBridgeProtocol("whatsapp"), .whatsapp)
    XCTAssertNil(MessageNetwork.fromBridgeProtocol("messenger"))
  }

  func testDirectConversationFromInstagramRoom() throws {
    let room = try XCTUnwrap(try parsedRooms()[dmRoomID])
    let conversation = try XCTUnwrap(room.conversation(selfUserID: selfUserID))
    XCTAssertEqual(conversation.id, "instagram:\(dmRoomID)")
    XCTAssertEqual(conversation.network, .instagram)
    XCTAssertEqual(conversation.transportKey, dmRoomID)
    XCTAssertEqual(conversation.title, "Malo")
    XCTAssertFalse(conversation.isGroup)
    XCTAssertEqual(conversation.unreadCount, 3)
    // Instagram n'expose aucun numéro : l'adresse reste le salon, jamais un MXID de ghost.
    XCTAssertNil(room.bridgePhoneNumber)
    XCTAssertEqual(conversation.address, dmRoomID)
    XCTAssertEqual(conversation.preview, "Oui, superbe lumière.")
  }

  /// Dans un DM, le pont ajoute aussi mon propre ghost : seul le correspondant compte.
  func testRemoteMembersExcludeBotAndMyOwnGhost() throws {
    let room = try XCTUnwrap(try parsedRooms()[dmRoomID])
    XCTAssertEqual(
      room.remoteMembers(selfUserID: selfUserID).map(\.userID),
      ["@instagram_17841400000000001:correspondance.local"]
    )
  }

  func testGroupRoomIsDetectedAndNamed() throws {
    let room = try XCTUnwrap(try parsedRooms()[groupRoomID])
    let conversation = try XCTUnwrap(room.conversation(selfUserID: selfUserID))
    XCTAssertTrue(conversation.isGroup)
    XCTAssertEqual(conversation.title, "Atelier photo")
    XCTAssertEqual(
      room.remoteMembers(selfUserID: selfUserID).map(\.userID),
      [
        "@instagram_17841400000000002:correspondance.local",
        "@instagram_17841400000000003:correspondance.local",
      ]
    )
  }

  func testMessagesCarryTheInstagramNetwork() throws {
    let room = try XCTUnwrap(try parsedRooms()[dmRoomID])
    let messages = room.sortedMessages
    XCTAssertEqual(messages.map(\.id), ["$msg-malo-1", "$msg-moi-ig"])
    XCTAssertTrue(messages.allSatisfy { $0.network == .instagram })
    XCTAssertTrue(messages.allSatisfy { $0.conversationID == "instagram:\(dmRoomID)" })
    // Une réaction n'est pas un message : elle se rattache à sa cible.
    XCTAssertEqual(messages[1].reactions.map(\.emoji), ["🔥"])
  }
}

// MARK: - Identités

extension MatrixBridgeInstagramTests {
  func testBotAndGhostRecognition() {
    XCTAssertTrue(MatrixIdentity.isBridgeBot("@instagrambot:correspondance.local"))
    XCTAssertEqual(MatrixIdentity.network(ofBot: "@instagrambot:correspondance.local"), .instagram)
    XCTAssertTrue(MatrixIdentity.isGhost("@instagram_17841400000000001:correspondance.local"))
    XCTAssertEqual(
      MatrixIdentity.network(ofGhost: "@instagram_17841400000000001:correspondance.local"),
      .instagram
    )
    XCTAssertFalse(MatrixIdentity.isBridgeBot("@instagram_17841400000000001:correspondance.local"))

    // Non-régression WhatsApp.
    XCTAssertTrue(MatrixIdentity.isBridgeBot("@whatsappbot:correspondance.local"))
    XCTAssertEqual(MatrixIdentity.network(ofBot: "@whatsappbot:correspondance.local"), .whatsapp)
    XCTAssertTrue(MatrixIdentity.isGhost("@whatsapp_lid-19876543210:correspondance.local"))
    XCTAssertEqual(
      MatrixIdentity.network(ofGhost: "@whatsapp_lid-19876543210:correspondance.local"),
      .whatsapp
    )

    // Un pont qu'on ne gère pas ne doit pas se faire passer pour l'un des nôtres.
    XCTAssertFalse(MatrixIdentity.isBridgeBot("@telegrambot:correspondance.local"))
    XCTAssertFalse(MatrixIdentity.isGhost("@telegram_1234:correspondance.local"))
    XCTAssertFalse(MatrixIdentity.isBridgeBot("@meffysto:correspondance.local"))
  }

  func testStripBridgeSuffix() {
    XCTAssertEqual(MatrixIdentity.stripBridgeSuffix("Malo (IG)"), "Malo")
    XCTAssertEqual(MatrixIdentity.stripBridgeSuffix("Malo (Instagram)"), "Malo")
    XCTAssertEqual(MatrixIdentity.stripBridgeSuffix("Alice Martin (WA)"), "Alice Martin")
    // Rien à retirer : le nom reste intact, espaces de bord en moins.
    XCTAssertEqual(MatrixIdentity.stripBridgeSuffix("  Nina Roche "), "Nina Roche")
  }

  /// Un identifiant Instagram n'est pas un numéro, même en chiffres : aucune fusion
  /// de contact ne doit s'appuyer dessus.
  func testInstagramIdentifiersNeverBecomePhoneNumbers() {
    XCTAssertNil(PhoneNormalizer.identityKey(for: "@instagram_17841400000000001:correspondance.local"))
    XCTAssertNil(MatrixIdentity.phoneNumber(in: "17841400000000001"))
    // Le préfixe de transport reste retiré pour WhatsApp, lui bien numéroté.
    XCTAssertEqual(PhoneNormalizer.identityKey(for: "@whatsapp_33612345678:serveur"), "tel:33612345678")
  }
}

// MARK: - Descripteurs et dialogue avec le bot

extension MatrixBridgeInstagramTests {
  func testDescriptorsMatchTheDeployedBridges() throws {
    let instagram = try XCTUnwrap(MessageNetwork.instagram.bridge)
    XCTAssertEqual(instagram.botLocalpart, "instagrambot")
    XCTAssertEqual(instagram.commandPrefix, "!ig")
    XCTAssertEqual(instagram.ghostPrefix, "instagram_")
    XCTAssertEqual(instagram.loginFlow, .webSession)
    XCTAssertEqual(instagram.botUserID(serverName: "correspondance.local"), "@instagrambot:correspondance.local")
    XCTAssertEqual(instagram.startChatCommand(identifier: "17841400000000001"), "pm 17841400000000001")

    let whatsapp = try XCTUnwrap(MessageNetwork.whatsapp.bridge)
    XCTAssertEqual(whatsapp.commandPrefix, "!wa")
    XCTAssertEqual(whatsapp.loginFlow, .qrCode)

    XCTAssertNil(MessageNetwork.iMessage.bridge)
    XCTAssertNil(MessageNetwork.signal.bridge)
    XCTAssertEqual(MessageNetwork.matrixBridged, [.whatsapp, .instagram])
  }

  /// Les réponses du bot pendant un login par cookies, telles que bridgev2 les écrit.
  func testCookieLoginStepsAreRecognised() {
    XCTAssertEqual(
      MatrixBridgeService.loginStep(
        inBotMessage: "Enter a JSON object with your cookies, or a cURL command copied from browser devtools."
      ),
      .awaitingCookies("Enter a JSON object with your cookies, or a cURL command copied from browser devtools.")
    )
    XCTAssertEqual(
      MatrixBridgeService.loginStep(inBotMessage: "Login URL: <https://www.instagram.com/accounts/login/>"),
      .awaitingCookies("Login URL: <https://www.instagram.com/accounts/login/>")
    )
    guard case .success = MatrixBridgeService.loginStep(inBotMessage: "Logged in as Malo (17841400000000001)") else {
      return XCTFail("« Logged in as … » doit valoir un succès")
    }
    guard case .failure = MatrixBridgeService.loginStep(inBotMessage: "Missing some keys: [sessionid ig_did]") else {
      return XCTFail("clés manquantes = échec")
    }
    guard case .failure = MatrixBridgeService.loginStep(
      inBotMessage: "Failed to parse input as JSON: invalid character 'c'"
    ) else {
      return XCTFail("JSON illisible = échec")
    }
    guard case .failure = MatrixBridgeService.loginStep(
      inBotMessage: "Login failed: Checkpoint required, please check the official website or app and then try again"
    ) else {
      return XCTFail("checkpoint Meta = échec")
    }
    // Un message qui ne parle pas du login ne doit rien conclure.
    XCTAssertNil(MatrixBridgeService.loginStep(inBotMessage: "Connected to Instagram"))
  }

  /// Non-régression du flux QR : ce que mautrix-whatsapp répond n'a pas bougé.
  func testWhatsAppLoginStepsStillParse() {
    guard case .success = MatrixBridgeService.loginStep(inBotMessage: "Successfully logged in as +33612345678") else {
      return XCTFail("succès WhatsApp non reconnu")
    }
    guard case .failure = MatrixBridgeService.loginStep(inBotMessage: "Login timed out") else {
      return XCTFail("expiration WhatsApp non reconnue")
    }
    XCTAssertEqual(
      MatrixBridgeService.pairingCode(in: "Input the pairing code `ABCD-EFGH` in the WhatsApp app"),
      "ABCD-EFGH"
    )
    XCTAssertEqual(
      MatrixBridgeService.loginStep(inBotMessage: "Input the pairing code abcd-efgh in the WhatsApp app"),
      .pairingCode("ABCD-EFGH")
    )
    XCTAssertNil(MatrixBridgeService.pairingCode(in: "Scan the QR code"))
  }

  /// `search <pseudo>` : bridgev2 formate chaque résultat en `` `id` / Nom ``.
  /// Les ghosts Meta étant numériques, c'est de là que sort l'identifiant du `pm`.
  func testFirstSearchResultIDIsExtracted() {
    XCTAssertEqual(
      MatrixBridgeService.firstSearchResultID(
        in: "Found 2 results:\n* `17841400000000001` / Malo\n* `17841400000000002` / Malo Photo"
      ),
      "17841400000000001"
    )
    XCTAssertNil(MatrixBridgeService.firstSearchResultID(in: "Identifier `malo` not found"))
  }
}
