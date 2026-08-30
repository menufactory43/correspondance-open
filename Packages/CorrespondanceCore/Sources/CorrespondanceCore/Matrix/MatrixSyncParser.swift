import Foundation

/// Applique un payload `/sync` sur un ensemble de salons. Pur et déterministe.
public struct MatrixSyncParser: Sendable {
  /// Types d'état portant l'information de bridge, du plus récent au plus ancien.
  public static let bridgeStateTypes = ["m.bridge", "fi.mau.bridge", "uk.half-shot.bridge"]

  public let selfUserID: String

  public init(selfUserID: String) {
    self.selfUserID = selfUserID
  }

  /// Fusionne le sync dans `rooms` (mutation en place, appels successifs cumulatifs).
  public func apply(_ response: MatrixSyncResponse, to rooms: inout [String: MatrixRoomModel]) {
    guard let joined = response.rooms?.join else { return }
    for (roomID, room) in joined {
      var model = rooms[roomID] ?? MatrixRoomModel(roomID: roomID)
      for event in (room.state?.events ?? []) { applyState(event, to: &model) }
      for event in (room.timeline?.events ?? []) {
        applyState(event, to: &model)
        applyMessage(event, roomID: roomID, to: &model)
        applyReaction(event, to: &model)
        applyRedaction(event, to: &model)
      }
      for event in (room.ephemeral?.events ?? []) { applyReceipt(event, to: &model) }
      if let heroes = room.summary?.heroes { model.heroes = heroes }
      if let count = room.unreadNotifications?.notificationCount { model.unreadCount = count }
      rooms[roomID] = model
    }
    // Un salon quitté disparaît de l'inbox.
    for roomID in (response.rooms?.leave?.keys ?? [:].keys) {
      rooms.removeValue(forKey: roomID)
    }
  }

  /// Fusionne l'état de conversation porté par le `/sync` (tags, push rules,
  /// account data). Séparé de `apply` : les salons vivent dans le modèle,
  /// l'état de conversation vit dans son propre instantané, que l'inbox garde.
  public func applyConversationState(
    _ response: MatrixSyncResponse,
    to snapshot: inout ConversationStateSnapshot
  ) {
    snapshot.apply(response)
  }

  /// Réinstalle l'historique du cache disque dans les salons, **avant** le premier
  /// `/sync`. Sans ce semis, le sync initial — dix events par salon chez Synapse —
  /// réécrivait le cache avec un modèle presque vide, et tout ce que les sessions
  /// précédentes avaient backfillé disparaissait à chaque relance de l'app.
  ///
  /// Le `/sync` qui suit fusionne par identifiant d'event : rien ne se duplique.
  /// Un envoi resté en attente au moment de quitter n'est pas repris — il n'a
  /// jamais existé côté serveur.
  public func seed(cachedMessages: [String: [ChatMessage]], into rooms: inout [String: MatrixRoomModel]) {
    for (conversationID, list) in cachedMessages {
      guard let roomID = Self.roomID(inConversationID: conversationID) else { continue }
      var model = rooms[roomID] ?? MatrixRoomModel(roomID: roomID)
      for message in list where !message.isPending && model.messagesByID[message.id] == nil {
        model.messagesByID[message.id] = message
        model.lastEventAt = max(model.lastEventAt, message.sentAt)
      }
      rooms[roomID] = model
    }
  }

  /// Inverse de `MatrixRoomModel.conversationID` (`réseau:!salon:serveur`) : le
  /// salon commence au premier `:`, ce qui suit en contient d'autres.
  public static func roomID(inConversationID conversationID: String) -> String? {
    guard let colon = conversationID.firstIndex(of: ":") else { return nil }
    let roomID = String(conversationID[conversationID.index(after: colon)...])
    return roomID.hasPrefix("!") ? roomID : nil
  }

  /// Messages d'un `GET /rooms/{id}/messages` (pagination arrière) fusionnés dans le salon.
  public func applyMessages(_ events: [MatrixEvent], roomID: String, to model: inout MatrixRoomModel) {
    for event in events {
      applyState(event, to: &model)
      applyMessage(event, roomID: roomID, to: &model)
      applyReaction(event, to: &model)
      applyRedaction(event, to: &model)
    }
  }

  // MARK: - État

