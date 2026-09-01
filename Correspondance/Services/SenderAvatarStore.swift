import Foundation
import CorrespondanceCore

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
  /// passe de placement du fil relancerait la même recherche pour rien. Mais
  /// « pas de photo » se périme — un membre arrivé au `/sync` suivant, un carnet
  /// enrichi — donc la trace porte sa date et s'efface au bout d'une minute.
  private var known: [String: Date] = [:]
  private static let negativeCacheTTL: TimeInterval = 60
  /// Photo d'un participant de salon Matrix. Le store ne connaît pas le service
  /// de pont — `InboxStore` lui prête de quoi la chercher, comme pour les portails.
  private var matrixMemberLoader: (@Sendable (String, String) async -> Data?)?

  func setMatrixMemberAvatarLoader(_ loader: @escaping @Sendable (String, String) async -> Data?) {
    matrixMemberLoader = loader
  }

  /// Même précaution que `ConversationAvatarStore` : le chargeur est posé après coup
  /// par un `Task`, et un fil ouvert dès le lancement demande ses visages avant lui.
  /// Ici l'enjeu est pire — un `nil` entre dans `known` et n'en ressort qu'à la
  /// prochaine invalidation. Attente bornée, pour ne pas suspendre un store sans pont.
  private func memberLoaderWhenReady() async -> (@Sendable (String, String) async -> Data?)? {
    for _ in 0..<50 where matrixMemberLoader == nil {
      try? await Task.sleep(for: .milliseconds(100))
    }
    return matrixMemberLoader
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
    if let missedAt = known[key] {
      if Date().timeIntervalSince(missedAt) < Self.negativeCacheTTL { return nil }
      known.removeValue(forKey: key)
    }

    let resolved: Data?
    switch network {
    // La note à soi n'a qu'un auteur, et c'est moi : rien à aller chercher.
    case .selfNote:
      resolved = nil
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
      } else if let loader = await memberLoaderWhenReady() {
        resolved = await loader(conversationID, senderID)
      } else {
        resolved = nil
      }
    }

    if let resolved {
      memory[key] = resolved
    } else {
      known[key] = Date()
    }
    return resolved
  }

  /// Une photo changée côté réseau, ou un contact enrichi : on réessaie.
  func invalidate(conversationID: String) {
    let prefix = "\(conversationID)|"
    memory = memory.filter { !$0.key.hasPrefix(prefix) }
    known = known.filter { !$0.key.hasPrefix(prefix) }
  }
}
