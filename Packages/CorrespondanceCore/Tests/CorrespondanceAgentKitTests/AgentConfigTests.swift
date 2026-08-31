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
    XCTAssertEqual(loaded.claude.allowedTools, ["Read", "Grep", "Glob"])
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
