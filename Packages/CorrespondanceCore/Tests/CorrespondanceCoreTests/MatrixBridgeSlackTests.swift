import XCTest
@testable import CorrespondanceCore

/// Le sixième pont : Slack, par mautrix-slack. Ce qui le distingue, c'est une
/// session en deux morceaux — le jeton du localStorage, le cookie `d` — et des
/// canaux qui arrivent comme des groupes.
final class MatrixBridgeSlackTests: XCTestCase {
  private let serverName = "correspondance.local"

  func testDescriptorMatchesTheDeployedBridge() throws {
    let slack = try XCTUnwrap(MessageNetwork.slack.bridge)
    XCTAssertEqual(slack.botLocalpart, "slackbot")
    XCTAssertEqual(slack.commandPrefix, "!slack")
    XCTAssertEqual(slack.ghostPrefix, "slack_")
    XCTAssertEqual(slack.loginFlow, .webSession)
    XCTAssertFalse(slack.identifiersArePhoneNumbers)
    XCTAssertEqual(slack.webLoginFlowID, "email")
    XCTAssertEqual(slack.botUserID(serverName: serverName), "@slackbot:correspondance.local")
  }

  func testBridgeProtocolMapping() {
    XCTAssertEqual(MessageNetwork.fromBridgeProtocol("slack"), .slack)
    XCTAssertEqual(MessageNetwork.fromBridgeProtocol("slackgo"), .slack)
    XCTAssertEqual(MessageNetwork.fromBridgeProtocol("twitter"), .twitter)
  }

  func testSlackIsBridgedAndListedAfterX() {
    XCTAssertTrue(MessageNetwork.slack.isMatrixBridged)
    XCTAssertEqual(MessageNetwork.slack.labelFR, "Slack")
    XCTAssertEqual(
      MessageNetwork.matrixBridged,
      [.signal, .whatsapp, .instagram, .messenger, .twitter, .slack]
    )
  }

  func testBotAndGhostRecognition() {
    XCTAssertTrue(MatrixIdentity.isBridgeBot("@slackbot:correspondance.local"))
    XCTAssertEqual(MatrixIdentity.network(ofBot: "@slackbot:correspondance.local"), .slack)
    XCTAssertTrue(MatrixIdentity.isGhost("@slack_T0123-U0456:correspondance.local"))
    XCTAssertEqual(MatrixIdentity.network(ofGhost: "@slack_T0123-U0456:correspondance.local"), .slack)
  }

  /// Un canal arrive comme un groupe : le pont pose `com.beeper.room_type`
  /// autrement que « dm », et l'app le rend comme un groupe, avec ses membres.
  func testAChannelIsAGroupRoom() throws {
    let response = try JSONDecoder().decode(
      MatrixSyncResponse.self,
      from: Data(
        """
        {"next_batch":"s1","rooms":{"join":{"!general:correspondance.local":{
          "state":{"events":[
            {"type":"m.bridge","state_key":"fi.mau.slack://slack/T0123/C0456",
             "sender":"@slackbot:correspondance.local","event_id":"$b","origin_server_ts":1756500000000,
             "content":{"bridgebot":"@slackbot:correspondance.local",
               "protocol":{"id":"slackgo","displayname":"Slack"},
               "channel":{"id":"C0456","displayname":"général"}}},
            {"type":"m.room.name","state_key":"","sender":"@slackbot:correspondance.local",
             "event_id":"$n","origin_server_ts":1756500000001,"content":{"name":"général"}}
          ]},"timeline":{"events":[]}}}}}
        """.utf8
      )
    )
    var rooms: [String: MatrixRoomModel] = [:]
    MatrixSyncParser(selfUserID: "@meffysto:correspondance.local").apply(response, to: &rooms)
    let room = try XCTUnwrap(rooms["!general:correspondance.local"])
    XCTAssertEqual(room.network, .slack)
    XCTAssertNil(room.bridgePhoneNumber)
  }

