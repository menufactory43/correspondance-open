import Foundation

/// Un tour d'agent : ce qu'il a répondu, et la session à reprendre la prochaine fois.
public struct AgentTurn: Sendable, Equatable {
  public var text: String
  public var sessionID: String?
  public var isError: Bool

  public init(text: String, sessionID: String?, isError: Bool = false) {
    self.text = text
    self.sessionID = sessionID
    self.isError = isError
  }
}

/// Ce qu'un moteur doit savoir faire. Claude Code aujourd'hui ; `codex exec` ou
/// `gemini` demain sur le même contrat — chacun sur son abonnement.
/// `permissionSpool` : le dossier où le moteur dépose ses demandes d'outils et
/// attend les décisions (cf. `Permission`). `nil` : hors liste blanche, refus.
public protocol AgentBackend: Sendable {
  func run(prompt: String, cwd: String?, sessionID: String?, permissionSpool: URL?) async throws -> AgentTurn
}

extension AgentBackend {
  public func run(prompt: String, cwd: String?, sessionID: String?) async throws -> AgentTurn {
    try await run(prompt: prompt, cwd: cwd, sessionID: sessionID, permissionSpool: nil)
  }
}

public enum AgentBackendError: Error, LocalizedError {
  case binaryNotFound
  case timedOut(seconds: Int)
  case exit(code: Int32, stderr: String)
  case unreadableOutput(String)

  public var errorDescription: String? {
    switch self {
    case .binaryNotFound: "l'exécutable `claude` est introuvable"
    case .timedOut(let s): "Claude n'a pas répondu en \(s) s"
    case .exit(let code, let stderr): "claude a quitté avec le code \(code)" + (stderr.isEmpty ? "" : " — \(stderr)")
    case .unreadableOutput(let detail): "sortie de claude illisible — \(detail)"
    }
  }
}

/// La sortie de `claude -p --output-format json`, réduite à ce qui nous sert.
public enum ClaudeOutput {
  public static func parse(_ data: Data) throws -> AgentTurn {
    // `--output-format json` rend un seul objet ; on tolère un flux d'objets
    // (une ligne par event) en gardant le dernier `type: result`.
    let objects = try jsonObjects(in: data)
    guard let result = objects.last(where: { ($0["type"] as? String) == "result" }) ?? objects.last else {
      throw AgentBackendError.unreadableOutput("aucun objet JSON")
    }
    let isError = (result["is_error"] as? Bool) ?? false
    let sessionID = result["session_id"] as? String
    var text = (result["result"] as? String) ?? ""
    if text.isEmpty, let subtype = result["subtype"] as? String, subtype != "success" {
      text = "Claude s'est arrêté : \(subtype.replacingOccurrences(of: "_", with: " "))."
    }
    return AgentTurn(text: text.trimmingCharacters(in: .whitespacesAndNewlines), sessionID: sessionID, isError: isError)
  }

  private static func jsonObjects(in data: Data) throws -> [[String: Any]] {
    if let single = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      return [single]
    }
    guard let text = String(data: data, encoding: .utf8) else {
      throw AgentBackendError.unreadableOutput("pas de l'UTF-8")
    }
    let objects = text.split(separator: "\n").compactMap { line -> [String: Any]? in
      guard let d = line.data(using: .utf8) else { return nil }
      return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }
    guard !objects.isEmpty else {
      throw AgentBackendError.unreadableOutput(String(text.prefix(200)))
    }
    return objects
  }
}

/// Lance le vrai `claude` — celui qui est loggé sur la machine, donc sur
/// l'abonnement de la machine. Jamais de clé API ici.
public struct ClaudeCodeBackend: AgentBackend {
  public var settings: AgentConfig.ClaudeSettings
  /// Le chemin absolu de `correspondance-agent` lui-même : c'est lui que
  /// `claude` relance en serveur MCP (`permission-tool`) quand un spool est fourni.
  public var selfBinary: String?

  public init(settings: AgentConfig.ClaudeSettings, selfBinary: String? = nil) {
    self.settings = settings
    self.selfBinary = selfBinary
  }

