import Foundation

/// Applique un payload `/sync` sur un ensemble de salons. Pur et déterministe.
struct MatrixSyncParser: Sendable {
  /// Types d'état portant l'information de bridge, du plus récent au plus ancien.
  static let bridgeStateTypes = ["m.bridge", "fi.mau.bridge", "uk.half-shot.bridge"]

  let selfUserID: String

  init(selfUserID: String) {
    self.selfUserID = selfUserID
  }

  /// Fusionne le sync dans `rooms` (mutation en place, appels successifs cumulatifs).
  func apply(_ response: MatrixSyncResponse, to rooms: inout [String: MatrixRoomModel]) {
    guard let joined = response.rooms?.join else { return }
    for (roomID, room) in joined {
      var model = rooms[roomID] ?? MatrixRoomModel(roomID: roomID)
      for event in (room.state?.events ?? []) { applyState(event, to: &model) }
      for event in (room.timeline?.events ?? []) {
        applyState(event, to: &model)
        applyMessage(event, roomID: roomID, to: &model)
      }
      if let heroes = room.summary?.heroes { model.heroes = heroes }
      if let count = room.unreadNotifications?.notificationCount { model.unreadCount = count }
      rooms[roomID] = model
    }
    // Un salon quitté disparaît de l'inbox.
    for roomID in (response.rooms?.leave?.keys ?? [:].keys) {
      rooms.removeValue(forKey: roomID)
    }
  }

  /// Messages d'un `GET /rooms/{id}/messages` (pagination arrière) fusionnés dans le salon.
  func applyMessages(_ events: [MatrixEvent], roomID: String, to model: inout MatrixRoomModel) {
    for event in events {
      applyState(event, to: &model)
      applyMessage(event, roomID: roomID, to: &model)
    }
  }

  // MARK: - État

  private func applyState(_ event: MatrixEvent, to model: inout MatrixRoomModel) {
    guard let content = event.content else { return }
    switch event.type {
    case "m.room.name":
      if let name = content.string(at: "name") { model.explicitName = name }

    case "m.room.member":
      guard let userID = event.stateKey else { return }
      let membership = content.string(at: "membership") ?? "leave"
      let displayName = content.string(at: "displayname")
      // Un `leave` ne doit pas effacer le nom déjà connu (on garde l'historique lisible).
      var member = model.members[userID] ?? MatrixRoomModel.Member(displayName: nil, membership: membership)
      member.membership = membership
      if let displayName { member.displayName = displayName }
      model.members[userID] = member
      if model.bridgePhoneNumber == nil,
         !MatrixIdentity.isBridgeBot(userID),
         userID != selfUserID,
         let phone = MatrixIdentity.phoneNumber(in: displayName)
      {
        model.bridgePhoneNumber = phone
      }

    case let type where Self.bridgeStateTypes.contains(type):
      applyBridge(content, to: &model)

    default:
      break
    }
    if event.type.hasPrefix("m.room."), event.sentAt > model.lastEventAt {
      model.lastEventAt = event.sentAt
    }
  }

  private func applyBridge(_ content: MatrixJSON, to model: inout MatrixRoomModel) {
    if let protocolID = content.string(at: "protocol.id"),
       let network = MessageNetwork.fromBridgeProtocol(protocolID)
    {
      model.network = network
    }
    if let channelName = content.string(at: "channel.displayname") {
      model.bridgeChannelName = channelName
    }
    // Le bridge peut exposer le numéro (`channel.id` en JID, ou un extra explicite).
    // On ne prend que ce qui ressemble vraiment à un numéro ; sinon on s'en passe.
    if model.bridgePhoneNumber == nil {
      let candidates = [
        content.string(at: "channel.id"),
        content.string(at: "channel.external_url"),
        content.string(at: "fi.mau.whatsapp.phone_number"),
        content.string(at: "com.beeper.phone_number"),
      ]
      for candidate in candidates {
        // `33612345678@s.whatsapp.net` → on ne garde que la partie avant l'arobase.
        let head = candidate?.split(separator: "@").first.map(String.init)
        if let phone = MatrixIdentity.phoneNumber(in: head) {
          model.bridgePhoneNumber = phone
          break
        }
      }
    }
  }

  // MARK: - Messages

  private func applyMessage(_ event: MatrixEvent, roomID: String, to model: inout MatrixRoomModel) {
    guard event.type == "m.room.message",
          let eventID = event.eventID,
          let content = event.content
    else { return }
    // Les éditions arrivent en double du message d'origine — on garde l'original.
    if content.string(at: "m.relates_to.rel_type") == "m.replace" { return }

    let network = model.network ?? .whatsapp
    let msgtype = content.string(at: "msgtype") ?? "m.text"
    let body = content.string(at: "body") ?? ""
    var text = ""
    var attachments: [MessageAttachment] = []

    switch msgtype {
    case "m.image", "m.video", "m.file", "m.audio":
      if let mxc = content.string(at: "url") {
        attachments.append(
          MessageAttachment(
            id: mxc,
            contentType: content.string(at: "info.mimetype") ?? Self.fallbackMime(for: msgtype),
            filename: body.isEmpty ? nil : body,
            localPath: MatrixAttachmentStore.existingLocalPath(forMXC: mxc)
          )
        )
      } else {
        text = body
      }
    default:
      text = body
    }

    let message = ChatMessage(
      id: eventID,
      conversationID: model.conversationID,
      network: network,
      text: text,
      sentAt: event.sentAt,
      isFromMe: event.sender == selfUserID,
      attachments: attachments
    )
    guard message.hasVisibleBody else { return }
    model.messagesByID[eventID] = message
    if event.sentAt > model.lastEventAt { model.lastEventAt = event.sentAt }
  }

  private static func fallbackMime(for msgtype: String) -> String {
    switch msgtype {
    case "m.image": "image/jpeg"
    case "m.video": "video/mp4"
    case "m.audio": "audio/ogg"
    default: "application/octet-stream"
    }
  }
}
