import Foundation

/// Approuver un outil depuis la conversation : `claude` demande via
/// `--permission-prompt-tool`, l'agent pose la question dans la room, et un 👍
/// d'un propriétaire répond.
///
/// Deux processus se parlent par fichiers, dans un dossier « spool » créé pour
/// le tour : le serveur MCP (sous-commande `permission-tool`, enfant de
/// `claude`) écrit `<id>.request.json` et attend `<id>.response.json`, que
/// l'agent écrit quand la réaction arrive. Pas de socket, pas de port : deux
/// processus du même utilisateur, un dossier `0700`.
public enum Permission {

  /// Ce que `claude` veut faire — écrit par le serveur MCP, lu par l'agent.
  public struct Request: Codable, Sendable, Equatable {
    public var id: String
    public var toolName: String
    /// L'entrée de l'outil, JSON brut : on la rend telle quelle dans
    /// `updatedInput` si c'est oui, on n'a pas besoin de la comprendre.
    public var inputJSON: String

    public init(id: String, toolName: String, inputJSON: String) {
      self.id = id
      self.toolName = toolName
      self.inputJSON = inputJSON
    }

    /// Ce que la room doit lire : l'outil, et l'essentiel de son entrée.
    /// Pour `Bash` c'est la commande ; sinon le JSON, tronqué.
    public var summary: String {
      if let data = inputJSON.data(using: .utf8),
         let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        if let command = object["command"] as? String { return "`\(command)`" }
        if let path = (object["file_path"] ?? object["path"]) as? String { return path }
      }
      let compact = inputJSON.replacingOccurrences(of: "\n", with: " ")
      return compact.count > 200 ? String(compact.prefix(200)) + "…" : compact
    }
  }

  /// La décision — écrite par l'agent, lue par le serveur MCP.
  public struct Response: Codable, Sendable, Equatable {
    public var allow: Bool
    public var message: String?

    public init(allow: Bool, message: String? = nil) {
      self.allow = allow
      self.message = message
    }
  }

  public static func requestURL(in spool: URL, id: String) -> URL {
    spool.appending(path: "\(id).request.json")
  }
  public static func responseURL(in spool: URL, id: String) -> URL {
    spool.appending(path: "\(id).response.json")
  }

  /// Les demandes en attente dans le spool, dans l'ordre d'arrivée.
  public static func pendingRequests(in spool: URL) -> [Request] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: spool.path())) ?? []
    return names.filter { $0.hasSuffix(".request.json") }.sorted().compactMap { name in
      guard let data = try? Data(contentsOf: spool.appending(path: name)) else { return nil }
      return try? JSONDecoder().decode(Request.self, from: data)
    }
  }

  public static func write(_ response: Response, in spool: URL, id: String) throws {
    try JSONEncoder().encode(response).write(to: responseURL(in: spool, id: id), options: .atomic)
  }
}

/// Le serveur MCP (stdio, JSON-RPC ligne à ligne) que `claude` lance via
/// `--mcp-config`. Un seul outil, `approve` : il écrit la demande dans le
/// spool et bloque jusqu'à la réponse — c'est tout son travail.
///
/// La logique est pure (une ligne entre, une ligne sort) : c'est elle que les
/// tests exercent ; la boucle stdin vit dans `serve()`.
public struct PermissionTool: Sendable {
  public var spool: URL
  public var timeoutSeconds: Int

  public init(spool: URL, timeoutSeconds: Int) {
    self.spool = spool
    self.timeoutSeconds = timeoutSeconds
  }

  /// Boucle stdio : bloquante, à appeler depuis la sous-commande et nulle part ailleurs.
  public func serve() {
    while let line = readLine(strippingNewline: true) {
      guard let reply = handle(line: line) else { continue }
      FileHandle.standardOutput.write(Data((reply + "\n").utf8))
    }
  }

  /// Une ligne JSON-RPC entre, la réponse sort (`nil` pour une notification).
  public func handle(line: String) -> String? {
    guard let data = line.data(using: .utf8),
          let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let method = message["method"] as? String
    else { return nil }
    let id = message["id"]
    guard id != nil else { return nil } // notification : rien à répondre

    switch method {
    case "initialize":
      let requested = (message["params"] as? [String: Any])?["protocolVersion"] as? String
      return encode(id: id!, result: [
        "protocolVersion": requested ?? "2024-11-05",
        "capabilities": ["tools": [String: Any]()],
        "serverInfo": ["name": "cc-permission", "version": "1.0.0"],
      ])
    case "ping":
      return encode(id: id!, result: [String: Any]())
    case "tools/list":
      return encode(id: id!, result: ["tools": [[
        "name": "approve",
        "description": "Demande au propriétaire, dans la conversation, la permission d'utiliser un outil.",
        "inputSchema": [
          "type": "object",
          "properties": [
            "tool_name": ["type": "string"],
            "input": ["type": "object"],
          ],
          "required": ["tool_name"],
        ],
      ]]])
    case "tools/call":
      let arguments = ((message["params"] as? [String: Any])?["arguments"] as? [String: Any]) ?? [:]
      let decision = decide(toolName: arguments["tool_name"] as? String ?? "?",
                            input: arguments["input"] as? [String: Any] ?? [:])
      return encode(id: id!, result: ["content": [["type": "text", "text": decision]]])
    default:
      return encode(id: id!, error: ["code": -32601, "message": "méthode inconnue : \(method)"])
    }
  }

  /// Écrit la demande, attend la décision, la met à la forme que
  /// `--permission-prompt-tool` exige : `{"behavior":"allow","updatedInput":…}`
  /// ou `{"behavior":"deny","message":"…"}`.
  func decide(toolName: String, input: [String: Any]) -> String {
    let id = UUID().uuidString
    let inputData = (try? JSONSerialization.data(withJSONObject: input)) ?? Data("{}".utf8)
    let inputJSON = String(data: inputData, encoding: .utf8) ?? "{}"
    let request = Permission.Request(id: id, toolName: toolName, inputJSON: inputJSON)
    defer {
      try? FileManager.default.removeItem(at: Permission.requestURL(in: spool, id: id))
      try? FileManager.default.removeItem(at: Permission.responseURL(in: spool, id: id))
    }
    do {
      try JSONEncoder().encode(request).write(to: Permission.requestURL(in: spool, id: id), options: .atomic)
    } catch {
      return deny("le spool est inaccessible : \(error.localizedDescription)")
    }

    let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
    let responseURL = Permission.responseURL(in: spool, id: id)
    while Date() < deadline {
      if let data = try? Data(contentsOf: responseURL),
         let response = try? JSONDecoder().decode(Permission.Response.self, from: data) {
        if response.allow {
          return "{\"behavior\":\"allow\",\"updatedInput\":\(inputJSON)}"
        }
        return deny(response.message ?? "refusé par le propriétaire")
      }
      Thread.sleep(forTimeInterval: 0.2)
    }
    return deny("personne n'a répondu dans la conversation (\(timeoutSeconds) s)")
  }

  private func deny(_ message: String) -> String {
    let payload: [String: Any] = ["behavior": "deny", "message": message]
    let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    return String(data: data, encoding: .utf8) ?? "{\"behavior\":\"deny\"}"
  }

  private func encode(id: Any, result: [String: Any]) -> String? {
    encode(["jsonrpc": "2.0", "id": id, "result": result])
  }
  private func encode(id: Any, error: [String: Any]) -> String? {
    encode(["jsonrpc": "2.0", "id": id, "error": error])
  }
  private func encode(_ object: [String: Any]) -> String? {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
    return String(data: data, encoding: .utf8)
  }
}
