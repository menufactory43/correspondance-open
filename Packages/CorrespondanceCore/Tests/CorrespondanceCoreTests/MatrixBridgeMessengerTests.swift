import XCTest
@testable import CorrespondanceCore

/// Le quatrième pont. Messenger sort de la même image Docker qu'Instagram, mais d'un
/// autre binaire : un autre bot, un autre préfixe de ghosts, un autre `protocol.id`.
/// Ce qui compte ici, c'est que rien ne se confonde — un ghost Messenger ne doit
/// jamais être pris pour un ghost Instagram, ni l'inverse.
final class MatrixBridgeMessengerTests: XCTestCase {
  private let serverName = "correspondance.local"

  // MARK: - Descripteur

  func testDescriptorMatchesTheDeployedBridge() throws {
    let messenger = try XCTUnwrap(MessageNetwork.messenger.bridge)
    XCTAssertEqual(messenger.botLocalpart, "messengerbot")
    XCTAssertEqual(messenger.commandPrefix, "!fb")
    XCTAssertEqual(messenger.ghostPrefix, "messenger_")
    XCTAssertEqual(messenger.loginFlow, .webSession)
    XCTAssertFalse(messenger.supportsPhonePairing)
    XCTAssertFalse(messenger.identifiersArePhoneNumbers)
    XCTAssertFalse(messenger.relaysGroupLeave)
    XCTAssertEqual(messenger.botUserID(serverName: serverName), "@messengerbot:correspondance.local")
    // `pm` est l'alias de `start-chat` : un identifiant Meta, jamais un numéro.
    XCTAssertEqual(messenger.startChatCommand(identifier: "100012345678901"), "pm 100012345678901")
    // mautrix-facebook annonce quatre flows de connexion : sans en nommer un,
    // bridgev2 refuse d'ouvrir la tentative. On prend `messenger` (messenger.com),
    // qui ne dépend pas de l'état du compte Facebook.
    XCTAssertEqual(messenger.webLoginFlowID, "messenger")
  }

  /// Les quatre orthographes sous lesquelles le pont peut s'annoncer dans `m.bridge`.
  /// `facebook` est son `id` par défaut, `facebookgo` son `BeeperBridgeType`.
  func testBridgeProtocolMapping() {
    XCTAssertEqual(MessageNetwork.fromBridgeProtocol("facebook"), .messenger)
    XCTAssertEqual(MessageNetwork.fromBridgeProtocol("facebookgo"), .messenger)
    XCTAssertEqual(MessageNetwork.fromBridgeProtocol("Messenger"), .messenger)
    XCTAssertEqual(MessageNetwork.fromBridgeProtocol("meta"), .messenger)
    // Instagram garde les siennes : les deux réseaux de Meta ne se recouvrent pas.
    XCTAssertEqual(MessageNetwork.fromBridgeProtocol("instagramgo"), .instagram)
  }

  func testMessengerIsBridgedAndListedAfterInstagram() {
    XCTAssertTrue(MessageNetwork.messenger.isMatrixBridged)
    XCTAssertTrue(MessageNetwork.messenger.livesOnRelay)
    XCTAssertEqual(MessageNetwork.messenger.labelFR, "Messenger")
    XCTAssertEqual(MessageNetwork.matrixBridged, [.signal, .whatsapp, .instagram, .messenger])
  }

  // MARK: - Identités

  func testBotAndGhostRecognition() {
    XCTAssertTrue(MatrixIdentity.isBridgeBot("@messengerbot:correspondance.local"))
    XCTAssertEqual(MatrixIdentity.network(ofBot: "@messengerbot:correspondance.local"), .messenger)
    XCTAssertTrue(MatrixIdentity.isGhost("@messenger_100012345678901:correspondance.local"))
    XCTAssertEqual(
      MatrixIdentity.network(ofGhost: "@messenger_100012345678901:correspondance.local"),
      .messenger
    )
    XCTAssertFalse(MatrixIdentity.isBridgeBot("@messenger_100012345678901:correspondance.local"))

    // Non-régression : le voisin de la même image ne doit rien s'approprier.
    XCTAssertEqual(
      MatrixIdentity.network(ofGhost: "@instagram_17841400000000001:correspondance.local"),
      .instagram
    )
    XCTAssertEqual(MatrixIdentity.network(ofBot: "@instagrambot:correspondance.local"), .instagram)
  }

  func testStripBridgeSuffix() {
    XCTAssertEqual(MatrixIdentity.stripBridgeSuffix("Camille Roy (FB)"), "Camille Roy")
    XCTAssertEqual(MatrixIdentity.stripBridgeSuffix("Camille Roy (Messenger)"), "Camille Roy")
  }

  /// Un identifiant Facebook est numérique et long — quinze chiffres, exactement la
  /// longueur d'un E.164 maximal. Il ressemble à un numéro sans en être un, et aucune
  /// fusion de contact ne doit s'appuyer dessus : ni depuis le ghost…
  func testMessengerIdentifiersNeverBecomePhoneNumbers() {
    XCTAssertNil(
      PhoneNormalizer.identityKey(for: "@messenger_100012345678901:correspondance.local")
    )
  }