  func testCapabilities() {
    let caps = MessageNetwork.slack.capabilities
    XCTAssertTrue(caps.editsSentMessages)
    XCTAssertNil(caps.editWindow)
    XCTAssertTrue(caps.renamesGroup)
    XCTAssertTrue(caps.removesMember)
    XCTAssertTrue(caps.addsMember)
    XCTAssertTrue(caps.sendsVoiceMessages)
    XCTAssertFalse(caps.createsGroup)
  }

  // MARK: - Session

  func testSessionRequiresBothTokensWithTheRightPrefixes() {
    let ok = SlackLoginSession(authToken: "xoxc-abc", cookieToken: "xoxd-def")
    XCTAssertEqual(ok?.jsonPayload, "{\"auth_token\":\"xoxc-abc\",\"cookie_token\":\"xoxd-def\"}")
    // Blancs de bord retirés (une valeur copiée d'un tableau).
    XCTAssertEqual(SlackLoginSession(authToken: " xoxc-abc\n", cookieToken: "xoxd-def ")?.authToken, "xoxc-abc")
    // Mauvais préfixe, jeton vide, cookie manquant : pas de session.
    XCTAssertNil(SlackLoginSession(authToken: "abc", cookieToken: "xoxd-def"))
    XCTAssertNil(SlackLoginSession(authToken: "xoxc-abc", cookieToken: "def"))
    XCTAssertNil(SlackLoginSession(authToken: "xoxc-", cookieToken: "xoxd-def"))
    XCTAssertNil(SlackLoginSession(authToken: nil, cookieToken: "xoxd-def"))
  }

  func testSessionFromPastedObject() {
    let session = SlackLoginSession(values: ["auth_token": "xoxc-a", "cookie_token": "xoxd-b", "extra": "ignoré"])
    XCTAssertEqual(session?.authToken, "xoxc-a")
    XCTAssertEqual(session?.cookieToken, "xoxd-b")
  }

  /// Le collage : l'objet JSON, ou un cURL copié de l'onglet Réseau — le jeton
  /// dans le corps, le cookie `d` encodé pour l'URL dans l'en-tête.
  func testSessionFromPastedCurl() {
    let curl = """
      curl 'https://acme.slack.com/api/client.boot' \\
        -H 'cookie: b=abc; d=xoxd-ab%2Fcd%2Bef%3D%3D; d-s=1756' \\
        --data-raw 'token=xoxc-1234-5678-abcdef&version=5'
      """
    let session = SlackLoginSession(pasted: curl)
    XCTAssertEqual(session?.authToken, "xoxc-1234-5678-abcdef")
    XCTAssertEqual(session?.cookieToken, "xoxd-ab/cd+ef==")
    XCTAssertEqual(SlackLoginSession(pasted: " {\"auth_token\":\"xoxc-a\",\"cookie_token\":\"xoxd-b\"} ")?.cookieToken, "xoxd-b")
    XCTAssertNil(SlackLoginSession(pasted: "curl https://slack.com -H 'cookie: d=xoxd-abc'"), "sans jeton, pas de session")
  }

  // MARK: - L'API de provisioning

  /// L'adresse du pont : le homeserver, port du pont, sans chemin.
  func testProvisioningURLKeepsHostAndSwapsPort() {
    XCTAssertEqual(MessageNetwork.slack.bridge?.provisioningPort, 29335)
    XCTAssertNil(MessageNetwork.iMessage.bridge?.provisioningPort, "iMessage n’a pas de pont")
    let url = MatrixBridgeService.provisioningURL(homeserver: URL(string: "http://100.64.0.7:8008/")!, port: 29335)
    XCTAssertEqual(url?.absoluteString, "http://100.64.0.7:29335")
  }

