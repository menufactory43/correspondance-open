import XCTest
@testable import CorrespondanceAgentKit

final class ClaudeOutputTests: XCTestCase {
  func testParsesSingleResultObject() throws {
    let json = """
      {"type":"result","subtype":"success","is_error":false,"result":"  Bonjour.  ","session_id":"abc-123","total_cost_usd":0.01}
      """
    let turn = try ClaudeOutput.parse(Data(json.utf8))
    XCTAssertEqual(turn, AgentTurn(text: "Bonjour.", sessionID: "abc-123", isError: false))
  }

  func testParsesStreamAndKeepsLastResult() throws {
    let stream = """
      {"type":"system","subtype":"init","session_id":"s1"}
      {"type":"assistant","message":{}}
      {"type":"result","subtype":"success","is_error":false,"result":"Fini.","session_id":"s1"}
      """
    XCTAssertEqual(try ClaudeOutput.parse(Data(stream.utf8)).text, "Fini.")
  }

  func testErrorSubtypeWithoutResultGetsAMessage() throws {
    let json = """
      {"type":"result","subtype":"error_max_turns","is_error":true,"result":"","session_id":"s2"}
      """
    let turn = try ClaudeOutput.parse(Data(json.utf8))
    XCTAssertTrue(turn.isError)
    XCTAssertEqual(turn.text, "Claude s'est arrêté : error max turns.")
  }

  func testGarbageThrows() {
    XCTAssertThrowsError(try ClaudeOutput.parse(Data("pas du json".utf8)))
  }

  func testArgumentsBuild() {
    var settings = AgentConfig.ClaudeSettings()
    settings.allowedTools = ["Read", "Bash(git *)"]
    settings.model = "claude-sonnet-5"
    settings.systemPrompt = "Tu es cc."
    XCTAssertEqual(
      ClaudeCodeBackend.arguments(settings: settings, sessionID: "s9"),
      ["-p", "--output-format", "json", "--resume", "s9", "--allowedTools", "Read,Bash(git *)", "--permission-mode", "bypassPermissions", "--model", "claude-sonnet-5", "--append-system-prompt", "Tu es cc."]
    )
    settings.allowedTools = []
    settings.model = nil
    settings.systemPrompt = ""
    // Sans liste blanche, il reste le régime — et il est dit, pas subi.
    XCTAssertEqual(
      ClaudeCodeBackend.arguments(settings: settings, sessionID: nil),
      ["-p", "--output-format", "json", "--permission-mode", "bypassPermissions"]
    )
  }

  /// Le régime se pose explicitement : un défaut de CLI change de version en
  /// version, et « pleine permission » doit être écrit dans la ligne de commande.
  func testLeRegimeEstToujoursDitALaCLI() {
    var settings = AgentConfig.ClaudeSettings()
    XCTAssertEqual(settings.permissionMode, "bypassPermissions")
    XCTAssertTrue(ClaudeCodeBackend.arguments(settings: settings, sessionID: nil).contains("--permission-mode"))
    // Sauf si on le vide exprès : on rend alors la main au moteur.
    settings.permissionMode = ""
    XCTAssertFalse(ClaudeCodeBackend.arguments(settings: settings, sessionID: nil).contains("--permission-mode"))
  }
}
