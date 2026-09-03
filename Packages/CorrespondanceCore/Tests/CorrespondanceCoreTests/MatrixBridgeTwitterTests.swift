import XCTest
@testable import CorrespondanceCore

/// Le cinquième pont : X, par mautrix-twitter. Ce qui le distingue des autres
/// réseaux à cookies, c'est l'étape de plus — le code PIN de X Chat, demandé après
/// la session — et un connecteur qui résout les pseudos tout seul, sans `search`.
final class MatrixBridgeTwitterTests: XCTestCase {
  private let serverName = "correspondance.local"

  // MARK: - Descripteur

  func testDescriptorMatchesTheDeployedBridge() throws {
    let x = try XCTUnwrap(MessageNetwork.twitter.bridge)
    XCTAssertEqual(x.botLocalpart, "twitterbot")
    XCTAssertEqual(x.commandPrefix, "!tw")
    XCTAssertEqual(x.ghostPrefix, "twitter_")
    XCTAssertEqual(x.loginFlow, .webSession)
    XCTAssertFalse(x.supportsPhonePairing)
    XCTAssertFalse(x.identifiersArePhoneNumbers)
    XCTAssertFalse(x.relaysGroupLeave)
    XCTAssertEqual(x.botUserID(serverName: serverName), "@twitterbot:correspondance.local")
    // Le connecteur annonce deux flows (`cookies`, `password`) : sans en nommer
    // un, bridgev2 refuse d'ouvrir la tentative.
    XCTAssertEqual(x.webLoginFlowID, "cookies")
    // `pm` prend le pseudo tel quel : c'est le connecteur qui le résout.
    XCTAssertEqual(x.startChatCommand(identifier: "jack"), "pm jack")
  }

  /// `NetworkID` et `BeeperBridgeType` valent tous deux « twitter » chez ce pont.
  func testBridgeProtocolMapping() {
    XCTAssertEqual(MessageNetwork.fromBridgeProtocol("twitter"), .twitter)
    XCTAssertEqual(MessageNetwork.fromBridgeProtocol("Twitter"), .twitter)
    XCTAssertEqual(MessageNetwork.fromBridgeProtocol("x"), .twitter)
    // Les voisins gardent les leurs.
    XCTAssertEqual(MessageNetwork.fromBridgeProtocol("facebookgo"), .messenger)
    XCTAssertEqual(MessageNetwork.fromBridgeProtocol("instagramgo"), .instagram)
  }

  func testXIsBridgedAndListedAfterMessenger() {
    XCTAssertTrue(MessageNetwork.twitter.isMatrixBridged)
    XCTAssertTrue(MessageNetwork.twitter.livesOnRelay)
    XCTAssertEqual(MessageNetwork.twitter.labelFR, "X")
    XCTAssertEqual(MessageNetwork.matrixBridged, [.signal, .whatsapp, .instagram, .messenger, .twitter, .slack])
  }

  // MARK: - Identités

  func testBotAndGhostRecognition() {
    XCTAssertTrue(MatrixIdentity.isBridgeBot("@twitterbot:correspondance.local"))
    XCTAssertEqual(MatrixIdentity.network(ofBot: "@twitterbot:correspondance.local"), .twitter)
    XCTAssertTrue(MatrixIdentity.isGhost("@twitter_44196397:correspondance.local"))
    XCTAssertEqual(MatrixIdentity.network(ofGhost: "@twitter_44196397:correspondance.local"), .twitter)
    XCTAssertFalse(MatrixIdentity.isBridgeBot("@twitter_44196397:correspondance.local"))
  }

  /// `displayname_template` vaut « (Twitter) » par défaut, « (X) » dans notre gabarit.
  func testStripBridgeSuffix() {
    XCTAssertEqual(MatrixIdentity.stripBridgeSuffix("Camille Roy (X)"), "Camille Roy")
    XCTAssertEqual(MatrixIdentity.stripBridgeSuffix("Camille Roy (Twitter)"), "Camille Roy")
  }

  /// Un identifiant X est un entier de Snowflake — jusqu'à dix-neuf chiffres. Il ne
  /// doit jamais passer pour un numéro, ni depuis le ghost…
  func testXIdentifiersNeverBecomePhoneNumbers() {
    XCTAssertNil(PhoneNormalizer.identityKey(for: "@twitter_44196397:correspondance.local"))
  }

