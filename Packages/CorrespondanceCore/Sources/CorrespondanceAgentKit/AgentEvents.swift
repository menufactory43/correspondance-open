import CorrespondanceMatrixClient
import Foundation

/// Les events que l'agent pose et que les ponts ne relaient pas : la
/// proposition, que Correspondance rend comme un brouillon, et la demande de
/// permission, qu'un 👍 d'un propriétaire tranche.
public enum AgentEvents {
  public static let proposalType = AgentWire.proposalType
  public static let permissionType = AgentWire.permissionType
  /// Ce que l'agent sait de sa machine — posté au démarrage dans ses rooms en
  /// tête-à-tête (la note à soi en tête). La présence est éteinte sur le
  /// Relais, exprès : ce petit event est son remplaçant.
  public static let statusType = AgentWire.statusType

  /// La configuration de l'agent, event **d'état** de sa room console : écrite
  /// par l'app, lue par l'agent au démarrage et suivie à chaque `/sync`. Sur
  /// l'hôte il ne reste que l'amorce. Cf. `AgentRemoteConfig`.
  public static let configType = AgentWire.configType

  /// Le journal d'un tour dans la room console : qui a demandé, quels outils
  /// ont servi, combien de temps. Depuis la pleine permission, c'est ce qui
  /// rend un agent relisible — « cet agent a fait ça », pas « il s'est passé
  /// quelque chose ».
  public static let journalType = AgentWire.journalType

  public static func journal(
    agent: String, roomID: String, sender: String, prompt: String,
    tools: [String], seconds: Double, tokens: Int?
  ) -> MatrixJSON {
    var fields: [String: MatrixJSON] = [
      AgentWire.JournalKey.agent: .string(agent),
      AgentWire.JournalKey.room: .string(roomID),
      AgentWire.JournalKey.sender: .string(sender),
      // Assez pour reconnaître le tour, pas assez pour recopier la conversation
      // dans un journal que d'autres appareils synchronisent.
      AgentWire.JournalKey.prompt: .string(String(prompt.prefix(200))),
      AgentWire.JournalKey.tools: .array(tools.map(MatrixJSON.string)),
      AgentWire.JournalKey.seconds: .number((seconds * 10).rounded() / 10),
    ]
    if let tokens { fields[AgentWire.JournalKey.tokens] = .number(Double(tokens)) }
    return .object(fields)
  }

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

  /// Le contenu d'un status : la ligne des moteurs, et l'agent qui la signe.
  public static func status(body: String, agent: String) -> MatrixJSON {
    .object([
      "body": .string(body),
      "agent": .string(agent),
    ])
  }

  /// Le contenu d'une demande de permission : le texte lisible, l'outil, et
  /// l'agent. La décision est une `m.reaction` (👍/👎) sur cet event.
  public static func permission(body: String, tool: String, agent: String, inReplyTo eventID: String) -> MatrixJSON {
    .object([
      "body": .string(body),
      "tool": .string(tool),
      "agent": .string(agent),
      "m.relates_to": .object([
        "m.in_reply_to": .object(["event_id": .string(eventID)])
      ]),
    ])
  }

}
