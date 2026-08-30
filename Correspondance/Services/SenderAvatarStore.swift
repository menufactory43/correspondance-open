import Foundation

/// Le visage d'un **expéditeur**, pas d'un fil : c'est ce qu'il faut à gauche des
/// bulles d'un groupe, où chaque prise de parole a un autre auteur.
///
/// `ConversationAvatarStore` répond pour une conversation (la sidebar, la pilule) ;
/// ici on répond pour une personne dans un salon. Les deux partagent le cache
/// disque des médias : rien n'est retéléchargé deux fois.
actor SenderAvatarStore {
  static let shared = SenderAvatarStore()

  private var memory: [String: Data] = [:]
  /// Auteurs dont on sait déjà qu'on n'a pas de photo : sans cette trace, chaque
  /// passe de placement du fil relancerait la même recherche pour rien.
  private var known: Set<String> = []
  /// Photo d'un participant de salon Matrix. Le store ne connaît pas le service
  /// de pont — `InboxStore` lui prête de quoi la chercher, comme pour les portails.
  private var matrixMemberLoader: (@Sendable (String, String) async -> Data?)?

  func setMatrixMemberAvatarLoader(_ loader: @escaping @Sendable (String, String) async -> Data?) {
    matrixMemberLoader = loader
  }

  /// - Parameter conversationID: le fil **réel** de la bulle (un fil fusionné en
  ///   compte deux : c'est celui du réseau qui a parlé qui répond).
  /// - Parameter senderID: l'auteur côté réseau — un handle iMessage, un MXID.
  func imageData(
    conversationID: String,
    senderID: String?,
    network: MessageNetwork
  ) async -> Data? {
    guard let senderID, !senderID.isEmpty else { return nil }
    let key = "\(conversationID)|\(senderID)"
    if let cached = memory[key] { return cached }
    if known.contains(key) { return nil }

    let resolved: Data?
    switch network {
    case .iMessage:
      // En groupe, chat.db donne le handle de l'auteur : le carnet d'adresses
      // sait y répondre exactement comme pour un tête-à-tête.
      resolved = await ContactDirectory.shared.imageData(forHandle: senderID)
    case .signal, .whatsapp, .instagram:
      // La photo qu'on a choisie soi-même passe avant celle du réseau, comme
      // partout ailleurs — mais un ghost n'expose un numéro que rarement.
      let contact = senderID.hasPrefix("+")
        ? await ContactDirectory.shared.imageData(forHandle: senderID)
        : nil
      if let contact {
        resolved = contact
      } else if let matrixMemberLoader {
        resolved = await matrixMemberLoader(conversationID, senderID)
      } else {
        resolved = nil
      }
    }

    known.insert(key)
    if let resolved { memory[key] = resolved }
    return resolved
  }

  /// Une photo changée côté réseau, ou un contact enrichi : on réessaie.
  func invalidate(conversationID: String) {
    let prefix = "\(conversationID)|"
    memory = memory.filter { !$0.key.hasPrefix(prefix) }
    known = known.filter { !$0.hasPrefix(prefix) }
  }
}
