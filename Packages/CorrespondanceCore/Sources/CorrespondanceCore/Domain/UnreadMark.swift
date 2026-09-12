import Foundation

/// Où s'arrête la lecture dans un fil — fonction pure, testée, sans SwiftUI.
///
/// Le Relais ne donne pas de marque de lecture par message : il donne un
/// COMPTE de messages non lus, et l'efface dès qu'on ouvre le fil. On relève
/// donc ce compte à l'ouverture (`RelayStore.unreadOnOpen`) et on le traduit
/// ici en un message précis — celui devant lequel la barre se pose, et sur
/// lequel le fil s'ouvre.
public enum UnreadMark {
  /// Le premier message non lu : celui devant lequel la barre se pose.
  ///
  /// `nil` quand il n'y a rien à marquer :
  /// - rien n'attendait ;
  /// - l'attente est plus vieille que la page chargée (`unreadCount` couvre
  ///   tout le fil visible). Une barre en tête d'un historique tronqué
  ///   mentirait : elle dirait « tout ce qui suit est neuf » d'un fil entier ;
  /// - il ne reste, dans ce qui attend, que mes propres messages — le compte
  ///   du Relais ne compte que ce qui vient des autres, et une barre posée
  ///   devant une de mes bulles n'aurait aucun sens.
  public static func firstUnreadID(messages: [ChatMessage], unreadCount: Int) -> String? {
    guard unreadCount > 0, unreadCount < messages.count else { return nil }
    let boundary = messages.count - unreadCount
    return messages[boundary...]
      .first { !$0.isFromMe && !$0.isSystemEvent }?
      .id
  }
}
