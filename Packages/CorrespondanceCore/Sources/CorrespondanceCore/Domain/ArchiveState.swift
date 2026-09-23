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

  /// Les membres à sortir de l'archive quand des fils se réunissent. Une ligne
  /// n'a qu'un état : si un seul membre est dehors, elle l'est, et les membres
  /// rangés doivent en sortir aussi. Sinon leur tag reste au Relais, invisible
  /// ici, et l'iPhone — qui ne voit pas le fil iMessage — tait leurs
  /// notifications sous une ligne pourtant active.
  public static func membersToUnarchiveOnMerge(
    _ memberIDs: [String],
    archivedIDs: Set<String>
  ) -> [String] {
    guard !memberIDs.allSatisfy(archivedIDs.contains) else { return [] }
    return memberIDs.filter(archivedIDs.contains)
  }

  /// Les membres sans salon (iMessage) à ranger parce qu'un autre appareil
  /// vient de ranger la ligne. L'iPhone archive tous les salons d'une ligne
  /// fusionnée, mais il ne peut rien écrire pour le fil iMessage : sans cette
  /// passe, le Mac garderait la ligne dehors pendant que l'iPhone la tait.
  ///
  /// Seul un **changement** vaut intention : tous les salons rangés, et au
  /// moins un d'entre eux depuis la dernière lecture. Un état figé ne dit
  /// rien de plus que ce que le Mac sait déjà.
  public static func localMembersToArchive(
    memberIDs: [String],
    isRelayBacked: (String) -> Bool,
    archivedBefore: Set<String>,
    archivedNow: Set<String>
  ) -> [String] {
    let rooms = memberIDs.filter(isRelayBacked)
    guard !rooms.isEmpty,
          rooms.allSatisfy(archivedNow.contains),
          rooms.contains(where: { !archivedBefore.contains($0) })
    else { return [] }
    return memberIDs.filter { !isRelayBacked($0) && !archivedNow.contains($0) }
  }
}