  /// Les arguments, sans le prompt (il passe par stdin : pas de limite de
  /// longueur, pas d'échappement).
  public static func arguments(
    settings: AgentConfig.ClaudeSettings,
    sessionID: String?,
    permission: (spool: String, selfBinary: String)? = nil
  ) -> [String] {
    var args = ["-p", "--output-format", "json"]
    if let sessionID { args += ["--resume", sessionID] }
    if !settings.allowedTools.isEmpty { args += ["--allowedTools", settings.allowedTools.joined(separator: ",")] }
    // Le régime se pose explicitement — un défaut de CLI peut changer de
    // version en version, et « pleine permission » doit être dit, pas espéré.
    if !settings.permissionMode.isEmpty { args += ["--permission-mode", settings.permissionMode] }
    if let model = settings.model { args += ["--model", model] }
    if !settings.systemPrompt.isEmpty { args += ["--append-system-prompt", settings.systemPrompt] }
    if let permission {
      // Un serveur MCP éphémère — nous-même, en sous-commande — et la consigne
      // de lui demander tout outil hors liste blanche au lieu de le refuser.
      let server: [String: Any] = [
        "command": permission.selfBinary,
        "args": ["permission-tool", permission.spool, String(settings.permission.timeoutSeconds)],
      ]
      let mcpConfig = ["mcpServers": ["cc-perm": server]]
      if let data = try? JSONSerialization.data(withJSONObject: mcpConfig),
         let json = String(data: data, encoding: .utf8) {
        args += ["--mcp-config", json, "--permission-prompt-tool", "mcp__cc-perm__approve"]
      }
    }
    return args
  }

  /// Le chemin absolu de l'exécutable courant — `claude` le lancera depuis un
  /// autre répertoire, un chemin relatif ne survivrait pas.
  public static func resolveSelfBinary() -> String? {
    let arg0 = CommandLine.arguments.first ?? ""
    let url: URL
    if arg0.hasPrefix("/") {
      url = URL(fileURLWithPath: arg0)
    } else if arg0.contains("/") {
      url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: arg0)
    } else {
      let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
      guard let dir = path.split(separator: ":").first(where: {
        FileManager.default.isExecutableFile(atPath: "\($0)/\(arg0)")
      }) else { return nil }
      url = URL(fileURLWithPath: "\(dir)/\(arg0)")
    }
    let resolved = url.resolvingSymlinksInPath().path()
    return FileManager.default.isExecutableFile(atPath: resolved) ? resolved : nil
  }

  public static func resolveBinary(_ configured: String?) -> String? {
    Subprocess.find("claude", configured: configured)
  }

  public func run(prompt: String, cwd: String?, sessionID: String?, permissionSpool: URL?) async throws -> AgentTurn {
    guard let binary = Self.resolveBinary(settings.binary) else { throw AgentBackendError.binaryNotFound }
    var permission: (spool: String, selfBinary: String)?
    var extraEnv: [String: String] = [:]
    var timeout = settings.timeoutSeconds
    if let permissionSpool, let selfBinary = selfBinary ?? Self.resolveSelfBinary() {
      permission = (spool: permissionSpool.path(), selfBinary: selfBinary)
      // Le temps d'un 👍 s'ajoute au tour : ni Claude (timeout d'appel MCP),
      // ni nous (timeout du processus) ne devons couper avant l'humain.
      extraEnv["MCP_TOOL_TIMEOUT"] = String((settings.permission.timeoutSeconds + 30) * 1000)
      timeout += settings.permission.timeoutSeconds
    }
    let args = Self.arguments(settings: settings, sessionID: sessionID, permission: permission)
    let workdir = cwd ?? settings.defaultCwd
    let deadline = timeout
    let env = extraEnv
    let output = try await Task.detached(priority: .userInitiated) {
      try Subprocess.run(binary: binary, arguments: args, stdin: prompt, cwd: workdir, timeoutSeconds: deadline, extraEnv: env)
    }.value
    return try ClaudeOutput.parse(output.stdout)
  }
}
