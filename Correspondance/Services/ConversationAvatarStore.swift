import AppKit
import Foundation

/// Résout les photos de profil / groupes (portails Matrix + Contacts iMessage).
actor ConversationAvatarStore {
  static let shared = ConversationAvatarStore()

  private var memory: [String: Data] = [:]
  /// Téléchargement d'une photo de portail Matrix. Le store ne connaît pas le
  /// service de pont — `InboxStore` lui passe la closure au démarrage du `/sync`,
  /// ce qui laisse le store testable sans homeserver.
  private var matrixAvatarLoader: (@Sendable (String) async -> Data?)?

  func setMatrixAvatarLoader(_ loader: @escaping @Sendable (String) async -> Data?) {
    matrixAvatarLoader = loader
  }

  func imageData(for conversation: Conversation) async -> Data? {
    if let cached = memory[conversation.id] { return cached }

    let resolved: Data?
    switch conversation.network {
    case .iMessage:
      // Un groupe iMessage porte sa propre photo (chat.properties → pièce jointe) ;
      // le carnet d'adresses ne sait répondre que pour un tête-à-tête.
      if let groupPhoto = loadGroupPhotoData(for: conversation) {
        resolved = groupPhoto
      } else {
        resolved = await ContactDirectory.shared.imageData(for: conversation)
      }
    case .signal, .whatsapp, .instagram:
      // Fil bridgé : d'abord le carnet d'adresses si le pont a exposé un numéro —
      // la photo qu'on a choisie soi-même vaut mieux que celle du réseau. Sinon la
      // photo du portail (`m.room.avatar`), seule image dont dispose un fil Instagram.
      let contact = conversation.address.hasPrefix("+")
        ? await ContactDirectory.shared.imageData(forHandle: conversation.address)
        : nil
      if let contact {
        resolved = contact
      } else if let mxc = conversation.remoteAvatarID, let matrixAvatarLoader {
        resolved = await matrixAvatarLoader(mxc)
      } else if !conversation.memberAvatarIDs.isEmpty, let matrixAvatarLoader {
        resolved = await mosaicData(forMembers: conversation.memberAvatarIDs, loader: matrixAvatarLoader)
      } else {
        resolved = nil
      }
    }

    if let resolved {
      memory[conversation.id] = resolved
    }
    return resolved
  }

  /// Groupe sans photo à lui : on montre les visages, comme Messages et Instagram.
  /// Chaque photo passe par le même chargeur (donc le même cache disque) qu'un
  /// avatar de portail ; seule la composition est nouvelle, et elle sort en PNG
  /// pour rester dans le contrat `Data?` du store.
  ///
  /// Le liseré prend la couleur de fenêtre : la vignette est un bitmap figé, il ne
  /// se reteindra pas si l'apparence système change en cours de route.
  private func mosaicData(
    forMembers ids: [String],
    loader: @Sendable (String) async -> Data?
  ) async -> Data? {
    var images: [NSImage] = []
    for id in ids {
      guard let data = await loader(id), let image = NSImage(data: data) else { continue }
      images.append(image)
    }
    return AvatarMosaic.compose(images, size: 44, separator: .windowBackgroundColor)
  }

  func invalidate(conversationID: String) {
    memory.removeValue(forKey: conversationID)
  }

  /// Le visage d'une ligne fusionnée : celui du fil choisi à la fusion.
  /// La ligne virtuelle n'a ni carnet d'adresses ni fichier sur disque — elle
  /// emprunte l'image déjà résolue de l'un de ses membres.
  func adopt(mergedID: String, from source: Conversation) async {
    guard let data = await imageData(for: source) else {
      memory.removeValue(forKey: mergedID)
      return
    }
    memory[mergedID] = data
  }

  /// Photo de groupe déjà localisée par `IMessageDatabase`.
  private func loadGroupPhotoData(for conversation: Conversation) -> Data? {
    guard let path = conversation.groupPhotoPath, !path.isEmpty else { return nil }
    return try? Data(contentsOf: URL(fileURLWithPath: path))
  }

}
