import CorrespondanceMatrixClient
import Foundation

/// Le journal des tours — **un garde-fou, pas une commodité**.
///
/// Depuis la pleine permission, trois choses seulement bornent ce qu'un agent
/// peut faire : le dossier de la room, les propriétaires seuls, et ce journal.
/// C'est ce qui sépare « cet agent a fait ça » de « quelque chose a été posté
/// sous ce nom ».
///
/// D'où la règle qui gouverne ce fichier : **un garde-fou qui ne peut pas
/// s'exercer doit le dire.** Il n'a pas le droit de sortir par un `return`
/// muet. Trois fois de suite, le même motif a coûté cher — l'app affirmait
/// « actif » sans preuve, le journal envoyait un flottant et avalait le 400,
/// puis il sortait par un `guard` sans un mot. Ici, l'impossibilité est une
/// valeur de retour, pas un silence.
public struct AgentJournal: Sendable {
  /// Où poster. `nil` : pas de console, donc pas de journal — et ça se dit.
  public var consoleRoomID: String?
  /// L'effet. Injectable : les tests éprouvent qu'un event part vraiment,
  /// avec le bon contenu, sans Relais.
  public var post: @Sendable (_ roomID: String, _ type: String, _ content: MatrixJSON) async throws -> Void

  public init(
    consoleRoomID: String?,
    post: @escaping @Sendable (String, String, MatrixJSON) async throws -> Void
  ) {
    self.consoleRoomID = consoleRoomID
    self.post = post
  }

  public enum Outcome: Equatable, Sendable {
    case written(roomID: String)
    /// Le garde-fou n'a pas pu s'exercer, et voici pourquoi — en français,
    /// pour le journal local et pour l'écran des réglages.
    case impossible(raison: String)
  }

  /// La raison qu'on affiche quand il n'y a pas de console. Elle nomme la
  /// conséquence, pas seulement la cause : sans journal, plus rien ne relit ce
  /// que l'agent a fait.
  public static let sansConsole =
    "pas de room console : les tours ne sont journalisés nulle part. "
      + "Ouvre-la depuis Réglages › Agent (« Activer cc ») — sans elle, plus rien ne relit "
      + "ce que cc fait, alors qu'il a tous ses outils."

  @discardableResult
  public func record(
    agent: String, roomID: String, sender: String, prompt: String,
    tools: [String], seconds: Double, tokens: Int?
  ) async -> Outcome {
    guard let consoleRoomID else { return .impossible(raison: Self.sansConsole) }
    let content = AgentEvents.journal(
      agent: agent, roomID: roomID, sender: sender, prompt: prompt,
      tools: tools, seconds: seconds, tokens: tokens
    )
    do {
      try await post(consoleRoomID, AgentEvents.journalType, content)
      return .written(roomID: consoleRoomID)
    } catch {
      // Une erreur d'écriture se dit aussi : c'est elle qui avait disparu quand
      // le journal envoyait un flottant.
      return .impossible(raison: "journal impostable : \(error.localizedDescription)")
    }
  }
}
