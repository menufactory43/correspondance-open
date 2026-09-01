import Foundation

/// Les moteurs qu'on garde debout, un par conversation — la conversation est
/// identifiée par son dossier de travail, que `Workspace` garantit unique par
/// agent et par room.
///
/// Pourquoi : un tour froid paie ~2,9 s de démarrage (`docs/SPIKE-acp.md`).
/// Pourquoi pas indéfiniment : un moteur debout, c'est un processus et sa
/// mémoire ; une conversation qu'on ne relance pas doit finir par se taire.
public actor ACPEnginePool {

  /// Ce qu'on garde, et combien de temps. Pur, donc éprouvé par les tests.
  public struct Policy: Sendable, Equatable {
    /// Au-delà de ce silence, un moteur s'éteint.
    public var idleSeconds: TimeInterval = 600
    /// Le nombre de conversations qu'on garde chaudes en même temps. Au-delà,
    /// la plus ancienne s'efface — sinon un agent bavard finit avec cinquante
    /// processus.
    public var maxEngines: Int = 4

    public init(idleSeconds: TimeInterval = 600, maxEngines: Int = 4) {
      self.idleSeconds = idleSeconds
      self.maxEngines = maxEngines
    }

    public func isExpired(lastUsed: Date, now: Date) -> Bool {
      now.timeIntervalSince(lastUsed) > idleSeconds
    }

    /// Qui s'efface quand il y en a trop : le plus anciennement servi.
    public func victim(among engines: [(key: String, lastUsed: Date)]) -> String? {
      guard engines.count > maxEngines else { return nil }
      return engines.min(by: { $0.lastUsed < $1.lastUsed })?.key
    }
  }

  private var policy: Policy
  private var engines: [String: ACPEngine] = [:]
  private let log: @Sendable (String) -> Void

  public init(policy: Policy = Policy(), log: @escaping @Sendable (String) -> Void = { _ in }) {
    self.policy = policy
    self.log = log
  }

  /// Le moteur de cette conversation, chaud s'il l'est encore. Un moteur mort
  /// (le processus a rendu l'âme) est remplacé sans bruit.
  func engine(for cwd: String, settings: AgentConfig.ACPSettings) -> ACPEngine {
    sweep(now: Date())
    if let existing = engines[cwd], existing.isAlive { return existing }
    if let dead = engines[cwd] {
      dead.shutdown()
      log("moteur de \(cwd) éteint tout seul — je le relance")
    }
    let engine = ACPEngine(cwd: cwd, settings: settings, log: log)
    engines[cwd] = engine
    evictIfCrowded()
    return engine
  }

  /// Éteint tout — à l'arrêt de l'agent, ou quand la config change de moteur.
  public func shutdownAll() {
    for engine in engines.values { engine.shutdown() }
    engines.removeAll()
  }

  func sweep(now: Date) {
    for (key, engine) in engines where policy.isExpired(lastUsed: engine.lastUsed, now: now) {
      engine.shutdown()
      engines.removeValue(forKey: key)
      log("moteur de \(key) éteint après \(Int(policy.idleSeconds / 60)) min de silence")
    }
  }

  private func evictIfCrowded() {
    let inventory = engines.map { (key: $0.key, lastUsed: $0.value.lastUsed) }
    guard let victim = policy.victim(among: inventory) else { return }
    engines[victim]?.shutdown()
    engines.removeValue(forKey: victim)
    log("moteur de \(victim) éteint : trop de conversations chaudes à la fois")
  }
}
