import XCTest
@testable import CorrespondanceCore

/// Le septième pont : Telegram, par mautrix-telegram (le pont Go). Ce qui le
/// distingue des autres, c'est qu'il n'a ni QR ni cookie : un numéro, le code que
/// Telegram pousse dans l'app du téléphone, et le mot de passe de la validation
/// en deux étapes — trois questions typées, par l'API de provisioning.
final class MatrixBridgeTelegramTests: XCTestCase {
  private let serverName = "correspondance.local"

  // MARK: - Descripteur

  func testDescriptorMatchesTheDeployedBridge() throws {
    let tg = try XCTUnwrap(MessageNetwork.telegram.bridge)
    XCTAssertEqual(tg.botLocalpart, "telegrambot")
    XCTAssertEqual(tg.commandPrefix, "!tg")
    XCTAssertEqual(tg.ghostPrefix, "telegram_")
    XCTAssertEqual(tg.loginFlow, .phoneCode)
    XCTAssertFalse(tg.supportsPhonePairing)
    XCTAssertFalse(tg.identifiersArePhoneNumbers)
    XCTAssertFalse(tg.relaysGroupLeave)
    XCTAssertEqual(tg.botUserID(serverName: serverName), "@telegrambot:correspondance.local")
    // Quatre flows chez le connecteur (`phone`, `qr`, `bot`, `manual`) : on suit
    // le numéro, par l'API de provisioning — comme Slack, pas par le chat.
    XCTAssertEqual(tg.webLoginFlowID, "phone")
    XCTAssertEqual(tg.provisionedLoginFlowID, "phone")
    // Le port par défaut du connecteur, libre chez nous (WhatsApp est à 29318).
    XCTAssertEqual(tg.provisioningPort, 29317)
    XCTAssertEqual(tg.accountsHintFR, "Un compte par numéro. Plusieurs numéros possibles.")
    // `pm` prend un pseudo ou un numéro : le connecteur résout les deux.
    XCTAssertEqual(tg.startChatCommand(identifier: "+33612345678"), "pm +33612345678")
    XCTAssertEqual(tg.startChatCommand(identifier: "durov"), "pm durov")
  }

  /// `NetworkID` et `BeeperBridgeType` valent tous deux « telegram » chez ce pont.
  func testBridgeProtocolMapping() {
    XCTAssertEqual(MessageNetwork.fromBridgeProtocol("telegram"), .telegram)
    XCTAssertEqual(MessageNetwork.fromBridgeProtocol("Telegram"), .telegram)
    XCTAssertEqual(MessageNetwork.fromBridgeProtocol("telegramgo"), .telegram)
    // Les voisins gardent les leurs, et un pont qu'on n'a pas reste inconnu.
    XCTAssertEqual(MessageNetwork.fromBridgeProtocol("slackgo"), .slack)
    XCTAssertNil(MessageNetwork.fromBridgeProtocol("discord"))
  }

  func testTelegramIsBridgedAndListedAfterSlack() {
    XCTAssertTrue(MessageNetwork.telegram.isMatrixBridged)
    XCTAssertTrue(MessageNetwork.telegram.livesOnRelay)
    XCTAssertEqual(MessageNetwork.telegram.labelFR, "Telegram")
    XCTAssertEqual(MessageNetwork.telegram.systemImage, "paperplane.fill")
    XCTAssertEqual(
      MessageNetwork.matrixBridged,
      [.signal, .whatsapp, .instagram, .messenger, .twitter, .slack, .telegram]
    )
  }

  // MARK: - Identités

  func testBotAndGhostRecognition() {
    XCTAssertTrue(MatrixIdentity.isBridgeBot("@telegrambot:correspondance.local"))
    XCTAssertEqual(MatrixIdentity.network(ofBot: "@telegrambot:correspondance.local"), .telegram)
    XCTAssertTrue(MatrixIdentity.isGhost("@telegram_777000:correspondance.local"))
    XCTAssertEqual(MatrixIdentity.network(ofGhost: "@telegram_777000:correspondance.local"), .telegram)
    XCTAssertFalse(MatrixIdentity.isBridgeBot("@telegram_777000:correspondance.local"))
  }

  func testStripBridgeSuffix() {
    XCTAssertEqual(MatrixIdentity.stripBridgeSuffix("Camille Roy (Telegram)"), "Camille Roy")
    XCTAssertEqual(MatrixIdentity.stripBridgeSuffix("Camille Roy"), "Camille Roy")
  }

