import Foundation

/// Ce que « cc » dit **de lui-même**, à ses propriétaires seuls : un tour qui
/// a échoué et pourquoi, un délai dépassé, un moteur absent, ou la main qu'il
/// passe. Porté par `fr.correspondance.agent.notice` (`AgentWire.noticeType`),
/// que les ponts ne relaient pas. Le fil le rend en ligne système, avec un
/// geste quand il y en a un : une panne qui ne se voit pas passe pour de la
/// lenteur.
public struct AgentNotice: Hashable, Codable, Sendable {
  /// La même chaîne qu'`AgentWire.noticeType` — le contrat est la chaîne.
  public static let eventType = "fr.correspondance.agent.notice"

  /// Qui parle (`cc`).
  public var agent: String
  /// La phrase, en français, telle que l'agent l'a écrite.
  public var body: String
  /// `engine_missing`, `engine_offline`, `timeout`, `error`, `handover` —
  /// ou autre chose : on ne ferme pas la liste.
  public var reason: String?
  /// Le geste proposé : `rescan` (relancer), `retry` (réessayer), ou rien.
  public var action: Action?

  public enum Action: String, Hashable, Codable, Sendable {
    case rescan, retry

    public var labelFR: String {
      switch self {
      case .rescan: "Relancer"
      case .retry: "Réessayer"
      }
    }
  }

  public init(agent: String, body: String, reason: String? = nil, action: Action? = nil) {
    self.agent = agent
    self.body = body
    self.reason = reason
    self.action = action
  }

  /// Passer la main n'est pas une panne : la pastille reste grise. Tout le
  /// reste — moteur absent, délai, erreur — se dit en rouge.
  public var isFailure: Bool {
    guard let reason, !reason.isEmpty else { return false }
    return reason != "handover"
  }
}
