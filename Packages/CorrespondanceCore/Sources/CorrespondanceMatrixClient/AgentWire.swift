import Foundation

/// Le format de fil entre l'app et l'agent : les types d'events et le nom de
/// leurs champs.
///
/// Il vit ici, dans le client Matrix, parce que **les deux côtés en ont besoin
/// et qu'aucun des deux ne peut dépendre de l'autre** : l'app tourne sur iOS,
/// où `Process` n'existe pas, donc `CorrespondanceCore` ne peut pas dépendre de
/// `CorrespondanceAgentKit` ; et l'agent tourne sous Linux, sans SwiftUI, donc
/// il ne peut pas dépendre de `CorrespondanceCore`.
///
/// Une seule définition des clés, donc, et pas deux qui divergent au premier
/// champ ajouté. Les ponts mautrix ne relaient aucun de ces types : ce qui s'y
/// dit reste entre le Relais et ses clients.
public enum AgentWire {

  // MARK: - Types d'events

  /// Ce que l'agent propose, et que l'app rend en brouillon.
  public static let proposalType = "fr.correspondance.agent.proposal"
  /// Une demande d'outil. Conservée pour les agents d'avant la pleine
  /// permission ; plus rien ne l'émet côté ACP.
  public static let permissionType = "fr.correspondance.agent.permission"
  /// Ce que l'agent sait de sa machine : « cc tourne sur umbrel depuis 14 h 02 ».
  public static let statusType = "fr.correspondance.agent.status"
  /// La configuration de l'agent — event **d'état** de sa room console.
  public static let configType = "fr.correspondance.agent.config"
  /// Un tour journalisé : qui, quoi, quels outils, combien de temps.
  public static let journalType = "fr.correspondance.agent.journal"

  // MARK: - Champs

  /// Les clés de `fr.correspondance.agent.config`. La version du schéma est
  /// dans `version` : un agent plus vieux que l'event refuse de le lire plutôt
  /// que d'en deviner la moitié.
  public enum ConfigKey {
    public static let version = "version"
    public static let agent = "agent"
    public static let owners = "owners"
    public static let trigger = "trigger"
    public static let hourlyCap = "hourlyCap"
    public static let defaultMode = "defaultMode"
    public static let backend = "backend"
    public static let toolPreset = "toolPreset"
    public static let model = "model"
    public static let systemPrompt = "systemPrompt"
    public static let rooms = "rooms"
    public static let acpCommand = "acpCommand"
    /// Les arguments de l'adaptateur : `gemini --acp`, `grok agent stdio`,
    /// `goose acp` — le binaire seul ouvre une interface interactive, pas un
    /// serveur ACP. Absent : l'agent applique ce qu'il sait de la commande.
    public static let acpArguments = "acpArguments"
    /// Les autres agents du Relais, par leur MXID. C'est ce qui fait d'un salon
    /// un **atelier** : la mention devient obligatoire, et un agent ne relance
    /// pas un agent.
    public static let peers = "peers"
    /// Dans chaque entrée de `rooms`.
    public static let roomCwd = "cwd"
    public static let roomMode = "mode"
  }

  /// Les clés de `fr.correspondance.agent.status`, au-delà du texte lisible.
  /// La machine et le pid sont ce qui permet de refuser un second agent sur le
  /// même compte — deux agents, ce sont deux réponses à chaque message.
  public enum StatusKey {
    public static let host = "host"
    public static let pid = "pid"
  }

  /// Le nom court de cette machine : `umbrel`, pas `umbrel.local`.
  public static var hostName: String {
    let nom = ProcessInfo.processInfo.hostName
    return nom.split(separator: ".").first.map(String.init) ?? nom
  }

  /// Les clés de `fr.correspondance.agent.journal`.
  public enum JournalKey {
    public static let agent = "agent"
    public static let room = "room"
    public static let sender = "sender"
    public static let prompt = "prompt"
    public static let tools = "tools"
    /// La durée du tour, en **millisecondes entières**. Jamais des secondes
    /// décimales : Matrix refuse les flottants, et c'est ce qui a empêché le
    /// journal de s'écrire pendant tout ce temps. Les millisecondes gardent la
    /// précision d'un tour court sans jamais produire de virgule.
    public static let durationMs = "duration_ms"
    public static let tokens = "tokens"
  }

  /// La version courante du schéma de configuration.
  public static let configVersion = 1
}
