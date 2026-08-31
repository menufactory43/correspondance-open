import CorrespondanceMatrixClient
import Foundation

/// D'où l'agent tient son mode de réponse, et dans quel ordre.
///
/// Quatre voix peuvent parler, et elles ne se valent pas :
///
/// 1. **la config de la room** — écrite à la main dans `config.json`, elle
///    tranche : c'est la décision la plus précise qui existe ;
/// 2. **le tête-à-tête** avec les propriétaires — personne d'autre ne lit, un
///    brouillon n'aurait personne à ménager ;
/// 3. **l'account data** `fr.correspondance.agent.settings`, écrite par l'app :
///    c'est le réglage que l'utilisateur peut changer depuis son Mac ou son
///    iPhone, sans toucher au Relais ;
/// 4. **le `defaultMode` de la config**, à défaut de tout le reste.
///
/// Fonction pure, exercée par les tests : la boucle `/sync` ne fait que lui
/// apporter ses quatre entrées.
public enum AgentMode {
  /// Le type d'account data globale où l'app écrit les réglages de l'agent.
  ///
  /// La même chaîne que `ConversationStateKeys.agentSettingsType` côté app,
  /// écrite deux fois **exprès** : l'agent ne dépend que du client Matrix,
  /// pour compiler sous Linux. Le contrat entre les deux est cette chaîne.
  public static let settingsType = "fr.correspondance.agent.settings"

  public static func resolve(
    roomMode: AgentConfig.RoomMode?,
    isPrivateWithOwners: Bool,
    accountDataDefault: AgentConfig.RoomMode?,
    configuredDefault: AgentConfig.RoomMode
  ) -> AgentConfig.RoomMode {
    if let roomMode { return roomMode }
    if isPrivateWithOwners { return .direct }
    return accountDataDefault ?? configuredDefault
  }

  /// Le mode par défaut que l'app a écrit, ou `nil` si elle n'a rien dit —
  /// jamais une valeur inventée : le silence laisse la config décider.
  public static func defaultMode(inSettings content: MatrixJSON) -> AgentConfig.RoomMode? {
    guard let raw = content.string(at: "default_mode") else { return nil }
    return AgentConfig.RoomMode(rawValue: raw)
  }

  /// Le mode par défaut porté par un `/sync`, s'il en porte un. Un `/sync`
  /// incrémental qui ne parle pas des réglages ne les efface pas : il rend
  /// `nil`, et l'appelant garde ce qu'il savait.
  public static func defaultMode(in response: MatrixSyncResponse) -> AgentConfig.RoomMode? {
    for event in response.accountData?.events ?? [] where event.type == settingsType {
      guard let content = event.content else { continue }
      return defaultMode(inSettings: content)
    }
    return nil
  }
}
