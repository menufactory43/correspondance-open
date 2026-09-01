import CorrespondanceMatrixClient
import Foundation

/// Un **atelier** : un salon où plusieurs agents et des humains travaillent sur
/// un sujet. La troisième forme, après la console (toi + un bot, pour le régler)
/// et le tête-à-tête (toi + un bot, pour lui parler).
///
/// Il n'est dangereux que par ses boucles : deux agents qui se répondent
/// brûlent une fenêtre d'abonnement en une nuit. Quatre règles suffisent, et
/// elles sont ici parce qu'elles se testent :
///
/// 1. **mention obligatoire** — aucun agent ne répond à un message qui ne le
///    nomme pas ;
/// 2. **un agent ne déclenche pas un agent**, sauf délégation nommée par un
///    propriétaire, profondeur 1 ;
/// 3. **un thread par tour** — le travail se déroule dans le thread, seul le
///    résultat remonte ;
/// 4. **un budget de tours par salon**, en plus du plafond par agent.
public enum Atelier {

  /// Ce qu'on sait d'un salon au moment de décider.
  public struct Context: Sendable, Equatable {
    /// Les agents présents, par leur MXID.
    public var agents: Set<String>
    /// Les propriétaires.
    public var owners: Set<String>
    /// Combien de tours ce salon a déjà consommés dans l'heure.
    public var turnsThisHour: Int
    /// Le budget du salon.
    public var budget: Int

    public init(agents: Set<String> = [], owners: Set<String> = [], turnsThisHour: Int = 0, budget: Int = 20) {
      self.agents = agents
      self.owners = owners
      self.turnsThisHour = turnsThisHour
      self.budget = budget
    }
  }

  public enum Decision: Equatable, Sendable {
    /// L'agent répond. `delegated` : ce tour vient d'une délégation nommée, il
    /// ne pourra pas en déclencher une autre.
    case respond(delegated: Bool)
    case ignore(Reason)

    public enum Reason: String, Equatable, Sendable {
      /// Personne ne m'a nommé — dans un atelier, on ne répond pas au bruit.
      case notMentioned
      /// Un agent parle, et il ne m'a pas été délégué par un propriétaire.
      case agentSpeaking
      /// Une délégation déléguée : profondeur 1, pas deux.
      case delegationTooDeep
      /// Le salon a consommé son budget.
      case budgetSpent
      /// L'expéditeur n'a pas le droit de me déclencher.
      case notAnOwner
    }
  }

  /// Décide si `agent` doit répondre à ce message dans cet atelier.
  ///
  /// `isDelegation` : le message vient d'un agent *et* un propriétaire l'a
  /// nommément chargé de déléguer (« @cc demande à @hermes de… »). C'est le
  /// seul cas où un agent en réveille un autre.
  public static func decide(
    agent: String,
    sender: String,
    body: String,
    trigger: String,
    context: Context,
    isDelegation: Bool = false,
    delegationDepth: Int = 0
  ) -> Decision {
    guard context.turnsThisHour < context.budget else { return .ignore(.budgetSpent) }
    guard mentions(agent: agent, trigger: trigger, in: body) else { return .ignore(.notMentioned) }

    let senderIsAgent = context.agents.contains(sender)
    if senderIsAgent {
      guard isDelegation else { return .ignore(.agentSpeaking) }
      guard delegationDepth < 1 else { return .ignore(.delegationTooDeep) }
      return .respond(delegated: true)
    }
    guard context.owners.contains(sender) else { return .ignore(.notAnOwner) }
    return .respond(delegated: false)
  }

  /// L'agent est-il nommé ? Son déclencheur (`@cc`) ou son MXID complet, et
  /// **n'importe où dans le message** — contrairement au tête-à-tête, où le
  /// déclencheur doit ouvrir la phrase : dans un atelier, « demande à @cc de
  /// regarder » est un appel parfaitement clair.
  public static func mentions(agent: String, trigger: String, in body: String) -> Bool {
    let texte = body.lowercased()
    if texte.contains(agent.lowercased()) { return true }
    let mot = trigger.lowercased()
    guard !mot.isEmpty, let plage = texte.range(of: mot) else { return false }
    // `@ccc` n'est pas `@cc`.
    let apres = plage.upperBound
    if apres < texte.endIndex {
      let suivant = texte[apres]
      if suivant.isLetter || suivant.isNumber { return false }
    }
    return true
  }

  /// Une délégation nommée par un propriétaire : « @cc demande à @hermes de… ».
  /// On ne cherche pas à comprendre la phrase — on repère qu'un propriétaire
  /// charge un agent d'en appeler un autre, et c'est tout ce dont on a besoin.
  public static func delegationTarget(in body: String, among agents: Set<String>, triggers: [String: String]) -> String? {
    let texte = body.lowercased()
    // La cible est nommée **après** la formule : dans « @cc demande à @hermes
    // de… », c'est hermes, et cc est celui qui délègue. Chercher n'importe
    // quelle mention rendrait cc cible de sa propre délégation.
    let formules = ["demande à", "demande a", "passe à", "passe a", "demandez à"]
    guard let apres = formules.compactMap({ texte.range(of: $0)?.upperBound }).min() else { return nil }
    let suite = String(texte[apres...])

    // Le premier agent nommé dans la suite gagne — deux mentions dans la même
    // phrase resteraient ambiguës, et on ne devine pas.
    var meilleure: (agent: String, position: String.Index)?
    for agent in agents {
      let trigger = (triggers[agent] ?? agent).lowercased()
      let position = suite.range(of: agent.lowercased())?.lowerBound
        ?? suite.range(of: trigger)?.lowerBound
      guard let position else { continue }
      if meilleure == nil || position < meilleure!.position {
        meilleure = (agent, position)
      }
    }
    return meilleure?.agent
  }
}
