import Foundation

/// Où s'arrête la lecture dans un fil — fonction pure, testée, sans SwiftUI.
///
/// Le Relais ne donne pas de marque de lecture par message : il donne un
/// COMPTE de messages non lus, et l'efface dès qu'on ouvre le fil. On relève
/// donc ce compte à l'ouverture (`RelayStore.unreadOnOpen`) et on le traduit
/// ici en un message précis — celui devant lequel la barre se pose, et sur
/// lequel le fil s'ouvre.
public enum UnreadMark {
  /// La barre : devant quel message elle se pose, et ce qu'elle annonce.
  public struct Mark: Equatable, Sendable {
    /// Le premier message non lu.
    public let messageID: String
    /// Ce qui attend SOUS la barre. Pas toujours le compte du Relais : voir
    /// `place(in:unreadCount:)`. La barre dit ce qu'il y a dessous, sinon
    /// elle ment.
    public let count: Int

    public init(messageID: String, count: Int) {
      self.messageID = messageID
      self.count = count
    }
  }

  /// Pose la barre, en REMONTANT le fil depuis la fin.
  ///
  /// Surtout pas en coupant à `messages.count - unreadCount` : le compte du
  /// Relais ne compte que les messages REÇUS, là où la liste porte aussi mes
  /// propres bulles, les événements de groupe et les cartes de l'agent. Sur un
  /// fil qui finit par un mot de moi, l'arithmétique posait la barre devant ce
  /// mot — vu en démonstration, six non lus annoncés au-dessus d'une seule
  /// carte d'agent. On remonte donc en ne comptant que ce qui compte :
  ///
  /// - les événements de groupe et les cartes de l'agent se sautent — ils ne
  ///   sont pas des messages reçus ;
  /// - un message de moi ARRÊTE la remontée : rien au-dessus de mon dernier
  ///   mot n'attend plus une lecture ;
  /// - si la page chargée porte moins de messages reçus que le Relais n'en
  ///   annonce, la barre se pose devant le plus ancien qu'on ait, et annonce
  ///   CE nombre-là. Dire « 12 » au-dessus de trois bulles serait faux.
  ///
  /// `nil` quand il n'y a rien à marquer : rien n'attendait, rien de reçu dans
  /// ce qui attend, ou la barre se poserait en tête d'un historique tronqué —
  /// elle dirait alors « tout ce qui suit est neuf » d'un fil entier.
  public static func place(in messages: [ChatMessage], unreadCount: Int) -> Mark? {
    guard unreadCount > 0 else { return nil }
    var found = 0
    var candidate: String?
    for message in messages.reversed() {
      if message.isSystemEvent || message.isAgentProposal { continue }
      if message.isFromMe { break }
      candidate = message.id
      found += 1
      if found == unreadCount { break }
    }
    guard let candidate, found > 0 else { return nil }
    // Toute la page est neuve : une barre en tête n'apprend rien et fait
    // croire à un fil entièrement non lu.
    guard candidate != messages.first?.id else { return nil }
    return Mark(messageID: candidate, count: found)
  }
}