  /// …ni depuis le `channel.id` de l'état de bridge, que le parseur lisait jusqu'ici
  /// comme un numéro dès qu'il tenait en quinze chiffres.
  func testBridgeChannelIDIsNeverReadAsAPhoneNumber() throws {
    let response = try JSONDecoder().decode(
      MatrixSyncResponse.self,
      from: Data(
        """
        {"next_batch":"s1","rooms":{"join":{"!fb-camille:correspondance.local":{
          "state":{"events":[
            {"type":"m.bridge","state_key":"fi.mau.facebook://facebook/100012345678901",
             "sender":"@messengerbot:correspondance.local","event_id":"$state-bridge-fb",
             "origin_server_ts":1756500000000,
             "content":{"bridgebot":"@messengerbot:correspondance.local",
               "protocol":{"id":"facebookgo","displayname":"Facebook Messenger"},
               "channel":{"id":"100012345678901","displayname":"Camille Roy"},
               "com.beeper.room_type":"dm"}}
          ]},"timeline":{"events":[]}}}}}
        """.utf8
      )
    )
    var rooms: [String: MatrixRoomModel] = [:]
    MatrixSyncParser(selfUserID: "@meffysto:correspondance.local").apply(response, to: &rooms)
    let room = try XCTUnwrap(rooms["!fb-camille:correspondance.local"])
    XCTAssertEqual(room.network, .messenger)
    XCTAssertNil(room.bridgePhoneNumber)
    // Faute de numéro, l'adresse du fil reste le salon — jamais un faux « + ».
    let conversation = try XCTUnwrap(room.conversation(selfUserID: "@meffysto:correspondance.local"))
    XCTAssertEqual(conversation.address, "!fb-camille:correspondance.local")
    XCTAssertEqual(conversation.title, "Camille Roy")
  }

  // MARK: - Capacités

  /// Mêmes capacités qu'Instagram : c'est le même connecteur, à un binaire près.
  func testCapabilitiesFollowInstagram() {
    XCTAssertEqual(MessageNetwork.messenger.capabilities, MessageNetwork.instagram.capabilities)
    XCTAssertTrue(MessageNetwork.messenger.supportsEditing)
    XCTAssertTrue(MessageNetwork.messenger.supportsVoiceMessages)
    XCTAssertTrue(MessageNetwork.messenger.supportsMemberInvite)
    // Ni renommage ni retrait tant que le pont ne les a pas remontés sur un vrai compte.
    XCTAssertFalse(MessageNetwork.messenger.supportsGroupRename)
    XCTAssertFalse(MessageNetwork.messenger.supportsMemberRemoval)
  }

  // MARK: - Dialogue avec le bot

  /// Les réponses de mautrix-facebook pendant un login par cookies. Ce sont les
  /// chaînes de bridgev2 : les mêmes que côté Instagram, à l'URL près.
  func testCookieLoginStepsAreRecognised() {
    XCTAssertEqual(
      MatrixBridgeService.loginStep(
        inBotMessage: "Enter a JSON object with your cookies, or a cURL command copied from browser devtools."
      ),
      .awaitingCookies("Enter a JSON object with your cookies, or a cURL command copied from browser devtools.")
    )
    XCTAssertEqual(
      MatrixBridgeService.loginStep(inBotMessage: "Login URL: <https://www.messenger.com/?no_redirect=true>"),
      .awaitingCookies("Login URL: <https://www.messenger.com/?no_redirect=true>")
    )
    guard case .success = MatrixBridgeService.loginStep(
      inBotMessage: "Logged in as Camille Roy (100012345678901)"
    ) else {
      return XCTFail("« Logged in as … » doit valoir un succès")
    }
    // Le refus du connecteur quand `datr` manque.
    guard case .failure = MatrixBridgeService.loginStep(
      inBotMessage: "Login failed: Missing cookies: [datr]"
    ) else {
      return XCTFail("cookies manquants = échec")
    }
    // Le flow non nommé : la tentative n'a jamais commencé, il faut le dire.
    guard case .failure = MatrixBridgeService.loginStep(
      inBotMessage: "Please specify a login flow, e.g. `login facebook`."
    ) else {
      return XCTFail("flow non choisi = échec")
    }
    XCTAssertNil(MatrixBridgeService.loginStep(inBotMessage: "Connected to Facebook Messenger"))
  }

  /// `search <nom>` : bridgev2 formate chaque résultat en `` `id` / Nom ``, quel que
  /// soit le réseau Meta — c'est de là que sort l'identifiant du `pm`.
  func testFirstSearchResultIDIsExtracted() {
    XCTAssertEqual(
      MatrixBridgeService.firstSearchResultID(
        in: "Found 2 results:\n* `100012345678901` / Camille Roy\n* `100012345678902` / Camille R."
      ),
      "100012345678901"
    )
  }
}