  /// Pas de cookies chez Telegram : ni profil, ni import navigateur, ni collage.
  func testTelegramHasNoCookieProfile() {
    XCTAssertNil(BridgeSessionCookies.Profile.of(.telegram))
  }

  /// Un groupe Telegram arrive comme un groupe : le pont pose `m.bridge` avec son
  /// protocole, et l'app en fait un fil Telegram.
  func testAGroupRoomIsATelegramConversation() throws {
    let response = try JSONDecoder().decode(
      MatrixSyncResponse.self,
      from: Data(
        """
        {"next_batch":"s1","rooms":{"join":{"!famille:correspondance.local":{
          "state":{"events":[
            {"type":"m.bridge","state_key":"fi.mau.telegram://telegram/-1001234567890",
             "sender":"@telegrambot:correspondance.local","event_id":"$b","origin_server_ts":1756500000000,
             "content":{"bridgebot":"@telegrambot:correspondance.local",
               "protocol":{"id":"telegram","displayname":"Telegram"},
               "channel":{"id":"-1001234567890","displayname":"Famille"}}},
            {"type":"m.room.name","state_key":"","sender":"@telegrambot:correspondance.local",
             "event_id":"$n","origin_server_ts":1756500000001,"content":{"name":"Famille"}}
          ]},"timeline":{"events":[]}}}}}
        """.utf8
      )
    )
    var rooms: [String: MatrixRoomModel] = [:]
    MatrixSyncParser(selfUserID: "@meffysto:correspondance.local").apply(response, to: &rooms)
    let room = try XCTUnwrap(rooms["!famille:correspondance.local"])
    XCTAssertEqual(room.network, .telegram)
    XCTAssertNil(room.bridgePhoneNumber)
  }

  func testCapabilities() {
    let caps = MessageNetwork.telegram.capabilities
    XCTAssertTrue(caps.editsSentMessages)
    // Telegram ferme la correction à 48 heures : c'est sa règle, pas celle du pont.
    XCTAssertEqual(caps.editWindow, 48 * 3600)
    XCTAssertNil(caps.deleteWindow)
    XCTAssertTrue(caps.renamesGroup)
    XCTAssertTrue(caps.removesMember)
    XCTAssertTrue(caps.addsMember)
    XCTAssertTrue(caps.createsGroup)
    XCTAssertTrue(caps.sendsVoiceMessages)
    XCTAssertEqual(MessageNetwork.telegram.editWindowLabelFR, "48 heures")
  }

  // MARK: - Le flow par numéro (API de provisioning)

  /// Les trois étapes du flow `phone`, telles que `loginphone.go` les décrit : le
  /// numéro (un champ `phone_number`), le code (un `2fa_code`, masqué), et — si
  /// le compte a la validation en deux étapes — le mot de passe.
  func testDecodesThePhoneFlowSteps() throws {
    let phone = try BridgeLoginProcessStep.decode(Data("""
      {"login_id":"tg-1","type":"user_input","step_id":"fi.mau.telegram.login.phone_number","instructions":"",
       "user_input":{"fields":[{"type":"phone_number","id":"phone_number","name":"Phone number","description":""}]}}
      """.utf8))
    XCTAssertEqual(phone.firstInputField?.id, "phone_number")
    XCTAssertFalse(phone.firstInputField?.isSecret ?? true)
    XCTAssertEqual(phone.userInput?.fields.count, 1)

    let code = try BridgeLoginProcessStep.decode(Data("""
      {"login_id":"tg-1","type":"user_input","step_id":"fi.mau.telegram.login.code","instructions":"",
       "user_input":{"fields":[{"type":"2fa_code","id":"phone_code","name":"Code","description":"The code was sent to the Telegram app on your phone"}]}}
      """.utf8))
    XCTAssertEqual(code.firstInputField?.id, "phone_code")
    XCTAssertTrue(code.firstInputField?.isSecret ?? false)

    let password = try BridgeLoginProcessStep.decode(Data("""
      {"login_id":"tg-1","type":"user_input","step_id":"fi.mau.telegram.login.password","instructions":"You have two-factor authentication enabled.",
       "user_input":{"fields":[{"type":"password","id":"fi.mau.telegram.login.password","name":"Password"}]}}
      """.utf8))
    XCTAssertTrue(password.firstInputField?.isSecret ?? false)

    let done = try BridgeLoginProcessStep.decode(Data("""
      {"login_id":"tg-1","type":"complete","step_id":"fi.mau.telegram.login.complete","instructions":"Successfully logged in as Camille Roy (`777000`)",
       "complete":{"user_login_id":"777000"}}
      """.utf8))
    XCTAssertEqual(done.type, .complete)
    XCTAssertEqual(done.complete?.userLoginID, "777000")
  }