  /// L'étape captcha, telle que bridgev2 la sérialise : une étape « cookies »
  /// avec la page, le script (qui embarque la clé du site), et le champ
  /// `captcha_token` que le script rend.
  func testDecodesTheCaptchaStep() throws {
    let json = """
      {"login_id":"d2abc","type":"cookies","step_id":"fi.mau.slack.login.email_captcha",
       "instructions":"Slack requires a CAPTCHA before it can email the confirmation code.",
       "cookies":{"url":"https://slack.com/signin","extract_js":"(config => { return 1 })({\\"siteKey\\":\\"6Le\\"})",
         "fields":[{"id":"captcha_token","required":true,"sources":[{"type":"special","name":"captcha_token"}]}]}}
      """
    let step = try BridgeLoginProcessStep.decode(Data(json.utf8))
    XCTAssertEqual(step.loginID, "d2abc")
    XCTAssertEqual(step.type, .cookies)
    XCTAssertEqual(step.stepID, "fi.mau.slack.login.email_captcha")
    XCTAssertEqual(step.cookies?.url, "https://slack.com/signin")
    XCTAssertTrue(step.cookies?.extractJS?.contains("siteKey") == true)
    XCTAssertEqual(step.cookies?.requiredFieldIDs, ["captcha_token"])
    XCTAssertTrue(step.cookies?.cookieBackedFields.isEmpty == true, "le captcha ne se lit dans aucun cookie")
  }

  /// L'étape `token` : l'`auth_token` vient du script, le `cookie_token` du cookie `d`.
  func testDecodesTheTokenStepWithACookieSource() throws {
    let json = """
      {"login_id":"x","type":"cookies","step_id":"fi.mau.slack.login.enter_auth_token","instructions":"…",
       "cookies":{"url":"https://slack.com/signin","extract_js":"new Promise(r => r({auth_token: 'xoxc-a'}))",
         "fields":[
           {"id":"auth_token","required":true,"sources":[{"type":"special","name":"fi.mau.slack.auth_token"}],"pattern":"^xoxc-.+$"},
           {"id":"cookie_token","required":true,"sources":[{"type":"cookie","name":"d","cookie_domain":"slack.com"}]}]}}
      """
    let step = try BridgeLoginProcessStep.decode(Data(json.utf8))
    let backed = try XCTUnwrap(step.cookies?.cookieBackedFields.first)
    XCTAssertEqual(backed.id, "cookie_token")
    XCTAssertEqual(backed.cookieName, "d")
    XCTAssertEqual(backed.domain, "slack.com")
    XCTAssertEqual(step.cookies?.requiredFieldIDs, ["auth_token", "cookie_token"])
  }

  /// Les saisies : l'e-mail en clair, le code masqué, l'espace de travail en
  /// liste ; et la fin.
  func testDecodesInputAndCompleteSteps() throws {
    let email = try BridgeLoginProcessStep.decode(Data("""
      {"login_id":"x","type":"user_input","step_id":"fi.mau.slack.login.enter_email","instructions":"Enter the email address associated with your Slack account.",
       "user_input":{"fields":[{"type":"email","id":"email","name":"Email","description":"","pattern":"^[^@\\\\s]+@[^@\\\\s]+\\\\.[^@\\\\s]+$"}]}}
      """.utf8))
    XCTAssertEqual(email.firstInputField?.id, "email")
    XCTAssertFalse(email.firstInputField?.isSecret ?? true)

    let code = try BridgeLoginProcessStep.decode(Data("""
      {"login_id":"x","type":"user_input","step_id":"fi.mau.slack.login.enter_email_code","instructions":"Slack emailed you a confirmation code.",
       "user_input":{"fields":[{"type":"2fa_code","id":"code","name":"Confirmation code","description":"Six-character code from Slack"}]}}
      """.utf8))
    XCTAssertTrue(code.firstInputField?.isSecret ?? false)

    let workspace = try BridgeLoginProcessStep.decode(Data("""
      {"login_id":"x","type":"user_input","step_id":"fi.mau.slack.login.select_workspace","instructions":"Choose the Slack workspace to connect.",
       "user_input":{"fields":[{"type":"select","id":"workspace","name":"Workspace","description":"","options":["Acme (T0123)","Beta (T0456)"]}]}}
      """.utf8))
    XCTAssertEqual(workspace.firstInputField?.options, ["Acme (T0123)", "Beta (T0456)"])

    let done = try BridgeLoginProcessStep.decode(Data("""
      {"login_id":"x","type":"complete","step_id":"fi.mau.slack.login.complete","instructions":"Successfully logged into Acme as meffysto@acme.com",
       "complete":{"user_login_id":"T0123-U0456"}}
      """.utf8))
    XCTAssertEqual(done.type, .complete)
    XCTAssertEqual(done.complete?.userLoginID, "T0123-U0456")
  }

