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
public protocol AgentBackend: Sendable {
  func run(prompt: String, cwd: String?, sessionID: String?) async throws -> AgentTurn
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

  public init(settings: AgentConfig.ClaudeSettings) {
    self.settings = settings
  }

  /// Les arguments, sans le prompt (il passe par stdin : pas de limite de
  /// longueur, pas d'échappement).
  public static func arguments(settings: AgentConfig.ClaudeSettings, sessionID: String?) -> [String] {
    var args = ["-p", "--output-format", "json"]
    if let sessionID { args += ["--resume", sessionID] }
    if !settings.allowedTools.isEmpty { args += ["--allowedTools", settings.allowedTools.joined(separator: ",")] }
    if let model = settings.model { args += ["--model", model] }
    if !settings.systemPrompt.isEmpty { args += ["--append-system-prompt", settings.systemPrompt] }
    return args
  }

  public static func resolveBinary(_ configured: String?) -> String? {
    if let configured, FileManager.default.isExecutableFile(atPath: configured) { return configured }
    let home = FileManager.default.homeDirectoryForCurrentUser.path()
    let candidates = [
      "\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "/usr/bin/claude",
    ]
    if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return found }
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    for dir in path.split(separator: ":") {
      let candidate = "\(dir)/claude"
      if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return nil
  }

  public func run(prompt: String, cwd: String?, sessionID: String?) async throws -> AgentTurn {
    guard let binary = Self.resolveBinary(settings.binary) else { throw AgentBackendError.binaryNotFound }
    let args = Self.arguments(settings: settings, sessionID: sessionID)
    let workdir = cwd ?? settings.defaultCwd
    let timeout = settings.timeoutSeconds
    let data = try await Task.detached(priority: .userInitiated) {
      try Self.runBlocking(binary: binary, arguments: args, stdin: prompt, cwd: workdir, timeoutSeconds: timeout)
    }.value
    return try ClaudeOutput.parse(data)
  }

  /// Bloquant, à appeler hors de l'acteur. `Process` n'est pas `Sendable` :
  /// il naît et meurt ici.
  private static func runBlocking(binary: String, arguments: [String], stdin: String, cwd: String?, timeoutSeconds: Int) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = arguments
    if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    // Un `claude` lancé depuis un autre `claude` refuse de démarrer : on ne
    // lui transmet pas les marqueurs de la session parente.
    var env = ProcessInfo.processInfo.environment
    for key in env.keys where key.hasPrefix("CLAUDECODE") || key.hasPrefix("CLAUDE_CODE_") { env.removeValue(forKey: key) }
    process.environment = env

    let input = Pipe(), output = Pipe(), errors = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    input.fileHandleForWriting.write(Data(stdin.utf8))
    try input.fileHandleForWriting.close()

    // Lire avant d'attendre : un tube plein bloquerait l'enfant.
    let outData = output.fileHandleForReading.readDataToEndOfFile()
    let errData = errors.fileHandleForReading.readDataToEndOfFile()

    let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
    while process.isRunning {
      if Date() >= deadline {
        process.terminate()
        throw AgentBackendError.timedOut(seconds: timeoutSeconds)
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
    guard process.terminationStatus == 0 || !outData.isEmpty else {
      let stderr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      throw AgentBackendError.exit(code: process.terminationStatus, stderr: String(stderr.suffix(400)))
    }
    return outData
  }
}
