import Foundation

/// Lance `hermes` (Nous Research) en un tour. La forme est celle éprouvée au
/// tir réel sur le NUC (cnvsSC/Fauconnier, 07-08/08), contre la doc :
///
/// - **jamais `-z`** : en mode `-z`, les flags de reprise (`--continue` comme
///   `-r`, par titre comme par ID) sont ignorés — chaque tour ouvrirait une
///   session neuve et amnésique. La reprise ne marche que sous `chat`.
/// - `hermes chat -Q --oneshot -q '…'` : un tour, sans bannière ni spinner.
/// - `-Q` écrit sa plomberie (`session_id: <id>`, « ↻ Resumed session … »)
///   sur **stderr** quand les flux sont séparés — c'est là qu'on lit la
///   session, et on écarte défensivement la même ligne de stdout.
/// - une session perdue se refuse par « No session found », code 1,
///   l'explication sur **stdout** : on repart alors sur une session neuve au
///   lieu de montrer l'erreur dans la room.
///
/// Hermes gère ses outils dans sa propre config (`hermes tools`) : le spool de
/// permissions est ignoré ici — configure-le serré avant de l'inviter.
public struct HermesBackend: AgentBackend {
  public var settings: AgentConfig.HermesSettings

  /// Le refus d'une session inconnue, tel qu'il sort — chaîne de l'outil d'en
  /// face : le jour où elle change, c'est ce littéral qu'on cherche.
  public static let refusDeSession = "No session found"

  public init(settings: AgentConfig.HermesSettings) {
    self.settings = settings
  }

  public static func resolveBinary(_ configured: String?) -> String? {
    Subprocess.find("hermes", configured: configured)
  }

  /// Les arguments d'un tour. Le prompt passe en argument (pas de shell entre
  /// nous : rien à échapper). `oneshot` : depuis 0.21, `-q` sème une session
  /// interactive et il faut `--oneshot` pour répondre-et-sortir ; en 0.20 le
  /// flag n'existe pas (vérifié sur le NUC) et `-q` sort tout seul — on tente
  /// avec, on retombe sans quand Hermes ne le connaît pas.
  public static func arguments(settings: AgentConfig.HermesSettings, sessionID: String?, prompt: String, oneshot: Bool = true) -> [String] {
    var args = oneshot ? ["chat", "-Q", "--oneshot", "-q", prompt] : ["chat", "-Q", "-q", prompt]
    if let sessionID { args += ["-r", sessionID] }
    if let model = settings.model { args += ["-m", model] }
    return args
  }

  /// La session, lue dans la plomberie de `-Q` : une ligne `session_id: <id>`,
  /// sur stderr flux séparés — on accepte les deux flux, au cas où.
  public static func sessionID(in text: String) -> String? {
    for line in text.split(separator: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("session_id:") else { continue }
      let id = trimmed.dropFirst("session_id:".count).trimmingCharacters(in: .whitespaces)
      return id.isEmpty ? nil : id
    }
    return nil
  }

  /// La réponse sans la plomberie : la ligne `session_id:` écartée où qu'elle
  /// soit, le reste trimé.
  public static func reply(from stdout: String) -> String {
    stdout.split(separator: "\n", omittingEmptySubsequences: false)
      .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("session_id:") }
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public func run(prompt: String, cwd: String?, sessionID: String?, permissionSpool: URL?) async throws -> AgentTurn {
    let turn: AgentTurn
    do {
      turn = try await oneTurn(prompt: prompt, cwd: cwd, sessionID: sessionID, oneshot: true)
    } catch AgentBackendError.exit(_, let stderr) where stderr.contains("--oneshot") {
      // Hermes 0.20 : le flag n'existe pas, et `-q` sort tout seul.
      turn = try await oneTurn(prompt: prompt, cwd: cwd, sessionID: sessionID, oneshot: false)
    }
    // La session que l'état retenait n'existe plus chez Hermes : on repart de
    // zéro plutôt que de porter le refus dans la room.
    if turn.isError, turn.text.contains(Self.refusDeSession), sessionID != nil {
      return try await run(prompt: prompt, cwd: cwd, sessionID: nil, permissionSpool: permissionSpool)
    }
    return turn
  }

  private func oneTurn(prompt: String, cwd: String?, sessionID: String?, oneshot: Bool) async throws -> AgentTurn {
    guard let binary = Self.resolveBinary(settings.binary) else { throw AgentBackendError.binaryNotFound }
    let args = Self.arguments(settings: settings, sessionID: sessionID, prompt: prompt, oneshot: oneshot)
    let workdir = cwd ?? settings.defaultCwd
    let timeout = settings.timeoutSeconds
    let output = try await Task.detached(priority: .userInitiated) {
      try Subprocess.run(binary: binary, arguments: args, stdin: "", cwd: workdir, timeoutSeconds: timeout)
    }.value
    let stdout = String(data: output.stdout, encoding: .utf8) ?? ""
    let stderr = String(data: output.stderr, encoding: .utf8) ?? ""
    let text = Self.reply(from: stdout)
    let session = Self.sessionID(in: stderr) ?? Self.sessionID(in: stdout) ?? sessionID
    return AgentTurn(text: text, sessionID: session, isError: output.status != 0 || text.isEmpty)
  }
}