  /// …ni depuis le `channel.id` de l'état de bridge.
  func testBridgeChannelIDIsNeverReadAsAPhoneNumber() throws {
    let response = try JSONDecoder().decode(
      MatrixSyncResponse.self,
      from: Data(
        """
        {"next_batch":"s1","rooms":{"join":{"!x-camille:correspondance.local":{
          "state":{"events":[
            {"type":"m.bridge","state_key":"fi.mau.twitter://twitter/44196397",
             "sender":"@twitterbot:correspondance.local","event_id":"$state-bridge-x",
             "origin_server_ts":1756500000000,
             "content":{"bridgebot":"@twitterbot:correspondance.local",
               "protocol":{"id":"twitter","displayname":"X"},
               "channel":{"id":"44196397","displayname":"Camille Roy"},
               "com.beeper.room_type":"dm"}}
          ]},"timeline":{"events":[]}}}}}
        """.utf8
      )
    )
    var rooms: [String: MatrixRoomModel] = [:]
    MatrixSyncParser(selfUserID: "@meffysto:correspondance.local").apply(response, to: &rooms)
    let room = try XCTUnwrap(rooms["!x-camille:correspondance.local"])
    XCTAssertEqual(room.network, .twitter)
    XCTAssertNil(room.bridgePhoneNumber)
    let conversation = try XCTUnwrap(room.conversation(selfUserID: "@meffysto:correspondance.local"))
    XCTAssertEqual(conversation.title, "Camille Roy")
  }

  // MARK: - Capacités

  /// Lu dans `capabilities.go` du pont : correction quinze minutes, suppression sans
  /// délai, nom du groupe et invitation relayés, pas de retrait, pas de vocal.
  func testCapabilitiesFollowTheConnector() {
    let caps = MessageNetwork.twitter.capabilities
    XCTAssertTrue(caps.editsSentMessages)
    XCTAssertEqual(caps.editWindow, 15 * 60)
    XCTAssertNil(caps.deleteWindow)
    XCTAssertTrue(caps.renamesGroup)
    XCTAssertTrue(caps.addsMember)
    XCTAssertFalse(caps.removesMember)
    XCTAssertFalse(caps.createsGroup)
    XCTAssertFalse(caps.sendsVoiceMessages)
  }

  // MARK: - Session

  func testCookieProfileTakesExactlyTheTwoRequiredCookies() throws {
    let profile = try XCTUnwrap(BridgeSessionCookies.Profile.of(.twitter))
    XCTAssertEqual(profile.loginURL.absoluteString, "https://x.com/i/flow/login")
    XCTAssertTrue(profile.acceptsDomain(".x.com"))
    XCTAssertTrue(profile.acceptsDomain("api.x.com"))
    XCTAssertFalse(profile.acceptsDomain("twitter.com"))
    XCTAssertFalse(profile.acceptsDomain("faux-x.com"))

    let session = try XCTUnwrap(
      BridgeSessionCookies(rawCookies: ["auth_token": "a", "ct0": "c", "guest_id": "g"], profile: profile)
    )
    XCTAssertEqual(session.values, ["auth_token": "a", "ct0": "c"])
    XCTAssertEqual(session.jsonPayload, "{\"auth_token\":\"a\",\"ct0\":\"c\"}")
    for missing in ["auth_token", "ct0"] {
      var partial = ["auth_token": "a", "ct0": "c"]
      partial[missing] = nil
      XCTAssertNil(BridgeSessionCookies(rawCookies: partial, profile: profile), "sans \(missing)")
    }
  }

  /// Le mode d'emploi du repli nomme le site, le domaine et les deux cookies —
  /// et le modèle ne porte qu'eux, dans l'ordre alphabétique.
  func testManualCookieGuideNamesTheRightSiteAndCookies() throws {
    let profile = try XCTUnwrap(BridgeSessionCookies.Profile.of(.twitter))
    let steps = profile.manualCookieStepsFR
    XCTAssertEqual(steps.count, 6)
    XCTAssertTrue(steps[0].contains("x.com"))
    XCTAssertTrue(steps[3].contains("https://x.com"))
    XCTAssertTrue(steps[4].contains("`auth_token` et `ct0`"))
    XCTAssertEqual(profile.manualCookieTemplate, "{\"auth_token\":\"…\",\"ct0\":\"…\"}")
    // Messenger en a trois : la liste se lit encore.
    XCTAssertTrue(BridgeSessionCookies.Profile.messenger.manualCookieStepsFR[4].contains("`c_user`, `datr` et `xs`"))
  }