  private func applyState(_ event: MatrixEvent, to model: inout MatrixRoomModel) {
    guard let content = event.content else { return }
    switch event.type {
    case "m.room.name":
      // `fi.mau.implicit_name` : nom dérivé du ghost par le bridge, pas un vrai nom de groupe.
      // On le laisse vide : le titre repartira du correspondant, puis du carnet d'adresses.
      if content.bool(at: "fi.mau.implicit_name") == true {
        model.explicitName = nil
      } else if let name = content.string(at: "name") {
        model.explicitName = MatrixIdentity.stripBridgeSuffix(name)
      }

    case "m.room.avatar":
      // Le pont retire la photo en envoyant un contenu vide : on suit, sinon
      // l'ancienne image survivrait à un changement côté réseau.
      let url = content.string(at: "url")
      model.avatarMXC = (url?.isEmpty == false) ? url : nil

    case "m.room.member":
      guard let userID = event.stateKey else { return }
      let membership = content.string(at: "membership") ?? "leave"
      let displayName = content.string(at: "displayname").map(MatrixIdentity.stripBridgeSuffix)
      let avatarMXC = content.string(at: "avatar_url")
      // Un `leave` ne doit pas effacer le nom déjà connu (on garde l'historique lisible),
      // ni la photo : elle sert encore à la mosaïque d'un groupe sans photo à lui.
      var member = model.members[userID] ?? MatrixRoomModel.Member(displayName: nil, membership: membership)
      member.membership = membership
      if let displayName { member.displayName = displayName }
      if let avatarMXC, !avatarMXC.isEmpty { member.avatarMXC = avatarMXC }
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
      model.bridgeChannelName = MatrixIdentity.stripBridgeSuffix(channelName)
    }
    if let roomType = content.string(at: "com.beeper.room_type.v2") ?? content.string(at: "com.beeper.room_type") {
      model.bridgeRoomType = roomType
    }
    if let channelID = content.string(at: "channel.id") { model.bridgeChannelID = channelID }
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
        // Un JID `@lid` ou `@g.us` n'est PAS un numéro, même s'il n'a que des chiffres.
        if let candidate, candidate.contains("@"), !candidate.hasSuffix("@s.whatsapp.net") { continue }
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

    // Le réseau du salon vient de l'état `m.bridge` ; s'il n'est pas encore arrivé
    // (timeline lue avant l'état), on le déduit des ghosts et bots présents plutôt
    // que de supposer WhatsApp. Un message sans réseau ne devient pas une conversation
    // de toute façon : `MatrixRoomModel.conversation` exige `network`.
    let network = model.network ?? Self.inferredNetwork(in: model) ?? .whatsapp
    let msgtype = content.string(at: "msgtype") ?? "m.text"
    var body = content.string(at: "body") ?? ""

    // `m.in_reply_to` : mautrix-whatsapp le bridge dans les deux sens.
    // Le corps embarque un repli « > <@x> texte » qu'il faut retirer de l'affichage.
    var replyTo: QuotedMessage?
    if let targetID = content.string(at: "m.relates_to.m.in_reply_to.event_id") {
      body = QuotedMessage.strippingReplyFallback(body)
      let quoted = model.messagesByID[targetID]
      replyTo = QuotedMessage(
        messageID: targetID,
        senderName: quoted.map { $0.isFromMe ? "Moi" : displayName(of: $0.senderID ?? "", in: model) }
          ?? Self.fallbackQuotedSender(in: content.string(at: "body") ?? ""),
        text: quoted?.sidebarPreviewText ?? Self.fallbackQuotedText(in: content.string(at: "body") ?? "")
      )
      if replyTo?.isEmpty == true { replyTo = nil }
    }

    var text = ""
    var attachments: [MessageAttachment] = []

    switch msgtype {
    case "m.image", "m.video", "m.file", "m.audio":
      if let mxc = content.string(at: "url") {
        // MSC2530 : quand `filename` est présent, il porte le nom du fichier et
        // `body` devient la **légende**. Sans cette distinction, le texte écrit
        // sous une photo disparaissait — on n'affichait que l'image.
        let explicitFilename = content.string(at: "filename")
        let caption: String? = {
          guard let explicitFilename, !explicitFilename.isEmpty else { return nil }
          // Certains ponts répètent le nom du fichier dans `body` : ce n'est pas
          // une légende, et l'écrire sous la photo n'apprendrait rien.
          return (body.isEmpty || body == explicitFilename) ? nil : body
        }()
        attachments.append(
          MessageAttachment(
            id: mxc,
            contentType: content.string(at: "info.mimetype") ?? Self.fallbackMime(for: msgtype),
            filename: explicitFilename ?? (body.isEmpty ? nil : body),
            localPath: MatrixAttachmentStore.existingLocalPath(forMXC: mxc)
          )
        )
        text = caption ?? ""
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
      senderID: event.sender,
      // Le fil nomme l'auteur une fois par groupe de bulles : il lui faut le
      // nom d'affichage de la salle, pas le MXID du bridge.
      senderName: event.sender.map { displayName(of: $0, in: model) },
      attachments: attachments,
      replyTo: replyTo
    )
    guard message.hasVisibleBody else { return }
    model.messagesByID[eventID] = message
    if event.sentAt > model.lastEventAt { model.lastEventAt = event.sentAt }
  }

  // MARK: - Réactions

  /// `m.reaction` : une annotation `{rel_type: "m.annotation", event_id, key}`.
  /// mautrix-whatsapp et mautrix-signal la bridgent dans les deux sens.
  private func applyReaction(_ event: MatrixEvent, to model: inout MatrixRoomModel) {
    guard event.type == "m.reaction",
          let eventID = event.eventID,
          let content = event.content,
          content.string(at: "m.relates_to.rel_type") == "m.annotation",
          let target = content.string(at: "m.relates_to.event_id"),
          let key = content.string(at: "m.relates_to.key"),
          let sender = event.sender
    else { return }

    model.reactionsByEventID[eventID] = MatrixRoomModel.ReactionEvent(
      targetEventID: target,
      emoji: key,
      senderID: sender,
      senderName: displayName(of: sender, in: model),
      isMine: sender == selfUserID
    )
  }

  /// `m.receipt` : `{ "$event": { "m.read": { "@user": { "ts": … } } } }`.
  /// C'est ce que mautrix-whatsapp pose quand le correspondant lit sur son téléphone.
  private func applyReceipt(_ event: MatrixEvent, to model: inout MatrixRoomModel) {
    guard event.type == "m.receipt",
          let events = event.content?.objectValue
    else { return }
    for (eventID, receipts) in events {
      guard let readers = receipts["m.read"]?.objectValue else { continue }
      for userID in readers.keys {
        model.readMarkerByUser[userID] = eventID
      }
    }
  }

  /// `m.room.redaction` : retire la réaction (ou le message) supprimé.
  /// Retirer une réaction, côté WhatsApp comme Signal, c'est rédiger son event.
  private func applyRedaction(_ event: MatrixEvent, to model: inout MatrixRoomModel) {
    guard event.type == "m.room.redaction", let target = event.redactedEventID else { return }
    model.reactionsByEventID.removeValue(forKey: target)
    model.messagesByID.removeValue(forKey: target)
    // Une réaction dont la cible disparaît n'a plus de sens.
    for (id, reaction) in model.reactionsByEventID where reaction.targetEventID == target {
      model.reactionsByEventID.removeValue(forKey: id)
    }
  }

  /// Nom affichable d'un expéditeur : le membre du salon, sinon le localpart nu.
  private func displayName(of userID: String, in model: MatrixRoomModel) -> String {
    if userID == selfUserID { return "Moi" }
    if let name = model.members[userID]?.displayName, !name.isEmpty { return name }
    return MatrixIdentity.localpart(userID)
  }

  /// Quand la cible n'est pas (encore) dans le modèle, le repli de citation reste
  /// la seule source : « > <@whatsapp_x:serveur> On se voit demain ? ».
  public static func fallbackQuotedSender(in body: String) -> String {
    guard let first = body.split(separator: "\n", omittingEmptySubsequences: false).first,
          first.hasPrefix("> <"),
          let open = first.firstIndex(of: "<"),
          let close = first[first.index(after: open)...].firstIndex(of: ">")
    else { return "" }
    let mxid = String(first[first.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
    return MatrixIdentity.localpart(mxid)
  }

  public static func fallbackQuotedText(in body: String) -> String {
    let quoted = body
      .split(separator: "\n", omittingEmptySubsequences: false)
      .prefix { $0.hasPrefix("> ") }
      .map { line -> String in
        var trimmed = String(line.dropFirst(2))
        // La première ligne porte « <@mxid> » avant le texte.
        if trimmed.hasPrefix("<"), let end = trimmed.firstIndex(of: ">") {
          trimmed = String(trimmed[trimmed.index(after: end)...])
        }
        return trimmed.trimmingCharacters(in: .whitespaces)
      }
    return quoted.joined(separator: " ").trimmingCharacters(in: .whitespaces)
  }

  /// Réseau déduit des habitants du salon : les ghosts et le bot portent le préfixe
  /// de leur pont. Sert de repli quand l'état `m.bridge` n'a pas encore été appliqué.
  public static func inferredNetwork(in model: MatrixRoomModel) -> MessageNetwork? {
    for userID in model.members.keys.sorted() {
      if let network = MatrixIdentity.network(ofGhost: userID) { return network }
      if let network = MatrixIdentity.network(ofBot: userID) { return network }
    }
    return nil
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
