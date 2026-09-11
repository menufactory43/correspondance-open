import Foundation

/// Source de vérité de l'archivage : un ensemble d'identifiants persisté côté app.
///
/// Aucun réseau ne connaît notre archive — chaque catalogue (chat.db, les ponts,
/// `/sync` Matrix) renvoie systématiquement `isArchived: false`. La règle est donc
/// de **réappliquer** l'ensemble après chaque fusion, jamais de faire confiance à
/// ce qui remonte du transport.
public enum ArchiveState {
  /// Réinstalle `isArchived` sur toute la liste. Renvoie `nil` si rien ne change,
  /// pour que l'appelant évite une ré-assignation (et une passe d'observation) inutile.
  ///
  /// - Parameter mergedMembers: pour chaque ligne fusionnée, les identifiants de
  ///   ses membres. Une ligne fusionnée n'a pas d'archive à elle : elle est
  ///   rangée quand **tous** ses fils le sont — la même règle que
  ///   `MergedContact.row(from:)`. Deux règles différentes ici et là faisaient
  ///   ping-pong dans le `didSet` de la liste jusqu'à épuiser la pile.
  public static func normalized(
    _ conversations: [Conversation],
    archivedIDs: Set<String>,
    mergedMembers: [String: [String]] = [:]
  ) -> [Conversation]? {
    var list = conversations
    var changed = false
    for index in list.indices {
      let expected = isArchived(list[index].id, archivedIDs: archivedIDs, mergedMembers: mergedMembers)
      if list[index].isArchived != expected {
        list[index].isArchived = expected
        changed = true
      }
    }
    return changed ? list : nil
  }

  /// L'état d'archive d'un identifiant : le sien pour un fil, celui de tous
  /// ses membres pour une ligne fusionnée.
  public static func isArchived(
    _ id: String,
    archivedIDs: Set<String>,
    mergedMembers: [String: [String]] = [:]
  ) -> Bool {
    if let members = mergedMembers[id], !members.isEmpty {
      return members.allSatisfy(archivedIDs.contains)
    }
    return archivedIDs.contains(id)
  }
}