  // MARK: - Dialogue avec le bot

  /// Les mots de bridgev2 et de `makePINStep` pendant un login X : les cookies,
  /// puis le PIN, puis le succès — et, entre les deux, le PIN refusé.
  func testLoginStepsAreRecognised() {
    XCTAssertEqual(
      MatrixBridgeService.loginStep(inBotMessage: "Login URL: <https://x.com/i/flow/login>"),
      .awaitingCookies("Login URL: <https://x.com/i/flow/login>")
    )
    XCTAssertEqual(
      MatrixBridgeService.loginStep(inBotMessage: "Please enter your Passcode"),
      .awaitingPasscode(isSetup: false, hint: nil)
    )
    XCTAssertEqual(
      MatrixBridgeService.loginStep(
        inBotMessage: "To retrieve your encrypted messages, please enter your passcode below. For more information see: https://help.x.com/en/using-x/about-chat"
      ),
      .awaitingPasscode(isSetup: false, hint: nil)
    )
    XCTAssertEqual(
      MatrixBridgeService.loginStep(inBotMessage: "Please enter your Create your PIN code"),
      .awaitingPasscode(isSetup: true, hint: nil)
    )
    XCTAssertEqual(
      MatrixBridgeService.loginStep(
        inBotMessage: "No PIN code is registered yet. Register by creating your PIN code below or using the X app."
      ),
      .awaitingPasscode(isSetup: true, hint: nil)
    )
    XCTAssertEqual(
      MatrixBridgeService.loginStep(
        inBotMessage: "Invalid passcode. You have 2 guesses remaining.\n\nTo retrieve your encrypted messages, please enter your passcode below."
      ),
      .awaitingPasscode(isSetup: false, hint: "Invalid passcode. You have 2 guesses remaining.")
    )
    guard case .success = MatrixBridgeService.loginStep(inBotMessage: "Successfully logged into X as @camille") else {
      return XCTFail("« Successfully logged into X » doit valoir un succès")
    }
    // Trop d'essais : le connecteur répond par une erreur, que bridgev2 préfixe.
    guard case .failure = MatrixBridgeService.loginStep(
      inBotMessage: "Failed to submit input: Too many incorrect passcode attempts. X Chat is locked."
    ) else {
      return XCTFail("X Chat verrouillé = échec")
    }
    guard case .failure = MatrixBridgeService.loginStep(inBotMessage: "Missing some keys: [ct0]") else {
      return XCTFail("cookie manquant = échec")
    }
    XCTAssertNil(MatrixBridgeService.loginStep(inBotMessage: "Connected to X"))
  }

  /// `resolve-identifier` répond dans le même moule que `search` : `` `id` / Nom ``.
  func testResolveIdentifierReplyYieldsTheNumericID() {
    XCTAssertEqual(MatrixBridgeService.firstSearchResultID(in: "Found `44196397` / Camille Roy"), "44196397")
  }

  /// Une espace finale copiée avec le cookie fait répondre à X « Could not
  /// authenticate you » : vu le 3 septembre, depuis le tableau des cookies de Brave.
  func testPastedCookieValuesLoseTheirSurroundingBlanks() {
    XCTAssertEqual(
      MatrixBridgeService.normalizedCookiePayload("  {\"auth_token\":\"abc \",\"ct0\":\" def\"}\n"),
      "{\"auth_token\":\"abc\",\"ct0\":\"def\"}"
    )
    // Ce qui n'est pas un objet JSON de chaînes ne bouge pas : une commande cURL, un PIN.
    XCTAssertEqual(MatrixBridgeService.normalizedCookiePayload(" curl 'https://x.com' -H 'cookie: a=b' "), "curl 'https://x.com' -H 'cookie: a=b'")
    XCTAssertEqual(MatrixBridgeService.normalizedCookiePayload("1234\n"), "1234")
  }

  func testHandleIsStrippedOfItsAtSign() {
    XCTAssertEqual(MatrixBridgeService.twitterHandle(" @camille "), "camille")
    XCTAssertEqual(MatrixBridgeService.twitterHandle("camille"), "camille")
  }
}
