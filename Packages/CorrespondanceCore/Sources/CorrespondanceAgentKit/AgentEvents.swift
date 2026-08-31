import CorrespondanceMatrixClient
import Foundation

/// Les events que l'agent pose et que les ponts ne relaient pas. Un seul type
/// pour l'instant : la proposition, que Correspondance rendra comme un brouillon.
public enum AgentEvents {
  public static let proposalType = "fr.correspondance.agent.proposal"

  /// Le contenu d'une proposition : le texte, l'agent qui le signe, et le
  /// message auquel il répond — pour que l'app la place au bon endroit du fil.
  public static func proposal(text: String, agent: String, inReplyTo eventID: String) -> MatrixJSON {
    .object([
      "body": .string(text),
      "agent": .string(agent),
      "m.relates_to": .object([
        "m.in_reply_to": .object(["event_id": .string(eventID)])
      ]),
    ])
  }

  /// Le préfixe quand l'agent parle **au nom du propriétaire** (mode direct sur
  /// un portail en relais) : les humains doivent savoir que ce n'est pas lui.
  public static func directPrefix(agent: String) -> String { "🤖 \(agent) : " }
}
