import CorrespondanceMatrixClient
import Foundation

/// Un moteur ACP **debout** : son processus, sa session, sa conversation.
/// On le garde entre deux tours d'une même conversation — mesuré dans
/// `docs/SPIKE-acp.md`, ça épargne ~2,9 s par tour (0,4 s de processus,
/// 2,5 s de `session/load`).
///
/// Bloquant par construction : il vit dans un `Task.detached`, jamais sur un
/// acteur. `@unchecked Sendable` parce que `Process` ne l'est pas — le verrou
/// interne garantit qu'un seul tour le traverse à la fois.
final class ACPEngine: @unchecked Sendable {
  let cwd: String
  private let settings: AgentConfig.ACPSettings
  private let log: @Sendable (String) -> Void
  private let lock = NSLock()

  private var process: Process?
  private var input: FileHandle?
  private var reader: LineReader?
  private var nextID = 1
  /// La session ACP en cours dans ce processus — tant qu'elle tient, un tour
  /// n'a ni `session/new` ni `session/load` à payer.
  private(set) var sessionID: String?
  private(set) var lastUsed = Date()
  private var loadSession = false
  private var announcedModes: [String] = []

  init(cwd: String, settings: AgentConfig.ACPSettings, log: @escaping @Sendable (String) -> Void) {
    self.cwd = cwd
    self.settings = settings
    self.log = log
  }

  var isAlive: Bool {
    lock.lock()
    defer { lock.unlock() }
    return process?.isRunning == true
  }

  // MARK: - Un tour

  /// Le tour complet, en réutilisant ce qui peut l'être. `sessionID` est celui
  /// que l'agent a retenu pour cette conversation : on ne le recharge que si le
  /// processus ne le porte pas déjà.
  func turn(prompt: String, resuming sessionID: String?) throws -> AgentTurn {
    lock.lock()
    defer {
      lastUsed = Date()
      lock.unlock()
    }
    let deadline = Date().addingTimeInterval(TimeInterval(settings.timeoutSeconds))
    var text = ""
    var tools: [String] = []

    try startIfNeeded(before: deadline)
    try prepareSession(resuming: sessionID, before: deadline)
    guard let session = self.sessionID else {
      throw AgentBackendError.unreadableOutput("aucune session ACP")
    }

    let result = try call(ACP.promptRequest(id: takeID(), sessionID: session, text: prompt),
                          id: nextID - 1, before: deadline, text: &text, tools: &tools)
    let stop = result["stopReason"]?.stringValue ?? "end_turn"
    let tokens = ACP.totalTokens(in: result)
    if !tools.isEmpty { log("outils du tour : \(tools.joined(separator: ", "))") }

    var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if body.isEmpty, stop != "end_turn" {
      body = "Le moteur s'est arrêté : \(stop.replacingOccurrences(of: "_", with: " "))."
    }
    return AgentTurn(
      text: body, sessionID: session, isError: stop == "refusal" || stop == "error",
      tools: tools, tokens: tokens
    )
  }

  func shutdown() {
    lock.lock()
    defer { lock.unlock() }
    try? input?.close()
    if process?.isRunning == true { process?.terminate() }
    process = nil
    input = nil
    reader = nil
    sessionID = nil
  }

  // MARK: - Le processus

  private func startIfNeeded(before deadline: Date) throws {
    if process?.isRunning == true { return }
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

    let inputPipe = Pipe(), outputPipe = Pipe(), errorPipe = Pipe()
    process.standardInput = inputPipe
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    // On ne lit jamais stderr jusqu'au bout : on le vide pour ne pas remplir le tube.
    errorPipe.fileHandleForReading.readabilityHandler = { _ = $0.availableData }
    try process.run()

    self.process = process
    self.input = inputPipe.fileHandleForWriting
    self.reader = LineReader(handle: outputPipe.fileHandleForReading)
    self.nextID = 1
    self.sessionID = nil

    var text = "", tools: [String] = []
    let initialize = try call(ACP.initializeRequest(id: takeID()), id: nextID - 1, before: deadline,
                              text: &text, tools: &tools)
    loadSession = initialize.value(at: "agentCapabilities.loadSession")?.boolValue == true
    let name = initialize.value(at: "agentInfo.name")?.stringValue ?? settings.command
    let version = initialize.value(at: "agentInfo.version")?.stringValue ?? "?"
    log("moteur ACP : \(name) \(version)")
    if let pinned = settings.pinnedVersion, version != "?", version != pinned {
      // Une version qu'on n'a pas éprouvée : le mode par défaut d'un adaptateur
      // change d'une version à l'autre (cf. le mode `auto` de claude-agent-acp).
      log("⚠ adaptateur en \(version), le catalogue épingle \(pinned) — régime à revérifier")
    }
  }

  private func prepareSession(resuming sessionID: String?, before deadline: Date) throws {
    if let current = self.sessionID, sessionID == nil || sessionID == current { return }
    var text = "", tools: [String] = []
    var modes: (current: String?, available: [String]) = (nil, [])

    if let sessionID, loadSession {
      do {
        let loaded = try call(ACP.sessionLoadRequest(id: takeID(), sessionID: sessionID, cwd: cwd),
                              id: nextID - 1, before: deadline, text: &text, tools: &tools)
        self.sessionID = sessionID
        modes = ACP.modes(in: loaded)
      } catch {
        log("session \(sessionID) perdue (\(error.localizedDescription)) — on repart neuf")
      }
    }
    if self.sessionID == nil {
      let created = try call(ACP.sessionNewRequest(id: takeID(), cwd: cwd), id: nextID - 1,
                             before: deadline, text: &text, tools: &tools)
      guard let id = ACP.sessionID(in: created) else {
        throw AgentBackendError.unreadableOutput("session/new sans sessionId")
      }
      self.sessionID = id
      modes = ACP.modes(in: created)
    }
    announcedModes = modes.available

    // Le régime se pose, il ne se subit jamais — même quand on autorise tout.
    guard let session = self.sessionID,
          let mode = settings.resolvedMode(available: modes.available), mode != modes.current
    else { return }
    _ = try? call(ACP.setModeRequest(id: takeID(), sessionID: session, mode: mode),
                  id: nextID - 1, before: deadline, text: &text, tools: &tools)
    log("mode de permission forcé : \(mode) (le moteur démarrait en \(modes.current ?? "?"))")
  }

  // MARK: - JSON-RPC

  private func takeID() -> Int {
    defer { nextID += 1 }
    return nextID
  }

  private func send(_ line: String) throws {
    guard let data = line.data(using: .utf8), let input else { return }
    try input.write(contentsOf: data)
  }

  /// Envoie une requête, honore tout ce que le moteur demande en attendant
  /// (permissions comprises), et rend son résultat.
  private func call(
    _ line: String, id: Int, before deadline: Date, text: inout String, tools: inout [String]
  ) throws -> MatrixJSON {
    try send(line)
    while true {
      guard let reader, let incoming = reader.next(before: deadline) else {
        throw AgentBackendError.timedOut(seconds: settings.timeoutSeconds)
      }
      switch ACP.parse(line: incoming) {
      case .result(let responseID, let value) where responseID == id:
        return value
      case .failure(let responseID, let message) where responseID == id:
        throw AgentBackendError.exit(code: 1, stderr: message)
      case .result, .failure:
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
      case .noise(let noise) where !noise.isEmpty:
        log("moteur : \(noise.prefix(200))")
      case .noise:
        continue
      }
    }
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
        if buffer.isEmpty { return nil }
        let line = String(data: buffer, encoding: .utf8)
        buffer.removeAll()
        return line
      }
      buffer.append(chunk)
    }
  }
}