  /// Le pont parle anglais : on traduit par l'étape, par la phrase, et on garde
  /// l'anglais qu'on ne connaît pas — sous le français de l'étape.
  func testFrenchInstructions() throws {
    let captcha = try BridgeLoginProcessStep.decode(Data("""
      {"login_id":"x","type":"cookies","step_id":"fi.mau.slack.login.email_captcha",
       "instructions":"Slack requires a CAPTCHA before it can email the confirmation code. Complete the embedded challenge to continue.",
       "cookies":{"url":"https://slack.com/signin","fields":[]}}
      """.utf8))
    XCTAssertEqual(SlackLoginFrench.instructions(for: captcha), "Slack demande une vérification avant d'envoyer le code : passe-la ci-dessous.")

    let unknown = try BridgeLoginProcessStep.decode(Data("""
      {"login_id":"x","type":"user_input","step_id":"fi.mau.slack.login.select_workspace",
       "instructions":"Could not sign in to Acme: Slack did not complete the workspace login","user_input":{"fields":[]}}
      """.utf8))
    XCTAssertEqual(
      SlackLoginFrench.instructions(for: unknown),
      "Choisis l'espace de travail à connecter.\nCould not sign in to Acme: Slack did not complete the workspace login"
    )

    let done = try BridgeLoginProcessStep.decode(Data("""
      {"login_id":"x","type":"complete","step_id":"fi.mau.slack.login.complete","instructions":"Successfully logged into Acme Corp as meffysto@acme.com"}
      """.utf8))
    XCTAssertEqual(SlackLoginFrench.instructions(for: done), "Connecté à Acme Corp en tant que meffysto@acme.com.")

    let js = "heading.textContent = 'Complete the Slack verification'\nscript.src = 'https://www.google.com/recaptcha/api.js?render=explicit&onload=x'"
    let fr = SlackLoginFrench.localizedExtractJS(js)
    XCTAssertTrue(fr.contains("'Passe la vérification de Slack'"))
    XCTAssertTrue(fr.contains("api.js?hl=fr&render=explicit"))
    XCTAssertEqual(SlackLoginFrench.localizedExtractJS("new Promise(r => r())"), "new Promise(r => r())")
  }

