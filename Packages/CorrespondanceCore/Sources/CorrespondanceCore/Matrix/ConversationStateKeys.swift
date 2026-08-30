import Foundation

/// Les clés Matrix où vit l'état de conversation (ADR 0001). Un seul endroit
/// pour le vocabulaire : le Mac écrit et l'iPhone lit exactement les mêmes.
///
/// Ce qui est standard reste standard (`m.favourite`), ce qui nous appartient
/// porte notre préfixe inversé (`fr.correspondance.*`) — un autre client Matrix
/// le verra sans le comprendre, et ne l'abîmera pas.
public enum ConversationStateKeys {
  /// Room tag standard : épinglé.
  public static let favouriteTag = "m.favourite"
  /// Room tag : archivé — sorti de la file.
  public static let archivedTag = "fr.correspondance.archived"
  /// Room account data : brouillon en cours. `{ "text": "…" }`.
  public static let draftType = "fr.correspondance.draft"
  /// Room account data : messages masqués « ici ». `{ "event_ids": ["…"] }`.
  public static let hiddenType = "fr.correspondance.hidden"
  /// Account data global : les fusions de contacts, telles que le store les écrit.
  public static let mergedContactsType = "fr.correspondance.merged_contacts"
  /// Account data global : les push rules, d'où vient la sourdine.
  public static let pushRulesType = "m.push_rules"
  /// Account data de salon : les tags, tels que `/sync` les livre.
  public static let tagType = "m.tag"
}
