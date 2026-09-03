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
    /// Le nom sous lequel on appelle chaque agent (`@cc`), quand il diffère de
    /// `@` + son nom court. Sans entrée, c'est le nom court qui fait foi.
    public var triggers: [String: String]
    /// L'agent **à qui est** ce salon — un fil ouvert pour lui par l'app, où
    /// un second agent a été invité. C'est lui qui répond à ce qui ne nomme
    /// personne ; l'autre attend qu'on l'appelle. `nil` : un atelier ordinaire,
    /// où personne ne répond au bruit.
    public var host: String?

    public init(
      agents: Set<String> = [], owners: Set<String> = [], turnsThisHour: Int = 0, budget: Int = 20,
      triggers: [String: String] = [:], host: String? = nil
    ) {
      self.agents = agents
      self.owners = owners
      self.turnsThisHour = turnsThisHour
      self.budget = budget
      self.triggers = triggers
      self.host = host
    }

    /// Le nom court d'un agent, tel qu'on l'appelle : `@cc` → `cc`.
    func shortName(of agent: String) -> String {
      if let trigger = triggers[agent] { return trigger.hasPrefix("@") ? String(trigger.dropFirst()) : trigger }
      let local = agent.hasPrefix("@") ? String(agent.dropFirst()) : agent
      return local.split(separator: ":").first.map(String.init) ?? local
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
    var contexte = context
    contexte.triggers[agent] = trigger
    let destinataires = addressees(in: body, context: contexte)
    if destinataires.isEmpty {
      // Personne n'est nommé. Dans un fil qui est à moi, c'est à moi qu'on
      // parle — l'autre agent invité attend qu'on l'appelle. Ailleurs, c'est
      // du bruit : on ne répond pas.
      guard contexte.host == agent, !context.agents.contains(sender) else { return .ignore(.notMentioned) }
      guard context.owners.contains(sender) else { return .ignore(.notAnOwner) }
      return .respond(delegated: false)
    }
    guard destinataires.contains(agent) else { return .ignore(.notMentioned) }

    let senderIsAgent = context.agents.contains(sender)
    if senderIsAgent {
      guard isDelegation else { return .ignore(.agentSpeaking) }
      guard delegationDepth < 1 else { return .ignore(.delegationTooDeep) }
      return .respond(delegated: true)
    }
    guard context.owners.contains(sender) else { return .ignore(.notAnOwner) }
    return .respond(delegated: false)
  }

  /// À qui ce message s'adresse, parmi les agents du salon.
  ///
  /// Ceux qui **ouvrent** la phrase sont les destinataires, et eux seuls :
  /// « @cc dis à @claude de faire un test » parle à cc, de claude — claude ne
  /// répond pas, c'est à cc de le charger. « @claude @cc vous allez bien ? »
  /// s'adresse aux deux. Sans agent en tête, tous ceux qui sont nommés sont
  /// appelés : « hey @cc et @claude, un avis ? ». C'est ce qui fait qu'une
  /// mention n'apporte qu'**une** réponse, jamais deux pour la même phrase.
  public static func addressees(in body: String, context: Context) -> Set<String> {
    let noms = Dictionary(uniqueKeysWithValues: context.agents.map { (context.shortName(of: $0), $0) })
    // Le MXID complet vaut mention, comme avant.
    let texte = body.lowercased()
    var parMXID: Set<String> = []
    for agent in context.agents where texte.contains(agent.lowercased()) { parMXID.insert(agent) }
    let parNom = AgentWire.agentsAddressed(in: body, among: Array(noms.keys)).compactMap { noms[$0] }
    return parMXID.union(parNom)
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
