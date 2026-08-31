import Foundation

/// « Archiver tout ce qui est lu » — le geste de fin de journée.
///
/// Pur, et volontairement étroit : il ne touche QUE ce qui n'a plus rien à
/// attendre. Une conversation épinglée ne s'archive jamais (c'est la promesse
/// de l'épingle), une conversation non lue non plus (l'archiver, c'est la
/// perdre sans l'avoir lue), et ce qui est déjà rangé — archivé, en rappel,
/// en demande — n'est pas dans la file.
public enum ArchiveSweep {
  /// Ce que le geste emporterait, dans l'ordre de la liste.
  public static func targets(
    _ conversations: [Conversation],
    pinned: Set<String>,
    archived: Set<String>,
    asleep: Set<String> = [],
    requests: Set<String> = []
  ) -> [Conversation] {
    conversations.filter { conversation in
      guard !archived.contains(conversation.id), !conversation.isArchived else { return false }
      guard !pinned.contains(conversation.id) else { return false }
      guard !asleep.contains(conversation.id), !requests.contains(conversation.id) else { return false }
      // Un fil de catalogue n'a jamais rien reçu : il n'y a rien à y ranger.
      guard conversation.hasLivePreview else { return false }
      return !conversation.hasUnread
    }
  }

  /// La question qu'on pose avant de le faire. Le compte y est, toujours :
  /// c'est lui qui dit si l'on s'apprête à ranger trois fils ou quarante.
  public static func confirmationFR(count: Int) -> String {
    count == 1 ? "Archiver 1 fil lu ?" : "Archiver \(count) fils lus ?"
  }
}
