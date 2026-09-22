import Foundation

/// Le rapatriement d'un compte qu'on vient de connecter, vu de l'inbox.
///
/// Un pont fraîchement connecté crée ses salons un par un, pendant deux ou trois
/// minutes, et l'inbox se réordonnait sous les yeux à chaque arrivée. Ici, les
/// fils du réseau sont **retenus** le temps que ça dure, une carte dit où on en
/// est, et tout apparaît ensemble à la fin. Pur et `Sendable` : la règle qui
/// décide « c'est fini » se teste sans magasin.
public struct BridgeIntake: Equatable, Sendable {
  public let network: MessageNetwork
  public let startedAt: Date
  /// Combien de conversations le pont relit à la connexion. C'est un réglage à
  /// nous (`login_sync_limit`, `max_initial_conversations`… selon le pont), donc
  /// la barre a une vraie fin ; au-delà, elle reste pleine.
  public let expectedCount: Int
  /// Les fils du réseau déjà là.
  public private(set) var count: Int = 0
  /// La dernière fois qu'un fil de plus est arrivé.
  public private(set) var lastArrivalAt: Date

  /// Sans fil nouveau pendant ce temps, le pont a fini — il n'en crée jamais
  /// à plus de quelques secondes d'écart tant qu'il rapatrie.
  public static let quietPeriod: TimeInterval = 12
  /// Rien n'est arrivé du tout : on cesse d'attendre, il n'y a rien à retenir.
  public static let emptyPatience: TimeInterval = 60
  /// Quoi qu'il arrive, on ne retient jamais l'inbox plus longtemps que ça.
  public static let maxDuration: TimeInterval = 5 * 60

  public init(network: MessageNetwork, startedAt: Date, expectedCount: Int = 30) {
    self.network = network
    self.startedAt = startedAt
    self.expectedCount = max(1, expectedCount)
    self.lastArrivalAt = startedAt
  }

  /// Un relevé : combien de fils du réseau l'inbox connaît maintenant.
  public mutating func observe(count: Int, at now: Date) {
    guard count != self.count else { return }
    self.count = count
    lastArrivalAt = now
  }

  /// Le pont a-t-il fini ? `bridgeState` est le `state_event` du compte
  /// d'après `whoami` (`BACKFILLING` tant que le pont le dit lui-même).
  public func isSettled(at now: Date, bridgeState: String? = nil) -> Bool {
    if now.timeIntervalSince(startedAt) >= Self.maxDuration { return true }
    if bridgeState == "BACKFILLING" { return false }
    if count == 0 { return now.timeIntervalSince(startedAt) >= Self.emptyPatience }
    return now.timeIntervalSince(lastArrivalAt) >= Self.quietPeriod
  }

  /// La barre : de 0 à 1, pleine dès que le pont a relu ce qu'on lui demande.
  public var progress: Double {
    min(1, Double(count) / Double(expectedCount))
  }

  /// « 12 fils rapatriés », « Un fil rapatrié », « Le pont relit tes conversations… ».
  public var countLabelFR: String {
    switch count {
    case 0: String(localized: "Le pont relit tes conversations…")
    case 1: String(localized: "Un fil rapatrié")
    default: String(localized: "\(count) fils rapatriés")
    }
  }
}
