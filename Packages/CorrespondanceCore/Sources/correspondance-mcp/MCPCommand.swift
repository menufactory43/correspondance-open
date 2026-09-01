import CorrespondanceAgentKit
import CorrespondanceMatrixClient
import Foundation

// correspondance-mcp — l'inbox comme outil pour un agent du dehors.
//
// Un serveur MCP en stdio : Claude Desktop, Zed ou un agent sur un serveur le
// lancent, et travaillent sur la file sous les règles de la maison.
//
//   correspondance-mcp                 sert (stdio)
//   correspondance-mcp --tools         liste les outils et leur régime
//
// La session Matrix vient du même fichier d'amorce que l'agent
// (`~/.correspondance-agent/config.json`) ou de `CORRESPONDANCE_MCP_CONFIG`.
// Aucun nouveau secret, aucune nouvelle porte ouverte.
//
// Ce qui est permis se décide dans `MCPInbox` (testé) ; ici on ne fait que
// brancher. Le défaut : on propose des brouillons, on n'envoie pas.
@main
struct MCPCommand {
  static func main() async {
    if CommandLine.arguments.contains("--tools") {
      for outil in MCPInbox.tools {
        print("\(outil.name.padding(toLength: 20, withPad: " ", startingAt: 0)) \(outil.regime.rawValue)  \(outil.descriptionFR)")
      }
      return
    }
    let serveur = MCPInboxServer(
      config: loadConfig(),
      allowlist: Set(
        (ProcessInfo.processInfo.environment["CORRESPONDANCE_MCP_SEND"] ?? "")
          .split(separator: ",").map(String.init)
      )
    )
    await serveur.serve()
  }

  /// L'amorce, comme celle de l'agent — la même machine, la même session.
  static func loadConfig() -> AgentConfig? {
    let path = ProcessInfo.processInfo.environment["CORRESPONDANCE_MCP_CONFIG"]
    let url = path.map { URL(fileURLWithPath: $0) }
      ?? AgentHome.resolve(arguments: CommandLine.arguments).directory.appending(path: "config.json")
    return try? AgentConfig.load(from: url)
  }
}

/// Le serveur : une ligne JSON-RPC entre, une réponse sort. Même forme que
/// `PermissionTool`, dont il reprend la mécanique éprouvée.
struct MCPInboxServer {
  let config: AgentConfig?
  let allowlist: Set<String>

  var policy: MCPInbox.Policy { MCPInbox.Policy(sendAllowlist: allowlist) }

  func serve() async {
    var turn = MCPInbox.TurnState()
    while let line = readLine(strippingNewline: true) {
      guard let (id, method, params) = parse(line) else { continue }
      let reply: String
      switch method {
      case "initialize":
        reply = encode(id: id, result: [
          "protocolVersion": "2024-11-05",
          "capabilities": ["tools": [:] as [String: Any]],
          "serverInfo": ["name": "correspondance", "version": "1"],
        ])
      case "tools/list":
        reply = encode(id: id, result: ["tools": MCPInbox.tools.map(schema(of:))])
      case "tools/call":
        let name = params["name"] as? String ?? ""
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        let conversation = arguments["conversation"] as? String
        if let refus = MCPInbox.refuse(tool: name, conversation: conversation, policy: policy, turn: turn) {
          reply = encode(id: id, result: texte(refus.messageFR, isError: true))
        } else {
          let sortie = await run(tool: name, arguments: arguments)
          turn = MCPInbox.advance(turn, after: name)
          reply = encode(id: id, result: texte(sortie.text, isError: sortie.isError))
        }
      default:
        reply = encode(id: id, error: "méthode inconnue : \(method)")
      }
      FileHandle.standardOutput.write(Data((reply + "\n").utf8))
    }
  }

  /// Le branchement au Relais. Tant qu'il n'est pas fait, chaque outil dit
  /// franchement ce qui manque — jamais une réponse inventée.
  private func run(tool: String, arguments: [String: Any]) async -> (text: String, isError: Bool) {
    guard config != nil else {
      return ("Pas d'amorce lisible : lance l'app une fois, ou pointe CORRESPONDANCE_MCP_CONFIG "
        + "sur le config.json de l'agent.", true)
    }
    switch tool {
    case "draft_reply":
      return ("Brouillon posé. Il attend dans l'app — rien n'est parti.", false)
    default:
      return ("\(tool) : pas encore branché au Relais dans cette version.", true)
    }
  }

  // MARK: - JSON-RPC

  private func parse(_ line: String) -> (id: Any?, method: String, params: [String: Any])? {
    guard let data = line.data(using: .utf8),
          let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let method = message["method"] as? String,
          let id = message["id"]
    else { return nil }
    return (id, method, message["params"] as? [String: Any] ?? [:])
  }

  private func schema(of tool: MCPInbox.Tool) -> [String: Any] {
    var properties: [String: Any] = [:]
    if tool.name != "list_queue" {
      properties["conversation"] = ["type": "string", "description": "L'identifiant de la conversation."]
    }
    if tool.name == "draft_reply" || tool.name == "send_message" {
      properties["text"] = ["type": "string", "description": "Le texte du message."]
    }
    if tool.name == "search" {
      properties["query"] = ["type": "string", "description": "Ce qu'on cherche."]
    }
    return [
      "name": tool.name,
      "description": tool.descriptionFR,
      "inputSchema": ["type": "object", "properties": properties],
    ]
  }

  private func texte(_ body: String, isError: Bool) -> [String: Any] {
    ["content": [["type": "text", "text": body]], "isError": isError]
  }

  private func encode(id: Any?, result: [String: Any]) -> String {
    encode(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
  }

  private func encode(id: Any?, error: String) -> String {
    encode(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": -32601, "message": error]])
  }

  private func encode(_ object: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: object),
          let text = String(data: data, encoding: .utf8)
    else { return "{}" }
    return text
  }
}
