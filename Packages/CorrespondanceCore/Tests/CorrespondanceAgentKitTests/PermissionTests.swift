import XCTest
@testable import CorrespondanceAgentKit

/// Le chemin d'une permission, sans `claude` ni Matrix : le serveur MCP parle
/// JSON-RPC, le spool porte la demande, la décision revient à la bonne forme.
final class PermissionTests: XCTestCase {
  private var spool: URL!

  override func setUpWithError() throws {
    spool = FileManager.default.temporaryDirectory.appending(path: "perm-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: spool)
  }

  private func tool(timeout: Int = 1) -> PermissionTool {
    PermissionTool(spool: spool, timeoutSeconds: timeout)
  }

  private func json(_ line: String?) throws -> [String: Any] {
    let data = try XCTUnwrap(line).data(using: .utf8)!
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  // MARK: - JSON-RPC

  func testInitializeReprendLaVersionDuClient() throws {
    let reply = try json(tool().handle(line:
      #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#))
    let result = try XCTUnwrap(reply["result"] as? [String: Any])
    XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
    XCTAssertEqual(reply["id"] as? Int, 1)
  }

  func testLaListeExposeApprove() throws {
    let reply = try json(tool().handle(line: #"{"jsonrpc":"2.0","id":"a","method":"tools/list"}"#))
    let tools = try XCTUnwrap((reply["result"] as? [String: Any])?["tools"] as? [[String: Any]])
    XCTAssertEqual(tools.first?["name"] as? String, "approve")
    XCTAssertEqual(reply["id"] as? String, "a")
  }

  func testUneNotificationNeRepondRien() {
    XCTAssertNil(tool().handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
  }

  func testUneMethodeInconnueEstUneErreur() throws {
    let reply = try json(tool().handle(line: #"{"jsonrpc":"2.0","id":2,"method":"resources/list"}"#))
    XCTAssertNotNil(reply["error"])
  }

  // MARK: - Spool

  func testSansReponseCestUnRefus() throws {
    let reply = try json(tool(timeout: 0).handle(line:
      #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"approve","arguments":{"tool_name":"Bash","input":{"command":"rm -rf /"}}}}"#))
    let content = try XCTUnwrap((reply["result"] as? [String: Any])?["content"] as? [[String: Any]])
    let decision = try json(content.first?["text"] as? String)
    XCTAssertEqual(decision["behavior"] as? String, "deny")
  }

  func testUnOuiRendLEntreeIntacte() throws {
    // Un juge qui dit oui dès que la demande paraît — le rôle de l'agent.
    let judge = Thread {
      let deadline = Date().addingTimeInterval(5)
      while Date() < deadline {
        if let request = Permission.pendingRequests(in: self.spool).first {
          try? Permission.write(.init(allow: true), in: self.spool, id: request.id)
          return
        }
        Thread.sleep(forTimeInterval: 0.05)
      }
    }
    judge.start()
    let reply = try json(tool(timeout: 5).handle(line:
      #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"approve","arguments":{"tool_name":"Bash","input":{"command":"git status"}}}}"#))
    let content = try XCTUnwrap((reply["result"] as? [String: Any])?["content"] as? [[String: Any]])
    let decision = try json(content.first?["text"] as? String)
    XCTAssertEqual(decision["behavior"] as? String, "allow")
    let input = try XCTUnwrap(decision["updatedInput"] as? [String: Any])
    XCTAssertEqual(input["command"] as? String, "git status")
    // Le spool est rangé : ni demande ni réponse ne survivent à la décision.
    XCTAssertTrue(Permission.pendingRequests(in: spool).isEmpty)
  }

  func testUnNonPorteLeMessage() throws {
    let judge = Thread {
      let deadline = Date().addingTimeInterval(5)
      while Date() < deadline {
        if let request = Permission.pendingRequests(in: self.spool).first {
          try? Permission.write(.init(allow: false, message: "refusé par @meffysto"), in: self.spool, id: request.id)
          return
        }
        Thread.sleep(forTimeInterval: 0.05)
      }
    }
    judge.start()
    let reply = try json(tool(timeout: 5).handle(line:
      #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"approve","arguments":{"tool_name":"Write","input":{"file_path":"/tmp/x"}}}}"#))
    let content = try XCTUnwrap((reply["result"] as? [String: Any])?["content"] as? [[String: Any]])
    let decision = try json(content.first?["text"] as? String)
    XCTAssertEqual(decision["behavior"] as? String, "deny")
    XCTAssertEqual(decision["message"] as? String, "refusé par @meffysto")
  }

  // MARK: - Résumé

  func testLeResumeMontreLaCommande() {
    let request = Permission.Request(id: "1", toolName: "Bash", inputJSON: #"{"command":"git log --oneline"}"#)
    XCTAssertEqual(request.summary, "`git log --oneline`")
  }

  func testLeResumeMontreLeChemin() {
    let request = Permission.Request(id: "1", toolName: "Write", inputJSON: #"{"file_path":"/tmp/note.md","content":"…"}"#)
    XCTAssertEqual(request.summary, "/tmp/note.md")
  }

  func testLeResumeTronqueLeReste() {
    let long = #"{"query":"\#(String(repeating: "x", count: 300))"}"#
    let request = Permission.Request(id: "1", toolName: "WebSearch", inputJSON: long)
    XCTAssertTrue(request.summary.hasSuffix("…"))
    XCTAssertLessThanOrEqual(request.summary.count, 201)
  }

  // MARK: - Arguments de claude

  func testSansSpoolPasDeMCP() {
    let args = ClaudeCodeBackend.arguments(settings: .init(), sessionID: nil)
    XCTAssertFalse(args.contains("--permission-prompt-tool"))
    XCTAssertFalse(args.contains("--mcp-config"))
  }

  func testAvecSpoolClaudeApprendLOutil() throws {
    var settings = AgentConfig.ClaudeSettings()
    settings.permission.timeoutSeconds = 90
    let args = ClaudeCodeBackend.arguments(
      settings: settings, sessionID: nil,
      permission: (spool: "/tmp/spool", selfBinary: "/usr/local/bin/correspondance-agent"))
    let toolIndex = try XCTUnwrap(args.firstIndex(of: "--permission-prompt-tool"))
    XCTAssertEqual(args[toolIndex + 1], "mcp__cc-perm__approve")
    let configIndex = try XCTUnwrap(args.firstIndex(of: "--mcp-config"))
    let mcp = try json(args[configIndex + 1])
    let server = try XCTUnwrap((mcp["mcpServers"] as? [String: Any])?["cc-perm"] as? [String: Any])
    XCTAssertEqual(server["command"] as? String, "/usr/local/bin/correspondance-agent")
    XCTAssertEqual(server["args"] as? [String], ["permission-tool", "/tmp/spool", "90"])
  }

  // MARK: - Config

  func testLaPermissionEstFermeeParDefaut() throws {
    let config = try JSONDecoder().decode(
      AgentConfig.self,
      from: Data(#"{"homeserver":"http://x:8008","user":"cc","password":"p","owners":["@g:x"]}"#.utf8))
    XCTAssertFalse(config.claude.permission.enabled)
    XCTAssertEqual(config.claude.permission.timeoutSeconds, 120)
  }

  func testLaPermissionSeLitDansLaConfig() throws {
    let config = try JSONDecoder().decode(
      AgentConfig.self,
      from: Data(#"{"homeserver":"http://x:8008","user":"cc","password":"p","owners":["@g:x"],"claude":{"permission":{"enabled":true,"timeoutSeconds":60}}}"#.utf8))
    XCTAssertTrue(config.claude.permission.enabled)
    XCTAssertEqual(config.claude.permission.timeoutSeconds, 60)
  }
}
