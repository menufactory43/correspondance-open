import CorrespondanceMatrixClient
import Foundation

/// Un moteur qui parle ACP — Claude Code, Codex, goose — lancé en sous-processus
/// et piloté en JSON-RPC sur stdio.
///
/// Ce que ce backend remplace, à terme : le parseur de `--output-format json`
/// (`session/update`), les sessions `--resume` (`session/load`), le spool de
/// permissions (`session/request_permission`). `ClaudeCodeBackend` reste comme
/// filet tant que l'ACP n'est pas éprouvé sur un hôte Linux.
public struct ACPBackend: AgentBackend {
  public var settings: AgentConfig.ACPSettings
  /// Ce que le moteur a fait pendant le dernier tour — les outils, pour le journal.
  public var log: @Sendable (String) -> Void

  public init(settings: AgentConfig.ACPSettings, log: @escaping @Sendable (String) -> Void = { _ in }) {
    self.settings = settings
    self.log = log
  }

  /// L'adaptateur du moteur sur cette machine — le `PATH` d'un LaunchAgent est
  /// vide, donc la recherche est la nôtre.
  public static func resolveBinary(_ settings: AgentConfig.ACPSettings) -> String? {
    Subprocess.find(settings.command, configured: settings.binary)
  }

  public func run(prompt: String, cwd: String?, sessionID: String?, permissionSpool: URL?) async throws -> AgentTurn {
    // Le spool est ignoré : en ACP la permission passe par le protocole, et la
    // décision est « oui » (cf. `docs/PLAN-relais-agents.md`, pleine permission).
    let settings = self.settings
    let log = self.log
    let workdir = cwd ?? settings.defaultCwd ?? FileManager.default.currentDirectoryPath
    return try await Task.detached(priority: .userInitiated) {
      try ACPConversation(settings: settings, log: log).turn(prompt: prompt, cwd: workdir, sessionID: sessionID)
    }.value
  }
}

/// Un tour complet, du lancement du moteur à sa réponse. Bloquant : il naît et
/// meurt hors de l'acteur, comme `Subprocess`.
struct ACPConversation {
  var settings: AgentConfig.ACPSettings
  var log: @Sendable (String) -> Void