  /// Le pont parle anglais : on traduit par l'étape, par la phrase, et on garde
  /// l'anglais qu'on ne connaît pas — sous le français de l'étape.
  func testFrenchInstructions() throws {
    let phone = try BridgeLoginProcessStep.decode(Data("""
      {"login_id":"x","type":"user_input","step_id":"fi.mau.telegram.login.phone_number","instructions":"","user_input":{"fields":[]}}
      """.utf8))
    XCTAssertEqual(TelegramLoginFrench.instructions(for: phone), "Ton numéro Telegram, avec l'indicatif du pays (+33 6…).")
    XCTAssertEqual(BridgeLoginFrench.instructions(for: phone, network: .telegram), TelegramLoginFrench.instructions(for: phone))

    let incorrect = try BridgeLoginProcessStep.decode(Data("""
      {"login_id":"x","type":"user_input","step_id":"fi.mau.telegram.login.code.incorrect","instructions":"Incorrect code","user_input":{"fields":[]}}
      """.utf8))
    XCTAssertEqual(TelegramLoginFrench.instructions(for: incorrect), "Code refusé. Vérifie-le dans l'app Telegram et réessaie.")

    let unknown = try BridgeLoginProcessStep.decode(Data("""
      {"login_id":"x","type":"user_input","step_id":"fi.mau.telegram.login.password","instructions":"Something new the bridge says","user_input":{"fields":[]}}
      """.utf8))
    XCTAssertEqual(
      TelegramLoginFrench.instructions(for: unknown),
      "Ce compte a la validation en deux étapes : son mot de passe.\nSomething new the bridge says"
    )

    let done = try BridgeLoginProcessStep.decode(Data("""
      {"login_id":"x","type":"complete","step_id":"fi.mau.telegram.login.complete","instructions":"Successfully logged in as Camille Roy (`777000`)"}
      """.utf8))
    XCTAssertEqual(TelegramLoginFrench.instructions(for: done), "Connecté en tant que Camille Roy.")

    // Un pont sans traduction rend l'anglais tel quel.
    XCTAssertEqual(BridgeLoginFrench.instructions(for: unknown, network: .whatsapp), "Something new the bridge says")
  }

  /// Telegram refuse par des codes en majuscules, que le connecteur enveloppe
  /// dans une phrase : on cherche le code, et on lit le délai d'un FLOOD_WAIT.
  func testFrenchErrors() {
    XCTAssertEqual(
      TelegramLoginFrench.error("failed to send code: rpc error code 400: PHONE_NUMBER_INVALID"),
      "Ce numéro n'a pas l'air valide. Au format international, avec l'indicatif : +33 6…"
    )
    XCTAssertEqual(TelegramLoginFrench.error("rpc error code 420: FLOOD_WAIT_23"), "Telegram limite les essais : réessaie dans 23 s.")
    XCTAssertEqual(TelegramLoginFrench.error("FLOOD_WAIT_600"), "Telegram limite les essais : réessaie dans 10 min.")
    XCTAssertEqual(TelegramLoginFrench.error("FLOOD_WAIT_7200"), "Telegram limite les essais : réessaie dans 2 h.")
    XCTAssertEqual(TelegramLoginFrench.error("PHONE_CODE_EXPIRED"), "Ce code a expiré. Relance la connexion pour en recevoir un nouveau.")
    XCTAssertNil(TelegramLoginFrench.error("something else entirely"))
    // L'aiguillage préfixe du réseau ce qu'il ne sait pas traduire.
    XCTAssertEqual(BridgeLoginFrench.error("something else entirely", network: .telegram), "Telegram : something else entirely")
    XCTAssertEqual(BridgeLoginFrench.error("oops", network: .slack), "Slack : oops")
  }

  /// Le mot-clé « telegram » de l'agent reconnaît le bot et les ghosts du pont :
  /// un correspondant Telegram ne pilote jamais cc.
  func testAgentIgnoresTelegramGhosts() {
    XCTAssertTrue(MatrixIdentity.isGhost("@telegram_1234:correspondance.local"))
  }
}
