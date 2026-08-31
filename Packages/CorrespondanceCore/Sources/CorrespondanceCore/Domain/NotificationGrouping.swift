import Foundation

/// Une rafale de messages d'un même fil, telle qu'une notification la porte.
public struct NotificationBurst: Sendable, Equatable {
  /// L'identifiant de la notification système. Il ne bouge pas tant que la
  /// rafale dure : reposter la même le REMPLACE au lieu d'en empiler une
  /// deuxième — c'est tout le mécanisme.
  public let key: String
  /// Combien de messages cette notification résume.
  public var count: Int
  /// L'heure du dernier message compté.
  public var lastAt: Date

  public init(key: String, count: Int, lastAt: Date) {
    self.key = key
    self.count = count
    self.lastAt = lastAt
  }
}

/// Regrouper les notifications d'un même fil, sauf urgence.
///
/// Six messages en dix secondes, c'est une personne qui pense à voix haute :
/// une seule notification, la dernière, avec « et 5 autres messages ». C'est
/// la fonction la plus « Focus » de tout Beeper — elle rend le téléphone
/// silencieux sans rien cacher.
///
/// L'exception est le code à usage unique (`OneTimeCode`) : il vaut trente
/// secondes, il sonne tout de suite, et il ouvre sa propre notification.
public enum NotificationGrouping {
  /// Au-delà, ce n'est plus une rafale mais une autre prise de parole.
  public static let window: TimeInterval = 15

  /// L'état de la rafale après ce message.
  ///
  /// - Parameters:
  ///   - previous: la rafale en cours pour ce fil, s'il y en a une.
  ///   - sequence: un compteur qui ne recule pas, pour que deux rafales
  ///     successives du même fil ne partagent pas d'identifiant.
  public static func extend(
    _ previous: NotificationBurst?,
    conversationID: String,
    at now: Date,
    isUrgent: Bool,
    sequence: Int
  ) -> NotificationBurst {
    guard !isUrgent,
          let previous,
          now.timeIntervalSince(previous.lastAt) <= window,
          now >= previous.lastAt
    else {
      return NotificationBurst(key: "\(conversationID)#\(sequence)", count: 1, lastAt: now)
    }
    return NotificationBurst(key: previous.key, count: previous.count + 1, lastAt: now)
  }

  /// Ce que la notification dit : le dernier message, et ce qu'il cache.
  public static func bodyFR(latest: String, count: Int) -> String {
    guard count > 1 else { return latest }
    let others = count - 1
    let suffix = others == 1 ? "et 1 autre message" : "et \(others) autres messages"
    guard !latest.isEmpty else { return suffix }
    return "\(latest)\n\(suffix)"
  }
}
