import Foundation

/// Ce que la réponse rapide ouvre, et ce vers quoi elle passe.
///
/// Le panneau ne choisit pas au hasard : il montre ce qui attend une réponse —
/// le fil non lu le plus récent. Faute de non-lu, il montre ce que l'inbox avait
/// sous les yeux ; faute de tout, le premier de la file. ⌘↑ / ⌘↓ tournent en
/// rond dans cette même file : on ne se retrouve jamais au bout de rien.
public enum QuickReplyQueue {
  /// Le fil que le panneau ouvre à froid.
  public static func defaultConversationID(in queue: [Conversation], selectedID: String?) -> String? {
    let unread = queue
      .filter { $0.unreadCount > 0 }
      .sorted { $0.lastMessageAt > $1.lastMessageAt }
    if let first = unread.first { return first.id }
    if let selectedID, queue.contains(where: { $0.id == selectedID }) { return selectedID }
    return queue.first?.id
  }

  /// ⌘↓ (`delta` = 1) ou ⌘↑ (`delta` = -1). Circulaire, et tolérant : un fil
  /// disparu de la file renvoie au premier, une file vide ne renvoie rien.
  public static func step(from current: String?, in ids: [String], by delta: Int) -> String? {
    guard !ids.isEmpty else { return nil }
    guard let current, let index = ids.firstIndex(of: current) else { return ids.first }
    let count = ids.count
    let next = ((index + delta) % count + count) % count
    return ids[next]
  }
}
