import Foundation

/// Plafond glissant : au plus `limit` passages par fenêtre. Ce qui protège
/// l'abonnement quand personne ne regarde.
public struct HourlyCap: Sendable {
  public let limit: Int
  public let window: TimeInterval
  private var stamps: [Date] = []

  public init(limit: Int, window: TimeInterval = 3600) {
    self.limit = limit
    self.window = window
  }

  /// `true` et consomme un passage s'il en reste ; `false` sinon, sans rien consommer.
  public mutating func admit(now: Date = Date()) -> Bool {
    stamps.removeAll { now.timeIntervalSince($0) >= window }
    guard stamps.count < limit else { return false }
    stamps.append(now)
    return true
  }

  public func remaining(now: Date = Date()) -> Int {
    max(0, limit - stamps.filter { now.timeIntervalSince($0) < window }.count)
  }

  /// Dans combien de temps un passage se libère. `nil` s'il en reste déjà.
  public func nextSlot(now: Date = Date()) -> TimeInterval? {
    let live = stamps.filter { now.timeIntervalSince($0) < window }.sorted()
    guard live.count >= limit, let oldest = live.first else { return nil }
    return window - now.timeIntervalSince(oldest)
  }
}
