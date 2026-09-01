import CorrespondanceAgentKit
import CorrespondanceCore
import CorrespondanceMatrixClient
import Foundation

// correspondance-mcp — l'inbox comme outil pour un agent du dehors.
//
// Un serveur MCP en stdio : Claude Desktop, Zed ou un agent sur un serveur le
// lancent, et travaillent sur la file sous les règles de la maison.
//
//   correspondance-mcp                 sert (stdio)
//   correspondance-mcp --tools         liste les outils et leur régime
//   correspondance-mcp --doctor        dit s'il sait joindre le Relais
//
// La session Matrix vient du même fichier d'amorce que l'agent
// (`~/.correspondance-agent/config.json`) ou de `CORRESPONDANCE_MCP_CONFIG`.
// Aucun nouveau secret, aucune nouvelle porte ouverte.
//
// Ce qui est permis se décide dans `MCPInbox` (testé côté AgentKit) ; ce que
// les outils font, dans `MCPInboxTools` (testé contre un faux Relais). Ici on
// ne fait que brancher. Le défaut : on propose des brouillons, on n'envoie pas.
@main
struct MCPCommand {
  static func main() async {
    let arguments = CommandLine.arguments

    if arguments.contains("--tools") {
      for outil in MCPInbox.tools {
        let nom = outil.name.padding(toLength: 20, withPad: " ", startingAt: 0)
        print("\(nom) \(outil.regime.rawValue)  \(outil.descriptionFR)")
      }
      return
    }

    let allowlist = Set(
      (ProcessInfo.processInfo.environment["CORRESPONDANCE_MCP_SEND"] ?? "")
        .split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    )

    guard let config = loadConfig() else {
      if arguments.contains("--doctor") {
        print("✗ amorce introuvable — lance l'agent une fois, ou pointe CORRESPONDANCE_MCP_CONFIG")
        exit(1)
      }
      await MCPInboxServer(relay: nil, allowlist: allowlist, agent: "cc").serve()
      return
    }

    let client = MatrixClient(credentials: nil)
    let identite: String
    do {
      let credentials = try await client.login(
        homeserver: config.homeserver, user: config.user, password: config.password
      )
      identite = credentials.userID
    } catch {
      if arguments.contains("--doctor") {
        print("✗ le Relais a refusé la session : \(error.localizedDescription)")
        exit(1)
      }
      await MCPInboxServer(relay: nil, allowlist: allowlist, agent: config.user).serve()
      return
    }

    let relais = MatrixInboxRelay(client: client, selfUserID: identite)
    if arguments.contains("--doctor") {
      let salons = (try? await relais.joinedRooms().count) ?? 0
      print("✓ connecté comme \(identite) — \(salons) conversation(s)")
      print(allowlist.isEmpty
        ? "  envoi : aucune conversation autorisée (on propose des brouillons)"
        : "  envoi autorisé dans : \(allowlist.sorted().joined(separator: ", "))")
      return
    }
    await MCPInboxServer(relay: relais, allowlist: allowlist, agent: config.user).serve()
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
  let relay: (any InboxRelay)?
  let allowlist: Set<String>
  let agent: String

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

  /// Le branchement au Relais. Sans session, chaque outil dit franchement ce
  /// qui manque — jamais une réponse inventée.
  private func run(tool: String, arguments: [String: Any]) async -> (text: String, isError: Bool) {
    guard let relay else {
      return ("Pas de session sur le Relais : lance l'agent une fois, ou pointe "
        + "CORRESPONDANCE_MCP_CONFIG sur son config.json.", true)
    }
    let outils = MCPInboxTools(relay: relay, agent: agent)
    let conversation = arguments["conversation"] as? String
    do {
      switch tool {
      case "list_queue":
        return (try await outils.listQueue(), false)
      case "read_conversation":
        guard let conversation else { return ("Il manque la conversation à lire.", true) }
        let limite = (arguments["limit"] as? Int) ?? 20
        return (try await outils.readConversation(conversation, limit: min(limite, 100)), false)
      case "search":
        guard let query = arguments["query"] as? String else { return ("Il manque ce qu'on cherche.", true) }
        return (try await outils.search(query), false)
      case "archive":
        guard let conversation else { return ("Il manque la conversation à archiver.", true) }
        return (try await outils.archive(conversation, on: (arguments["on"] as? Bool) ?? true), false)
      case "remind":
        guard let conversation else { return ("Il manque la conversation.", true) }
        guard let quand = date(in: arguments) else {
          return ("Il manque l'heure du rappel (`at`, en ISO 8601 ou en minutes avec `in_minutes`).", true)
        }
        return (try await outils.remind(conversation, at: quand), false)
      case "draft_reply":
        guard let conversation else { return ("Il manque la conversation.", true) }
        guard let text = arguments["text"] as? String else { return ("Il manque le texte.", true) }
        return (try await outils.draftReply(conversation, text: text), false)
      case "send_message":
        guard let conversation else { return ("Il manque la conversation.", true) }
        guard let text = arguments["text"] as? String else { return ("Il manque le texte.", true) }
        return (try await outils.sendMessage(conversation, text: text), false)
      default:
        return ("\(tool) : outil inconnu.", true)
      }
    } catch {
      return ("Le Relais n'a pas répondu : \(error.localizedDescription)", true)
    }
  }

  /// L'heure d'un rappel : une date ISO 8601, ou un nombre de minutes.
  private func date(in arguments: [String: Any]) -> Date? {
    if let minutes = arguments["in_minutes"] as? Int {
      return Date().addingTimeInterval(TimeInterval(minutes * 60))
    }
    guard let texte = arguments["at"] as? String else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: texte) ?? ISO8601DateFormatter().date(from: texte)
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
    var requis: [String] = []
    // Tout sauf la file et la recherche travaille sur une conversation donnée.
    // Une propriété de trop est du bruit dans une description que le modèle lit.
    if tool.name != "list_queue", tool.name != "search" {
      properties["conversation"] = [
        "type": "string",
        "description": "L'identifiant de la conversation, tel que list_queue le rend (`!salon:serveur`).",
      ]
      requis.append("conversation")
    }
    if tool.name == "draft_reply" || tool.name == "send_message" {
      properties["text"] = ["type": "string", "description": "Le texte du message."]
      requis.append("text")
    }
    if tool.name == "search" {
      properties["query"] = ["type": "string", "description": "Ce qu'on cherche."]
      requis.append("query")
    }
    if tool.name == "read_conversation" {
      properties["limit"] = ["type": "integer", "description": "Combien de messages (20 par défaut)."]
    }
    if tool.name == "remind" {
      properties["in_minutes"] = ["type": "integer", "description": "Dans combien de minutes."]
      properties["at"] = ["type": "string", "description": "Ou une date ISO 8601."]
    }
    if tool.name == "archive" {
      properties["on"] = ["type": "boolean", "description": "false pour remettre dans la file."]
    }
    return [
      "name": tool.name,
      "description": tool.descriptionFR,
      "inputSchema": ["type": "object", "properties": properties, "required": requis],
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
