import CorrespondanceMatrixClient
import XCTest
@testable import CorrespondanceAgentKit

final class AgentConfigTests: XCTestCase {
  func testBotUserIDFollowsOwnersServer() {
    let config = AgentConfig(homeserver: URL(string: "http://100.64.0.1:8008")!, user: "cc", password: "x", owners: ["@meffysto:correspondance.local"])
    XCTAssertEqual(config.botUserID, "@cc:correspondance.local")
    var full = config
    full.user = "@bot:ailleurs.tld"
    XCTAssertEqual(full.botUserID, "@bot:ailleurs.tld")
  }

  func testRoundTripAndDefaults() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let url = dir.appending(path: "config.json")
    try AgentConfig.example().write(to: url)
    let loaded = try AgentConfig.load(from: url)
    XCTAssertEqual(loaded, AgentConfig.example())
    XCTAssertEqual(loaded.trigger, "@cc")
    XCTAssertEqual(loaded.defaultMode, .draft)
    XCTAssertEqual(loaded.hourlyCap, 30)
    // Le défaut est le palier plein : un agent invité par son propriétaire a
    // ses outils, et c'est le dossier de la room qui borne le risque.
    XCTAssertEqual(loaded.claude.allowedTools, AgentConfig.Presets.executer)
    XCTAssertEqual(loaded.claude.permissionMode, "bypassPermissions")
  }

  /// Les paliers sont versionnés : l'app en règle un par agent, elle
  /// n'assemble pas une liste d'outils à la main.
  func testLesPaliersDOutilsSeNommentEtSeRetrouvent() {
    XCTAssertEqual(AgentConfig.Presets.named("lire"), AgentConfig.Presets.lire)
    XCTAssertEqual(AgentConfig.Presets.named("écrire"), AgentConfig.Presets.ecrire)
    XCTAssertEqual(AgentConfig.Presets.named("plein"), AgentConfig.Presets.executer)
    XCTAssertNil(AgentConfig.Presets.named("inconnu"))

    XCTAssertEqual(AgentConfig.Presets.name(of: AgentConfig.Presets.lire), "lire")
    XCTAssertEqual(AgentConfig.Presets.name(of: AgentConfig.Presets.executer), "exécuter")
    XCTAssertEqual(AgentConfig.Presets.name(of: ["Read", "Bash(git *)"]), "sur mesure")
    // Écrire contient lire : un palier n'enlève jamais ce que le précédent donnait.
    XCTAssertTrue(Set(AgentConfig.Presets.lire).isSubset(of: Set(AgentConfig.Presets.ecrire)))
  }

  /// Une config d'hier, avec sa liste blanche et son moteur `claude`, doit
  /// continuer de marcher telle quelle — le NUC tourne dessus.
  func testUneConfigDHierResteLisible() throws {
    let json = """
      {"homeserver":"http://relais:8008","user":"cc","password":"p","owners":["@g:s"],
       "backend":"claude","claude":{"allowedTools":["Read","Grep"],"permission":{"enabled":true}}}
      """
    let config = try JSONDecoder().decode(AgentConfig.self, from: Data(json.utf8))
    XCTAssertEqual(config.backend, .claude)
    XCTAssertEqual(config.claude.allowedTools, ["Read", "Grep"])
    XCTAssertTrue(config.claude.permission.enabled)
    XCTAssertEqual(config.acp.command, "claude-code-acp", "le moteur ACP a ses défauts sans être écrit")
  }

  func testLeMoteurACPSeChoisitDansLaConfig() throws {
    let json = """
      {"homeserver":"http://relais:8008","user":"cc","password":"p","owners":["@g:s"],
       "backend":"acp","acp":{"command":"codex-acp","permissionModes":["dontAsk"]}}
      """
    let config = try JSONDecoder().decode(AgentConfig.self, from: Data(json.utf8))
    XCTAssertEqual(config.backend, .acp)
    XCTAssertEqual(config.acp.command, "codex-acp")
    XCTAssertEqual(config.acp.resolvedMode(available: ["default", "dontAsk"]), "dontAsk")
  }

  func testMinimalJSONGetsDefaults() throws {
    let json = """
      {"homeserver":"http://relais:8008","user":"cc","password":"p","owners":["@g:s"]}
      """
    let config = try JSONDecoder().decode(AgentConfig.self, from: Data(json.utf8))
    XCTAssertEqual(config.trigger, "@cc")
    XCTAssertEqual(config.rooms, [:])
    XCTAssertEqual(config.claude.timeoutSeconds, 300)
  }

  func testStatePersistsWithRestrictedPermissions() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "state.json")
    var state = AgentState()
    state.nextBatch = "s_1"
    state.claudeSessions["!r"] = "sess"
    state.credentials = MatrixCredentials(homeserver: URL(string: "http://relais:8008")!, userID: "@cc:s", accessToken: "tok")
    try state.write(to: url)
    XCTAssertEqual(AgentState.load(from: url), state)
    let perms = try FileManager.default.attributesOfItem(atPath: url.path())[.posixPermissions] as? Int
    XCTAssertEqual(perms, 0o600)
    XCTAssertEqual(AgentState.load(from: url.appending(path: "absent")), AgentState())
  }

  func testProposalContent() {
    let content = AgentEvents.proposal(text: "Voilà.", agent: "cc", inReplyTo: "$e1")
    XCTAssertEqual(content.string(at: "body"), "Voilà.")
    XCTAssertEqual(content.string(at: "agent"), "cc")
    XCTAssertEqual(content.string(at: "m.relates_to.m.in_reply_to.event_id"), "$e1")
  }
}
