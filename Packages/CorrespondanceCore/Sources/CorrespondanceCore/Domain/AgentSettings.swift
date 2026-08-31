import Foundation

/// Ce que l'utilisateur décide du comportement de « cc », et que l'agent lit.
///
/// L'agent ne tourne pas dans l'app : c'est un processus à part, sur le Relais.
/// Le seul canal entre les deux est l'account data Matrix globale
/// `fr.correspondance.agent.settings` — l'app l'écrit, l'agent la lit dans son
/// `/sync`. Aucun réglage n'est en dur, aucune API privée entre eux.
public struct AgentSettings: Hashable, Codable, Sendable {
  /// Comment l'agent répond quand rien d'autre n'en décide.
  public enum Mode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// L'agent parle tout haut : sa réponse part comme un message, et le pont
    /// la relaie au correspondant.
    case direct
    /// L'agent propose : un brouillon que je suis seul à voir, et que j'envoie
    /// — ou pas.
    case draft

    public var id: String { rawValue }

    public var labelFR: String {
      switch self {
      case .direct: "À voix haute"
      case .draft: "Brouillon à valider"
      }
    }

    public var subtitleFR: String {
      switch self {
      case .direct: "cc répond dans la conversation, et le correspondant le lit."
      case .draft: "cc propose ; rien ne part avant que tu l'aies envoyé."
      }
    }
  }

  /// Le mode des conversations où d'autres humains lisent. En tête-à-tête avec
  /// moi, l'agent répond toujours à voix haute — il n'y a personne à ménager.
  public var defaultMode: Mode

  public init(defaultMode: Mode = .draft) {
    self.defaultMode = defaultMode
  }

  /// Ce que l'agent fait quand l'account data n'a jamais été écrite.
  public static let fallback = AgentSettings(defaultMode: .draft)
}