  /// `whoami` : la liste des comptes, avec le nom du profil, un second
  /// identifiant, et l'état en français.
  func testDecodesWhoamiAccounts() throws {
    let json = """
      {"network":{"displayname":"Slack"},"login_flows":[],"logins":[
        {"id":"T0123-U0456","name":"Acme - moi@acme.com","profile":{"email":"moi@acme.com","name":"meffysto"},
         "state":{"state_event":"CONNECTED","timestamp":1756500000}},
        {"id":"T0789-U0456","name":"Beta - moi@acme.com","profile":{},
         "state":{"state_event":"BAD_CREDENTIALS","message":"token revoked"}}]}
      """
    let accounts = try BridgeAccount.decodeWhoami(Data(json.utf8))
    XCTAssertEqual(accounts.map(\.id), ["T0123-U0456", "T0789-U0456"])
    XCTAssertEqual(accounts[0].labelFR, "meffysto · moi@acme.com")
    XCTAssertTrue(accounts[0].isConnected)
    XCTAssertEqual(accounts[0].stateFR, "Connecté")
    XCTAssertEqual(accounts[1].labelFR, "Beta - moi@acme.com")
    XCTAssertFalse(accounts[1].isConnected)
    XCTAssertEqual(accounts[1].stateFR, "Session expirée : à reconnecter")
    XCTAssertEqual(try BridgeAccount.decodeWhoami(Data(#"{"logins":[]}"#.utf8)), [])
  }

  func testEveryBridgeHasAProvisioningPortAndAnAccountsHint() {
    for network in MessageNetwork.matrixBridged {
      XCTAssertNotNil(network.bridge?.provisioningPort, "\(network) sans port de provisioning")
      XCTAssertFalse(network.bridge?.accountsHintFR.isEmpty ?? true)
    }
    XCTAssertEqual(MessageNetwork.whatsapp.bridge?.provisioningPort, 29318)
    XCTAssertEqual(MessageNetwork.slack.bridge?.provisionedLoginFlowID, "email")
    XCTAssertNil(MessageNetwork.whatsapp.bridge?.provisionedLoginFlowID, "WhatsApp garde le QR par le chat")
  }

  func testSlackHasNoPureCookieProfile() {
    // Slack n'est pas un pur jeu de cookies : pas de Profile, donc la récolte par
    // cookies seuls et l'import navigateur l'ignorent.
    XCTAssertNil(BridgeSessionCookies.Profile.of(.slack))
  }

  /// L'invite « coller une session » de Slack diffère de celle de Meta/X, mais la
  /// forme courte les couvre toutes.
  func testSlackSessionPromptIsRecognisedAsAwaitingCookies() {
    XCTAssertEqual(
      MatrixBridgeService.loginStep(
        inBotMessage: "Enter a JSON object with your auth token and cookie token, or a cURL command copied from browser devtools."
      ),
      .awaitingCookies("Enter a JSON object with your auth token and cookie token, or a cURL command copied from browser devtools.")
    )
    // Le succès de Slack : « Successfully logged into <team> as <user> ».
    guard case .success = MatrixBridgeService.loginStep(inBotMessage: "Successfully logged into Acme as meffysto") else {
      return XCTFail("« Successfully logged into … » doit valoir un succès")
    }
  }

  /// Le flow e-mail natif : le bot demande, on rend une saisie ; un champ « code »
  /// est masqué ; « Options: » devient une liste de choix ; un captcha bascule en échec.
  func testSlackEmailFlowSteps() {
    guard case .awaitingInput(_, let secret1, let opts1) =
      MatrixBridgeService.slackInputStep(inBotMessage: "Please enter your Email\nThe email address associated with your Slack account.")
    else { return XCTFail("l'e-mail attend une saisie") }
    XCTAssertFalse(secret1)
    XCTAssertTrue(opts1.isEmpty)

    guard case .awaitingInput(_, let secret2, _) =
      MatrixBridgeService.slackInputStep(inBotMessage: "Please enter your Confirmation code")
    else { return XCTFail("le code attend une saisie") }
    XCTAssertTrue(secret2, "un code doit être masqué")

    guard case .awaitingInput(_, _, let opts3) =
      MatrixBridgeService.slackInputStep(inBotMessage: "Please enter your Workspace\nOptions: `T0BH2AAK1B9`, `T0456`")
    else { return XCTFail("l'espace de travail attend une saisie") }
    XCTAssertEqual(opts3, ["T0BH2AAK1B9", "T0456"])

    guard case .failure = MatrixBridgeService.slackInputStep(inBotMessage: "Slack requires a CAPTCHA before it can email the confirmation code.")
    else { return XCTFail("un captcha bascule en échec") }

    XCTAssertNil(MatrixBridgeService.slackInputStep(inBotMessage: "Some unrelated chatter"))
  }
}
