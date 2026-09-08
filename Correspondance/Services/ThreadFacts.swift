import Foundation
import CorrespondanceCore

/// Ce que le fil ouvert a besoin de savoir de sa conversation — et **rien** de
/// ce qu'un `/sync` fait bouger.
///
/// `conversations` se réécrit toutes les quelques secondes : un aperçu, un
/// compteur, « écrit… ». Tant que `ThreadView` lisait `selectedConversation`
/// (calculée dessus), chaque `/sync` refaisait son corps et remettait en page
/// les cent cinquante rangées — 250 ms au Time Profiler, un gel en plein
/// défilement. Ici : une valeur comparable, réassignée par le magasin
/// seulement quand elle change vraiment. Un `/sync` ordinaire ne touche plus
/// au fil.
struct ThreadFacts: Equatable {
  /// La ligne ouverte, débarrassée de ce qui bouge (`faceOnly`).
  var row: Conversation
  /// Sur une ligne fusionnée : ses membres, sous la même forme.
  var members: [Conversation] = []
  /// Le membre où l'on écrit, sur une ligne fusionnée.
  var activeMemberID: String?
  /// L'accusé du dernier message — il change quand il change, et c'est légitime.
  var lastDelivery: MessageDelivery?

  var isGroup: Bool { row.isGroup }

  /// Le fil où l'on écrit : le membre actif d'une ligne fusionnée, sinon la ligne.
  var sendingConversation: Conversation {
    members.first { $0.id == activeMemberID } ?? members.first ?? row
  }

  /// Renommer, ajouter, retirer : ce que le réseau du groupe permet — le même
  /// jugement que `InboxStore.canManageGroup`, sans relire `conversations`.
  var canManageGroup: Bool {
    guard row.isGroup, row.network.livesOnRelay else { return false }
    let capabilities = row.network.capabilities
    return capabilities.renamesGroup || capabilities.removesMember || capabilities.addsMember
  }

  /// Le fil réel d'une bulle — le même choix que `InboxStore.conversation(ofMessage:in:)`.
  func face(forMessage message: ChatMessage) -> Conversation? {
    if row.id == message.conversationID { return row }
    if !members.isEmpty {
      if let member = members.first(where: { $0.id == message.conversationID }) { return member }
      return members.first { $0.id == activeMemberID } ?? members.first
    }
    return row
  }
}
