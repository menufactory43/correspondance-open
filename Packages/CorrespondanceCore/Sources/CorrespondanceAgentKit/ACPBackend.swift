import CorrespondanceMatrixClient
import Foundation

/// Un moteur qui parle ACP — Claude Code, Codex, goose — piloté en JSON-RPC
/// sur stdio, et gardé chaud le temps d'une conversation.
///
/// Ce que ce backend remplace, à terme : le parseur de `--output-format json`
/// (`session/update`), les sessions `--resume` (`session/load`), le spool de
/// permissions (`session/request_permission`). `ClaudeCodeBackend` reste le
/// repli tant que l'adaptateur n'est pas posé par l'installation sur tous les
/// hôtes (cf. `docs/AGENT.md`).
public struct ACPBackend: AgentBackend {
  public var settings: AgentConfig.ACPSettings
  public var log: @Sendable (String) -> Void
  private let pool: ACPEnginePool

  public init(
    settings: AgentConfig.ACPSettings,
    pool: ACPEnginePool? = nil,
    log: @escaping @Sendable (String) -> Void = { _ in }
  ) {
    self.settings = settings
    self.log = log
    self.pool = pool ?? ACPEnginePool(
      policy: .init(idleSeconds: TimeInterval(settings.idleSeconds)), log: log
    )
  }

  /// L'adaptateur du moteur sur cette machine — le `PATH` d'un LaunchAgent est
  /// vide, donc la recherche est la nôtre.
  public static func resolveBinary(_ settings: AgentConfig.ACPSettings) -> String? {
    Subprocess.find(settings.command, configured: settings.binary)
  }

  public func run(prompt: String, cwd: String?, sessionID: String?, permissionSpool: URL?) async throws -> AgentTurn {
    // Le spool est ignoré : en ACP la permission passe par le protocole, et la
    // décision est « oui » (cf. `docs/PLAN-relais-agents.md`, pleine permission).
    let workdir = cwd ?? settings.defaultCwd ?? FileManager.default.currentDirectoryPath
    let engine = await pool.engine(for: workdir, settings: settings)
    return try await Task.detached(priority: .userInitiated) {
      try engine.turn(prompt: prompt, resuming: sessionID)
    }.value
  }

  public func shutdown() async {
    await pool.shutdownAll()
  }
}

/// Un moteur, et ce sur quoi on retombe s'il n'est pas là.
///
/// L'ACP apporte une dépendance neuve (un adaptateur Node) là où `claude`
/// suffisait. Tant que l'installation ne pose pas l'adaptateur partout, un hôte
/// peut se retrouver sans lui : plutôt que de rester muet, l'agent répond par
/// la CLI et le dit. Le repli est **collant** — une fois retombé, on n'essaie
/// pas l'adaptateur à chaque message.
public actor FallbackBackend: AgentBackend {
  private let primary: any AgentBackend
  private let secondary: any AgentBackend
  private let log: @Sendable (String) -> Void
  private var fellBack = false

  public init(
    primary: any AgentBackend, secondary: any AgentBackend,
    log: @escaping @Sendable (String) -> Void = { _ in }
  ) {
    self.primary = primary
    self.secondary = secondary
    self.log = log
  }

  /// Vrai une fois qu'on a renoncé à l'adaptateur — le status le dit.
  public var isFallenBack: Bool { fellBack }

  public func run(prompt: String, cwd: String?, sessionID: String?, permissionSpool: URL?) async throws -> AgentTurn {
    if fellBack {
      return try await secondary.run(prompt: prompt, cwd: cwd, sessionID: sessionID, permissionSpool: permissionSpool)
    }
    do {
      return try await primary.run(prompt: prompt, cwd: cwd, sessionID: sessionID, permissionSpool: permissionSpool)
    } catch let error as AgentBackendError where Self.isStartupFailure(error) {
      fellBack = true
      log("moteur ACP indisponible (\(error.localizedDescription)) — je réponds par la CLI en attendant")
      return try await secondary.run(prompt: prompt, cwd: cwd, sessionID: sessionID, permissionSpool: permissionSpool)
    }
  }

  /// Ce qui justifie un repli : l'adaptateur manque ou ne parle pas. Une erreur
  /// *du modèle* n'est pas ça — on ne rejoue pas un refus sur un autre moteur.
  static func isStartupFailure(_ error: AgentBackendError) -> Bool {
    switch error {
    case .binaryNotFound: true
    case .unreadableOutput: true
    case .exit: true
    case .timedOut: false
    }
  }
}
