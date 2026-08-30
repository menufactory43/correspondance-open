import Foundation

/// Source de vérité de l'archivage : un ensemble d'identifiants persisté côté app.
///
/// Aucun réseau ne connaît notre archive — chaque catalogue (chat.db, les ponts,
/// `/sync` Matrix) renvoie systématiquement `isArchived: false`. La règle est donc
/// de **réappliquer** l'ensemble après chaque fusion, jamais de faire confiance à
/// ce qui remonte du transport.
enum ArchiveState {
  /// Réinstalle `isArchived` sur toute la liste. Renvoie `nil` si rien ne change,
  /// pour que l'appelant évite une ré-assignation (et une passe d'observation) inutile.
  static func normalized(_ conversations: [Conversation], archivedIDs: Set<String>) -> [Conversation]? {
    var list = conversations
    var changed = false
    for index in list.indices {
      let expected = archivedIDs.contains(list[index].id)
      if list[index].isArchived != expected {
        list[index].isArchived = expected
        changed = true
      }
    }
    return changed ? list : nil
  }
}
