import Foundation

/// Ce que « cc » propose d'écrire — un brouillon, pas un message.
///
/// Dans un salon où d'autres humains lisent, l'agent ne prend pas la parole :
/// il pose un event `fr.correspondance.agent.proposal`, que les ponts mautrix
/// ne relaient pas (ils ne traduisent que `m.room.message`). La proposition
/// n'existe donc que sur le Relais, et ne se voit que dans Correspondance.
/// C'est le propriétaire qui décide : envoyer, corriger, ou ignorer.
public struct AgentProposal: Hashable, Codable, Sendable {
  /// Le type d'event qui la porte.
  ///
  /// La même chaîne qu'`AgentEvents.proposalType`, écrite deux fois **exprès** :
  /// l'agent tourne sur le Relais, sans le domaine de l'app (`CorrespondanceAgentKit`
  /// ne dépend que du client Matrix, pour compiler sous Linux). Le contrat entre
  /// les deux est cette chaîne, pas un type partagé.
  public static let eventType = "fr.correspondance.agent.proposal"

  /// Qui propose (`cc`). Écrit dans l'en-tête de la carte.
  public var agent: String
  /// Le texte proposé, tel qu'il partirait.
  public var text: String
  /// Le message auquel l'agent répond — l'ordre qui l'a déclenché.
  public var inReplyToEventID: String?

  public init(agent: String, text: String, inReplyToEventID: String? = nil) {
    self.agent = agent
    self.text = text
    self.inReplyToEventID = inReplyToEventID
  }

  /// « ✏️ cc propose » — l'en-tête de la carte, sur les deux plateformes.
  public var headerFR: String {
    let name = agent.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? "L'agent propose" : "\(name) propose"
  }

  /// Une proposition sans texte n'a rien à proposer.
  public var isEmpty: Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}

/// Un **aparté** : ce que je dis à un agent devant des humains.
///
/// Dans un fil bridgé, nommer un agent (« @cc résume », « dis à @claude… »)
/// fait partir le message en `fr.correspondance.agent.aside` au lieu d'un
/// `m.room.message` : les ponts mautrix ne relaient que ce dernier, donc le
/// correspondant ne voit ni la question ni le brouillon qui lui répond.
/// L'aparté reste entre le Relais, ses appareils et l'agent.
public struct AgentAside: Hashable, Codable, Sendable {
  /// Le type d'event qui le porte — la même chaîne qu'`AgentWire.asideType`.
  public static let eventType = "fr.correspondance.agent.aside"

  /// Les agents nommés, par leur nom court (`cc`, `claude`).
  public var agents: [String]

  public init(agents: [String]) {
    self.agents = agents
  }

  /// « Aparté avec cc · invisible pour les autres » — sous la bulle, sur les
  /// deux plateformes.
  public var footnoteFR: String {
    let noms = agents.filter { !$0.isEmpty }
    let avec = noms.isEmpty ? "Aparté" : "Aparté avec \(noms.joined(separator: ", "))"
    return "\(avec) · invisible pour les autres"
  }
}
