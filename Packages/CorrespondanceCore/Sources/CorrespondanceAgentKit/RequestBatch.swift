import Foundation

/// Les demandes qui arrivent pendant qu'un tour est en vol **s'accumulent et
/// partent ensemble**.
///
/// La garantie ne change pas — un seul tour à la fois par conversation — c'est
/// la réaction au dépassement qui change. Avant, l'agent postait « je suis
/// encore sur ta demande précédente, une à la fois » : une bulle qui **remplit
/// la file au lieu de la vider** (la règle qui domine tout le chantier agents)
/// et qui, pire, **perdait la demande** — elle n'était jamais traitée.
///
/// ## Pourquoi fusionner plutôt que répondre une fois par message
///
/// C'est le choix de `buzz-acp` : les events d'un canal s'accumulent, et quand
/// aucune requête n'est en vol, tout ce qui attend part en un seul
/// `session/prompt`. Deux messages coup sur coup coûtent alors **un** tour, pas
/// deux — c'est tout l'intérêt quand le plafond compte les tours et que chaque
/// tour coûte une fenêtre d'abonnement.
///
/// Le prix : une seule réponse pour deux questions. On l'accepte, et on borne
/// le dégât — le prompt attribue chaque message à son expéditeur pour que le
/// moteur sache qu'il en traite plusieurs, et la citation désigne le
/// **dernier**, celui auquel on s'attend à voir répondre.
public enum RequestBatch {

  /// Ce qu'on garde en attente, par conversation.
  public struct Pending: Sendable, Equatable {
    public var requests: [AgentRequest] = []

    public init(requests: [AgentRequest] = []) {
      self.requests = requests
    }

    public var isEmpty: Bool { requests.isEmpty }
  }

  /// La taille au-delà de laquelle on ne fait plus grossir le prompt. Il ne
  /// s'agit pas de jeter par principe : un lot absorbe tout ce qui attend, et
  /// cette borne n'existe que pour qu'un déluge ne fabrique pas un prompt
  /// ingérable.
  public static let tailleMax = 8_000

  /// Le lot qu'on envoie, et ce qu'on a dû laisser.
  public struct Batch: Sendable, Equatable {
    /// Le texte du tour.
    public var prompt: String
    /// La demande à citer : la **dernière**, celle à laquelle l'utilisateur
    /// s'attend à voir répondre.
    public var reply: AgentRequest
    /// Combien de demandes le lot porte.
    public var count: Int
    /// Ce qui n'a pas tenu dans la borne de taille — les plus anciennes. Se dit
    /// dans le journal, **jamais dans la conversation**.
    public var dropped: [AgentRequest]
  }

  /// Fusionne les demandes en attente d'une conversation.
  ///
  /// Une seule demande : le prompt est le sien, tel quel — le cas courant ne
  /// doit rien payer à la mécanique du lot.
  public static func merge(_ requests: [AgentRequest], tailleMax: Int = RequestBatch.tailleMax) -> Batch? {
    guard let derniere = requests.last else { return nil }
    guard requests.count > 1 else {
      return Batch(prompt: derniere.prompt, reply: derniere, count: 1, dropped: [])
    }

    // On garde les plus **récentes** : si quelque chose doit se perdre, que ce
    // soit ce qui est le plus vieux et le plus probablement dépassé.
    var gardees: [AgentRequest] = []
    var perdues: [AgentRequest] = []
    var taille = 0
    for requete in requests.reversed() {
      let cout = requete.prompt.count + 40  // l'entête « De @qui : »
      if taille + cout > tailleMax, !gardees.isEmpty {
        perdues.append(requete)
        continue
      }
      taille += cout
      gardees.append(requete)
    }
    gardees.reverse()
    perdues.reverse()

    let corps = gardees.map { requete in
      "De \(requete.sender) : \(requete.prompt)"
    }.joined(separator: "\n\n")

    let prompt = """
      Plusieurs demandes t'attendent dans cette conversation, dans l'ordre où \
      elles sont arrivées. Réponds à toutes en un seul message, brièvement, \
      sans les numéroter si ce n'est pas naturel.

      \(corps)
      """
    return Batch(prompt: prompt, reply: derniere, count: gardees.count, dropped: perdues)
  }
}