  func turn(prompt: String, cwd: String, sessionID: String?) throws -> AgentTurn {
    guard let binary = Subprocess.find(settings.command, configured: settings.binary) else {
      throw AgentBackendError.binaryNotFound
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = settings.arguments
    process.currentDirectoryURL = URL(fileURLWithPath: cwd)
    // Un moteur lancé depuis une session Claude Code refuse de démarrer.
    var env = ProcessInfo.processInfo.environment
    for key in env.keys where key.hasPrefix("CLAUDECODE") || key.hasPrefix("CLAUDE_CODE_") {
      env.removeValue(forKey: key)
    }
    process.environment = env

    let input = Pipe(), output = Pipe(), errors = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    defer {
      if process.isRunning { process.terminate() }
    }
    // On ne lit jamais stderr jusqu'au bout (le moteur y bavarde tant qu'il
    // vit) : on le vide en tâche de fond pour ne pas remplir le tube.
    errors.fileHandleForReading.readabilityHandler = { handle in
      _ = handle.availableData
    }
    defer { errors.fileHandleForReading.readabilityHandler = nil }

    let reader = LineReader(handle: output.fileHandleForReading)
    let deadline = Date().addingTimeInterval(TimeInterval(settings.timeoutSeconds))
    var nextID = 1
    var text = ""
    var tools: [String] = []
    var tokens: Int?

    func send(_ line: String) throws {
      guard let data = line.data(using: .utf8) else { return }
      try input.fileHandleForWriting.write(contentsOf: data)
    }

    /// Envoie une requête et rend son résultat, en honorant au passage tout ce
    /// que le moteur nous demande (permissions comprises).
    func call(_ line: String, id: Int) throws -> MatrixJSON {
      try send(line)
      while true {
        guard Date() < deadline else { throw AgentBackendError.timedOut(seconds: settings.timeoutSeconds) }
        guard let incoming = reader.next(before: deadline) else {
          throw AgentBackendError.unreadableOutput("le moteur s'est tu")
        }
        switch ACP.parse(line: incoming) {
        case .result(let responseID, let value) where responseID == id:
          return value
        case .result:
          continue
        case .failure(let responseID, let message) where responseID == id:
          throw AgentBackendError.exit(code: 1, stderr: message)
        case .failure:
          continue
        case .request(let requestID, let method, let params):
          if method == "session/request_permission" {
            if let tool = params.value(at: "toolCall.title")?.stringValue { tools.append(tool) }
            try send(ACP.permissionResponse(id: requestID, params: params))
          } else {
            try send(ACP.emptyResponse(id: requestID))
          }
        case .notification(_, let params):
          if let chunk = ACP.messageChunk(in: params) { text += chunk }
          if let tool = ACP.toolCall(in: params) { tools.append(tool) }
        case .noise(let line) where !line.isEmpty:
          log("moteur : \(line.prefix(200))")
        case .noise:
          continue
        }
      }
    }

    let initialize = try call(ACP.initializeRequest(id: nextID), id: nextID)
    nextID += 1
    if initialize["agentInfo"] != nil {
      let name = initialize.value(at: "agentInfo.name")?.stringValue ?? settings.command
      let version = initialize.value(at: "agentInfo.version")?.stringValue ?? "?"
      log("moteur ACP : \(name) \(version)")
    }

    // Reprendre la conversation si on en a une, en repartir neuf sinon — un
    // `session/load` qui échoue (session oubliée par le moteur) ne perd que la
    // mémoire, pas le tour.
    var session: String
    var modes: (current: String?, available: [String]) = (nil, [])
    if let sessionID, initialize.value(at: "agentCapabilities.loadSession")?.boolValue == true {
      do {
        let loaded = try call(ACP.sessionLoadRequest(id: nextID, sessionID: sessionID, cwd: cwd), id: nextID)
        nextID += 1
        session = sessionID
        modes = ACP.modes(in: loaded)
      } catch {
        log("session \(sessionID) perdue (\(error.localizedDescription)) — on repart neuf")
        let created = try call(ACP.sessionNewRequest(id: nextID, cwd: cwd), id: nextID)
        nextID += 1
        guard let id = ACP.sessionID(in: created) else {
          throw AgentBackendError.unreadableOutput("session/new sans sessionId")
        }
        session = id
        modes = ACP.modes(in: created)
      }
    } else {
      let created = try call(ACP.sessionNewRequest(id: nextID, cwd: cwd), id: nextID)
      nextID += 1
      guard let id = ACP.sessionID(in: created) else {
        throw AgentBackendError.unreadableOutput("session/new sans sessionId")
      }
      session = id
      modes = ACP.modes(in: created)
    }

    // Le régime se pose, il ne se subit pas — même quand on autorise tout.
    if let mode = settings.resolvedMode(available: modes.available), mode != modes.current {
      _ = try? call(ACP.setModeRequest(id: nextID, sessionID: session, mode: mode), id: nextID)
      nextID += 1
      log("mode de permission forcé : \(mode) (le moteur démarrait en \(modes.current ?? "?"))")
    }

    let result = try call(ACP.promptRequest(id: nextID, sessionID: session, text: prompt), id: nextID)
    tokens = ACP.totalTokens(in: result)
    let stop = result["stopReason"]?.stringValue ?? "end_turn"
    if !tools.isEmpty { log("outils du tour : \(tools.joined(separator: ", "))") }
    if let tokens { log("jetons du tour : \(tokens)") }

    try? input.fileHandleForWriting.close()
    var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if body.isEmpty, stop != "end_turn" {
      body = "Le moteur s'est arrêté : \(stop.replacingOccurrences(of: "_", with: " "))."
    }
    return AgentTurn(text: body, sessionID: session, isError: stop == "refusal" || stop == "error")
  }
}

/// Lit un flux ligne par ligne, sans jamais bloquer au-delà de l'échéance du tour.
final class LineReader {
  private let handle: FileHandle
  private var buffer = Data()

  init(handle: FileHandle) {
    self.handle = handle
  }

  func next(before deadline: Date) -> String? {
    while true {
      if let index = buffer.firstIndex(of: 0x0A) {
        let line = buffer[buffer.startIndex..<index]
        buffer.removeSubrange(buffer.startIndex...index)
        return String(data: line, encoding: .utf8) ?? ""
      }
      guard Date() < deadline else { return nil }
      let chunk = handle.availableData
      if chunk.isEmpty {
        // Fin de flux : ce qui reste sans saut de ligne compte quand même.
        if buffer.isEmpty { return nil }
        let line = String(data: buffer, encoding: .utf8)
        buffer.removeAll()
        return line
      }
      buffer.append(chunk)
    }
  }
}
