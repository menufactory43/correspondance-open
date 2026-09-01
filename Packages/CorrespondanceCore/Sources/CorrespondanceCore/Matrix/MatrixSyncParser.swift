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
        // Avant `applyState` : c'est l'adhésion encore en mémoire qui dit si
        // quelque chose a changé. Manquait ici — la ligne « cc a rejoint »
        // n'apparaissait qu'après une relecture de l'historique, jamais au
        // moment où on l'invite.
        applyMembershipNotice(event, roomID: roomID, to: &model)
        applyState(event, to: &model)
        applyMessage(event, roomID: roomID, to: &model)
        applyReaction(event, to: &model)
        applyPoll(event, roomID: roomID, to: &model)
        applyAgentProposal(event, to: &model)
        applyRedaction(event, to: &model)
      }
      for event in (room.ephemeral?.events ?? []) {
        applyReceipt(event, to: &model)
        applyTyping(event, to: &model)
      }
      if let heroes = room.summary?.heroes { model.heroes = heroes }
      if let count = room.unreadNotifications?.notificationCount { model.unreadCount = count }
      resolveQuotes(in: &model)
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

  /// Installe dans un salon une page relue du magasin local : les messages,
  /// leurs réactions, et les modifications qui attendaient leur cible.
  ///
  /// Rien n'est marqué à réécrire — tout cela **vient** du magasin. Un envoi
  /// encore en vol reste tel quel : il n'a pas de version sur disque.
  public func hydrate(
    messages: [ChatMessage],
    reactions: [String: MatrixRoomModel.ReactionEvent],
    into model: inout MatrixRoomModel
  ) {
    for message in messages where model.messagesByID[message.id] == nil {
      var restored = message
      // Une correction reçue pendant que le fil dormait s'applique à l'ouverture.
      if let waiting = model.pendingEdits.removeValue(forKey: message.id) {
        restored = Self.edited(restored, text: waiting.text, at: waiting.at)
        model.markWritten(restored.id)
      }
      model.messagesByID[restored.id] = restored
      model.lastEventAt = max(model.lastEventAt, restored.sentAt)
      if restored.replyTo?.awaitsTarget == true {
        model.unresolvedQuoteMessageIDs.insert(restored.id)
      }
    }
    for (eventID, reaction) in reactions where model.reactionsByEventID[eventID] == nil {
      model.reactionsByEventID[eventID] = reaction
    }
    // Une citation qui se résout ici gagne son texte : ça, ça vaut d'être
    // réécrit, et `resolveQuotes` le marque de lui-même.
    resolveQuotes(in: &model)
  }

  /// Inverse de `MatrixRoomModel.conversationID` (`réseau:!salon:serveur`) : le
  /// salon commence au premier `:`, ce qui suit en contient d'autres.
  public static func roomID(inConversationID conversationID: String) -> String? {
    guard let colon = conversationID.firstIndex(of: ":") else { return nil }
    let roomID = String(conversationID[conversationID.index(after: colon)...])
    return roomID.hasPrefix("!") ? roomID : nil
  }

  /// Ce qu'une page fusionnée a changé. Quand on remonte un trou, c'est
  /// `added` qui dit s'il faut continuer : une page qui n'apporte plus rien
  /// veut dire qu'on a rejoint l'historique en main.
  public struct MergeOutcome: Sendable, Equatable {
    /// Events (messages ou réactions) que le salon connaissait déjà.
    public var alreadyKnown: Int
    /// Messages ou réactions entrés dans le modèle par cette page.
    public var added: Int
  }

  /// Messages d'un `GET /rooms/{id}/messages` (pagination arrière) fusionnés dans le salon.
  @discardableResult
  public func applyMessages(_ events: [MatrixEvent], roomID: String, to model: inout MatrixRoomModel) -> MergeOutcome {
    var alreadyKnown = 0
    let before = model.messagesByID.count + model.reactionsByEventID.count
    for event in events {
      if let id = event.eventID,
         model.messagesByID[id] != nil || model.reactionsByEventID[id] != nil
      {
        alreadyKnown += 1
      }
      applyMembershipNotice(event, roomID: roomID, to: &model)
      applyState(event, to: &model)
      applyMessage(event, roomID: roomID, to: &model)
      applyReaction(event, to: &model)
      applyPoll(event, roomID: roomID, to: &model)
      applyAgentProposal(event, to: &model)
      applyRedaction(event, to: &model)
    }
    resolveQuotes(in: &model)
    let after = model.messagesByID.count + model.reactionsByEventID.count
    return MergeOutcome(alreadyKnown: alreadyKnown, added: max(0, after - before))
  }

  /// Donne leur texte aux citations dont la cible vient d'arriver. À jouer après
  /// chaque fusion : une page remontée en arrière livre la réponse **avant** le
  /// message cité, et un `/sync` peut n'apporter que l'un des deux.
  public func resolveQuotes(in model: inout MatrixRoomModel) {
    for messageID in model.unresolvedQuoteMessageIDs {
      guard var message = model.messagesByID[messageID],
            let targetID = message.replyTo?.messageID,
            let quoted = model.messagesByID[targetID]
      else { continue }
      message.replyTo = QuotedMessage(
        messageID: targetID,
        senderName: quotedSenderName(of: quoted, fallbackBody: "", in: model),
        text: quoted.sidebarPreviewText
      )
      model.messagesByID[messageID] = message
      model.markWritten(messageID)
      model.unresolvedQuoteMessageIDs.remove(messageID)
    }
  }

  /// Cibles de citation qu'on ne trouvera pas dans ce qu'on a : à demander au
  /// Relais une par une (`GET /rooms/{r}/event/{e}`).
  public static func missingQuoteTargets(in model: MatrixRoomModel) -> Set<String> {
    Set(
      model.unresolvedQuoteMessageIDs.compactMap { messageID -> String? in
        guard let target = model.messagesByID[messageID]?.replyTo?.messageID,
              model.messagesByID[target] == nil
        else { return nil }
        return target
      }
    )
  }

  /// Un trou de timeline signalé par `/sync` : Synapse n'a rendu qu'une fenêtre
  /// (dix events sans filtre) et a posé `limited: true`. Ce qui précède la
  /// fenêtre est resté chez le Relais, et **aucun `/sync` suivant ne le rendra** —
  /// après une nuit Mac éteint, un groupe bavard perdait tout sauf ses dix
  /// derniers messages. `prevBatch` est le curseur d'où repartir en arrière.
  public struct TimelineGap: Sendable, Equatable {
    public var roomID: String
    public var prevBatch: String
    /// Le salon avait-il déjà des messages avant cette passe ? Si oui, on remonte
    /// jusqu'à les retrouver ; sinon (salon rejoint en retard, première
    /// installation) il n'y a pas de borne et on se contente d'une page.
    public var hasAnchor: Bool

    public init(roomID: String, prevBatch: String, hasAnchor: Bool) {
      self.roomID = roomID
      self.prevBatch = prevBatch
      self.hasAnchor = hasAnchor
    }
  }

  /// Les trous que ce `/sync` laisse derrière lui. À calculer **avant** `apply` :
  /// c'est l'état d'avant la passe qui dit si le salon a une borne connue.
  public static func timelineGaps(
    in response: MatrixSyncResponse,
    rooms: [String: MatrixRoomModel]
  ) -> [TimelineGap] {
    (response.rooms?.join ?? [:]).compactMap { roomID, room in
      guard room.timeline?.limited == true, let token = room.timeline?.prevBatch else { return nil }
      let hasAnchor = !(rooms[roomID]?.messagesByID.isEmpty ?? true)
      return TimelineGap(roomID: roomID, prevBatch: token, hasAnchor: hasAnchor)
    }
    .sorted { $0.roomID < $1.roomID }
  }

  /// L'état complet d'un salon (`GET /rooms/{id}/state`), appliqué d'un bloc.
  /// C'est par là qu'un salon rejoint pendant que l'app dormait entre dans le
  /// modèle : aucun `/sync` incrémental ne le raconterait.
  public func applyState(_ events: [MatrixEvent], roomID: String, to model: inout MatrixRoomModel) {
    for event in events { applyState(event, to: &model) }
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
         Self.networkMayCarryPhoneNumbers(model.network),
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
      // Un `m.room.member` lu avant l'état de bridge a pu prendre un identifiant
      // pour un numéro : maintenant qu'on sait de quel réseau il s'agit, on défait.
      if !Self.networkMayCarryPhoneNumbers(network) { model.bridgePhoneNumber = nil }
    }
    if let channelName = content.string(at: "channel.displayname") {
      model.bridgeChannelName = MatrixIdentity.stripBridgeSuffix(channelName)
    }
    if let roomType = content.string(at: "com.beeper.room_type.v2") ?? content.string(at: "com.beeper.room_type") {
      model.bridgeRoomType = roomType
    }
    if let channelID = content.string(at: "channel.id") { model.bridgeChannelID = channelID }
    // Les formes qu'un pont emploierait pour dire « demande ». Aucune n'est
    // émise par mautrix v26.08 ; les lire ne coûte rien et le jour où l'une
    // arrive, l'écran Demandes se remplit tout seul.
    let pending = content.bool(at: "com.beeper.pending")
      ?? content.bool(at: "fi.mau.pending")
      ?? (content.string(at: "com.beeper.chat_type").map { $0 == "request" })
      ?? (content.string(at: "channel.type").map { $0 == "request" })
    if let pending { model.isNetworkFlaggedRequest = pending }
    // Le bridge peut exposer le numéro (`channel.id` en JID, ou un extra explicite).
    // On ne prend que ce qui ressemble vraiment à un numéro ; sinon on s'en passe.
    if model.bridgePhoneNumber == nil, Self.networkMayCarryPhoneNumbers(model.network) {
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

  /// Ce réseau identifie-t-il les gens par un numéro ?
  ///
  /// Sans cette question, un `channel.id` Messenger — quinze chiffres, la longueur
  /// exacte d'un E.164 maximal — deviendrait un « +100012345678901 », s'installerait
  /// comme adresse du fil, et fusionnerait avec le contact qui aurait le malheur de
  /// porter ce numéro. Instagram n'y échappe que par la longueur de ses identifiants ;
  /// on ne laisse plus le hasard décider. Réseau inconnu : on laisse passer, l'état de
  /// bridge repassera derrière (cf. `applyBridge`).
  private static func networkMayCarryPhoneNumbers(_ network: MessageNetwork?) -> Bool {
    guard let bridge = network?.bridge else { return true }
    return bridge.identifiersArePhoneNumbers
  }

  // MARK: - Arrivées et départs

  /// « cc a rejoint la conversation » : une ligne d'événement quand un
  /// utilisateur du Relais — un agent, pas un ghost ni un bot de pont — entre
  /// ou sort d'un salon. Les ghosts vont et viennent au rythme du réseau
  /// distant et n'ont rien à annoncer ici ; moi non plus.
  ///
  /// À jouer **avant** `applyState` : c'est l'adhésion précédente, encore en
  /// mémoire, qui dit si quelque chose a changé. Un `join` qui suit un `join`
  /// n'est qu'un changement de nom ou de photo.
  private func applyMembershipNotice(_ event: MatrixEvent, roomID: String, to model: inout MatrixRoomModel) {
    guard event.type == "m.room.member",
          let eventID = event.eventID,
          let userID = event.stateKey,
          userID != selfUserID,
          !MatrixIdentity.isGhost(userID),
          !MatrixIdentity.isBridgeBot(userID),
          let content = event.content
    else { return }
    let membership = content.string(at: "membership") ?? "leave"
    let wasJoined = model.members[userID]?.membership == "join"
    let verb: String
    switch (wasJoined, membership) {
    case (false, "join"): verb = "a rejoint la conversation"
    case (true, "leave"), (true, "ban"): verb = "a quitté la conversation"
    default: return
    }
    let name = content.string(at: "displayname").map(MatrixIdentity.stripBridgeSuffix)
      ?? model.members[userID]?.displayName
      ?? MatrixIdentity.localpart(of: userID)
    let network = model.network ?? Self.inferredNetwork(in: model) ?? .whatsapp
    model.messagesByID[eventID] = ChatMessage(
      id: eventID,
      conversationID: model.conversationID,
      network: network,
      text: "",
      sentAt: event.sentAt,
      isFromMe: false,
      senderID: userID,
      senderName: name,
      systemEventText: "\(name) \(verb)"
    )
    model.markWritten(eventID)
    if event.sentAt > model.lastEventAt { model.lastEventAt = event.sentAt }
  }

  // MARK: - Propositions de l'agent

  /// Un brouillon posé par « cc » (`fr.correspondance.agent.proposal`).
  ///
  /// Il entre dans le fil comme un message, mais il n'en est pas un : aucun
  /// pont ne le relaie, il ne bouge pas `lastEventAt` (le fil ne remonte donc
  /// pas dans la file pour une phrase que personne n'a dite), et
  /// `sidebarPreviewText` reste muet. Ce qui l'efface est ce qui efface un
  /// message : une redaction, ou le masquage « ici ».
  private func applyAgentProposal(_ event: MatrixEvent, to model: inout MatrixRoomModel) {
    guard event.type == AgentProposal.eventType,
          let eventID = event.eventID,
          let content = event.content,
          let proposal = Self.agentProposal(in: content, sender: event.sender),
          !proposal.isEmpty
    else { return }
    let network = model.network ?? Self.inferredNetwork(in: model) ?? .whatsapp
    model.messagesByID[eventID] = ChatMessage(
      id: eventID,
      conversationID: model.conversationID,
      network: network,
      text: "",
      sentAt: event.sentAt,
      // Une proposition n'est de personne : ni de moi, ni du correspondant.
      isFromMe: false,
      senderID: event.sender,
      senderName: event.sender.map { displayName(of: $0, in: model) },
      agentProposal: proposal
    )
    model.markWritten(eventID)
  }

  /// Le corps d'une proposition : `{ "body", "agent", "m.relates_to" }`.
  /// À défaut de champ `agent`, le localpart de l'expéditeur fait le nom.
  public static func agentProposal(in content: MatrixJSON, sender: String?) -> AgentProposal? {
    guard let body = content.string(at: "body"), !body.isEmpty else { return nil }
    let declared = content.string(at: "agent")?.trimmingCharacters(in: .whitespacesAndNewlines)
    let agent = (declared?.isEmpty == false)
      ? declared!
      : sender.map { MatrixIdentity.localpart(of: $0) } ?? ""
    return AgentProposal(
      agent: agent,
      text: body,
      inReplyToEventID: content.string(at: "m.relates_to.m.in_reply_to.event_id")
    )
  }

  // MARK: - Messages

  private func applyMessage(_ event: MatrixEvent, roomID: String, to model: inout MatrixRoomModel) {
    guard event.type == "m.room.message",
          let eventID = event.eventID,
          let content = event.content
    else { return }
    // Une modification (`m.replace`) n'est pas un message de plus : elle
    // corrige celui qu'elle vise. Elle peut arriver avant lui — une page
    // remontée à l'envers — auquel cas elle attend dans `pendingEdits`.
    if content.string(at: "m.relates_to.rel_type") == "m.replace" {
      applyEdit(event, content: content, to: &model)
      return
    }

    // Le réseau du salon vient de l'état `m.bridge` ; s'il n'est pas encore arrivé
    // (timeline lue avant l'état), on le déduit des ghosts et bots présents plutôt
    // que de supposer WhatsApp. Un message sans réseau ne devient pas une conversation
    // de toute façon : `MatrixRoomModel.conversation` exige `network`.
    let network = model.network ?? Self.inferredNetwork(in: model) ?? .whatsapp
    let msgtype = content.string(at: "msgtype") ?? "m.text"
    var body = content.string(at: "body") ?? ""

    // Le bot d'un pont qui parle dans un portail n'est pas un correspondant :
    // « relay now set », « message not bridged » sont des événements, en
    // anglais. Ils s'écrivent en ligne d'événement, traduits quand on les
    // connaît — vu en vrai, l'avis prenait la bulle et le visage du contact.
    // Une commande que j'ai donnée au pont dans le portail (« !wa set-relay »)
    // n'est pas un message à mon correspondant : le pont la lit et ne la
    // relaie pas, le fil n'a pas à la montrer en bulle.
    if event.sender == selfUserID, MatrixBridgeNotice.isBridgeCommand(body, network: network) {
      model.markWritten(eventID)
      return
    }
    if let sender = event.sender, MatrixIdentity.isBridgeBot(sender), !body.isEmpty {
      model.messagesByID[eventID] = ChatMessage(
        id: eventID,
        conversationID: model.conversationID,
        network: network,
        text: "",
        sentAt: event.sentAt,
        isFromMe: false,
        senderID: sender,
        senderName: "Pont",
        systemEventText: MatrixBridgeNotice.systemText(for: body)
      )
      model.markWritten(eventID)
      if event.sentAt > model.lastEventAt { model.lastEventAt = event.sentAt }
      return
    }

    // `m.in_reply_to` : mautrix-whatsapp le bridge dans les deux sens.
    // Le corps embarque un repli « > <@x> texte » qu'il faut retirer de l'affichage.
    var replyTo: QuotedMessage?
    if let targetID = content.string(at: "m.relates_to.m.in_reply_to.event_id") {
      body = QuotedMessage.strippingReplyFallback(body)
      let quoted = model.messagesByID[targetID]
      replyTo = QuotedMessage(
        messageID: targetID,
        senderName: quotedSenderName(
          of: quoted,
          fallbackBody: content.string(at: "body") ?? "",
          in: model
        ),
        text: quoted?.sidebarPreviewText ?? Self.fallbackQuotedText(in: content.string(at: "body") ?? "")
      )
      // Cible inconnue et pas de repli (Signal) : la citation attend, on ne la jette pas.
    }

    // Les mentions ne survivent pas au corps nu : mautrix y pose le nom seul et
    // range l'arobase dans la pilule HTML. On la lui rend — après le repli de
    // citation, dont le texte ne parle pas de ce message-ci.
    body = MatrixMentions.restoringPills(
      in: body, formattedBody: content.string(at: "formatted_body")
    )

    // `com.beeper.linkpreviews` : l'aperçu que l'expéditeur a lui-même produit.
    let linkPreview = Self.bridgedLinkPreview(in: content)

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
            localPath: MatrixAttachmentStore.existingLocalPath(forMXC: mxc),
            voice: Self.voiceNote(in: content, msgtype: msgtype)
          )
        )
        text = caption ?? ""
      } else {
        text = body
      }
    default:
      text = body
    }

    var message = ChatMessage(
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
      replyTo: replyTo,
      linkPreview: linkPreview
    )
    guard message.hasVisibleBody else { return }
    // Une modification arrivée avant sa cible s'applique à sa naissance — si
    // elle vient bien de l'auteur.
    if let waiting = model.pendingEdits.removeValue(forKey: eventID),
       waiting.sender == nil || waiting.sender == event.sender
    {
      message = Self.edited(message, text: waiting.text, at: waiting.at)
    }
    // Un message déjà corrigé qui repasse (page de backfill, sync initial) ne
    // redevient pas sa première version : la correction reste.
    if let known = model.messagesByID[eventID], let editedAt = known.editedAt {
      message = Self.edited(message, text: known.text, at: editedAt)
      message.editHistory = known.editHistory
    }
    model.messagesByID[eventID] = message
    model.markWritten(eventID)
    if replyTo?.awaitsTarget == true {
      model.unresolvedQuoteMessageIDs.insert(eventID)
    } else {
      model.unresolvedQuoteMessageIDs.remove(eventID)
    }
    if event.sentAt > model.lastEventAt { model.lastEventAt = event.sentAt }
  }

  /// Le message vocal d'un `m.audio`, ou `nil` si ce n'en est pas un.
  ///
  /// C'est la présence de `org.matrix.msc3245.voice` qui tranche — un objet
  /// vide, on ne lit donc que sa présence. La durée et la forme d'onde viennent
  /// de `org.matrix.msc1767.audio` ; à défaut, `info.duration` sait encore dire
  /// la durée, et la bulle se passe de forme d'onde.
  public static func voiceNote(in content: MatrixJSON, msgtype: String) -> VoiceNote? {
    guard msgtype == "m.audio", content.value(at: VoiceNoteKeys.voice) != nil else { return nil }
    let audio = content.value(at: VoiceNoteKeys.audio)
    let millis = audio?["duration"]?.doubleValue ?? content.double(at: "info.duration") ?? 0
    let raw = (audio?["waveform"]?.arrayValue ?? []).compactMap(\.intValue)
    return VoiceNote(duration: millis / 1000, waveform: VoiceNote.normalized(raw))
  }

  /// Applique une modification `m.replace`. Le nouveau texte vit dans
  /// `m.new_content` ; le `body` de l'event, lui, porte le repli « * texte »
  /// que lisent les clients qui ignorent MSC2676 — jamais ce qu'on affiche.
  ///
  /// Seul l'auteur peut corriger son message : une modification venue de
  /// quelqu'un d'autre n'en est pas une, et on la laisse tomber.
  private func applyEdit(_ event: MatrixEvent, content: MatrixJSON, to model: inout MatrixRoomModel) {
    guard let target = content.string(at: "m.relates_to.event_id"),
          let text = Self.newText(in: content)
    else { return }
    guard let existing = model.messagesByID[target] else {
      // La cible n'est pas là : la modification attend, et seule la dernière
      // compte — corriger deux fois ne garde que le dernier mot.
      if let known = model.pendingEdits[target], known.at > event.sentAt { return }
      model.pendingEdits[target] = MatrixRoomModel.PendingEdit(text: text, at: event.sentAt, sender: event.sender)
      return
    }
    guard existing.senderID == event.sender else { return }
    // Une modification plus ancienne qui arrive après ne défait pas la dernière.
    if let editedAt = existing.editedAt, editedAt > event.sentAt { return }
    model.messagesByID[target] = Self.edited(existing, text: text, at: event.sentAt)
    model.markWritten(target)
  }

  /// Le message corrigé : le nouveau texte, la date, et l'ancien rangé dans
  /// l'historique — c'est lui qu'on lit sous la mention « Modifié ».
  private static func edited(_ message: ChatMessage, text: String, at: Date) -> ChatMessage {
    var updated = message
    if !message.text.isEmpty, message.text != text, !updated.editHistory.contains(message.text) {
      updated.editHistory.append(message.text)
    }
    updated.text = text
    updated.editedAt = at
    return updated
  }

  /// Le texte d'une modification : `m.new_content.body`, et rien d'autre. Le
  /// `body` racine est un repli préfixé d'une étoile — l'afficher ajouterait
  /// une astérisque au message à chaque correction.
  public static func newText(in content: MatrixJSON) -> String? {
    // Un message corrigé garde ses mentions : elles s'écrivent au même endroit,
    // le nom dans le corps et l'arobase dans la pilule.
    if let body = content.string(at: "m.new_content.body") {
      return MatrixMentions.restoringPills(
        in: body, formattedBody: content.string(at: "m.new_content.formatted_body")
      )
    }
    // Certains ponts ne posent que le repli : on lui retire son étoile.
    guard let fallback = content.string(at: "body") else { return nil }
    let text = fallback.hasPrefix("* ") ? String(fallback.dropFirst(2)) : fallback
    return MatrixMentions.restoringPills(
      in: text, formattedBody: content.string(at: "formatted_body")
    )
  }

  /// Le premier aperçu de `com.beeper.linkpreviews` qui porte une adresse. Les
  /// clés sont celles d'Open Graph, l'image est déjà sur le Relais (`mxc://`).
  public static func bridgedLinkPreview(in content: MatrixJSON) -> BridgedLinkPreview? {
    guard let previews = content["com.beeper.linkpreviews"]?.arrayValue else { return nil }
    for preview in previews {
      guard let url = preview["matched_url"]?.stringValue ?? preview["og:url"]?.stringValue,
            !url.isEmpty
      else { continue }
      let image = preview["og:image"]?.stringValue
      return BridgedLinkPreview(
        url: url,
        title: preview["og:title"]?.stringValue,
        description: preview["og:description"]?.stringValue,
        imageMXC: (image?.hasPrefix("mxc://") == true) ? image : nil,
        imageContentType: preview["og:image:type"]?.stringValue
      )
    }
    return nil
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
    model.markWritten(eventID)
  }

  // MARK: - Sondages (MSC3381)

  /// Les trois events d'un sondage. `poll.start` pose la question et devient un
  /// message ; `poll.response` est une voix ; `poll.end` ferme les votes.
  ///
  /// L'ordre d'arrivée n'a aucune importance : une voix reçue avant sa question
  /// (page remontée à l'envers) attend dans le dépouillement, et la question
  /// la retrouve. Une voix postérieure à la clôture ne compte jamais.
  private func applyPoll(_ event: MatrixEvent, roomID: String, to model: inout MatrixRoomModel) {
    guard let eventID = event.eventID, let content = event.content else { return }

    if PollEventTypes.isStart(event.type) {
      guard let poll = Self.poll(inStart: content, type: event.type) else { return }
      var entry = model.pollsByEventID[eventID] ?? MatrixRoomModel.PollEvent(poll: poll, startType: event.type)
      // La question remplace ce qu'on avait ; les voix déjà reçues restent.
      entry.poll.question = poll.question
      entry.poll.answers = poll.answers
      entry.poll.kind = poll.kind
      entry.poll.maxSelections = poll.maxSelections
      entry.startType = event.type
      Self.retally(&entry, selfUserID: selfUserID)
      model.pollsByEventID[eventID] = entry

      let network = model.network ?? Self.inferredNetwork(in: model) ?? .whatsapp
      let message = ChatMessage(
        id: eventID,
        conversationID: model.conversationID,
        network: network,
        text: "",
        sentAt: event.sentAt,
        isFromMe: event.sender == selfUserID,
        senderID: event.sender,
        senderName: event.sender.map { displayName(of: $0, in: model) },
        poll: entry.poll
      )
      model.messagesByID[eventID] = message
      if event.sentAt > model.lastEventAt { model.lastEventAt = event.sentAt }
      return
    }

    guard let target = content.string(at: "m.relates_to.event_id"),
          content.string(at: "m.relates_to.rel_type") == "m.reference",
          let sender = event.sender
    else { return }

    if PollEventTypes.isResponse(event.type) {
      let answers = Self.answerIDs(inResponse: content, type: event.type)
      var entry = model.pollsByEventID[target]
        ?? MatrixRoomModel.PollEvent(poll: Poll(question: "", answers: []), startType: event.type)
      // Une voix plus ancienne qui arrive après ne remplace pas la dernière.
      if let known = entry.voteTimes[sender], known > event.sentAt { return }
      if let closedAt = entry.closedAt, event.sentAt > closedAt { return }
      entry.voteTimes[sender] = event.sentAt
      entry.poll.votesByVoter[sender] = answers
      Self.retally(&entry, selfUserID: selfUserID)
      model.pollsByEventID[target] = entry
      refreshPollMessage(target, in: &model)
      return
    }

    if PollEventTypes.isEnd(event.type) {
      // Seul l'auteur du sondage — ou un modérateur — peut le clore. On s'en
      // tient à l'auteur : c'est tout ce que les ponts produisent.
      guard model.messagesByID[target] == nil || model.messagesByID[target]?.senderID == sender
        || sender == selfUserID
      else { return }
      var entry = model.pollsByEventID[target]
        ?? MatrixRoomModel.PollEvent(poll: Poll(question: "", answers: []), startType: PollEventTypes.startUnstable)
      entry.closedAt = event.sentAt
      entry.poll.isClosed = true
      // Les voix arrivées après la clôture n'auraient jamais dû compter.
      for (voter, when) in entry.voteTimes where when > event.sentAt {
        entry.voteTimes.removeValue(forKey: voter)
        entry.poll.votesByVoter.removeValue(forKey: voter)
      }
      Self.retally(&entry, selfUserID: selfUserID)
      model.pollsByEventID[target] = entry
      refreshPollMessage(target, in: &model)
    }
  }

  private func refreshPollMessage(_ eventID: String, in model: inout MatrixRoomModel) {
    guard var message = model.messagesByID[eventID],
          let poll = model.pollsByEventID[eventID]?.poll
    else { return }
    message.poll = poll
    model.messagesByID[eventID] = message
    model.markWritten(eventID)
  }

  /// Ne retient que les voix portant sur des réponses qui existent, et relit
  /// les miennes. Rejoué après chaque event : c'est le dépouillement.
  private static func retally(_ entry: inout MatrixRoomModel.PollEvent, selfUserID: String) {
    let valid = Set(entry.poll.answers.map(\.id))
    if !valid.isEmpty {
      for (voter, answers) in entry.poll.votesByVoter {
        let kept = answers.filter { valid.contains($0) }
        // Une voix pour une réponse inconnue est une voix perdue, pas une
        // abstention : la personne a bien voté, on ne sait juste pas pour quoi.
        if kept.isEmpty { entry.poll.votesByVoter.removeValue(forKey: voter) }
        else { entry.poll.votesByVoter[voter] = Array(kept.prefix(max(entry.poll.maxSelections, 1))) }
      }
    }
    entry.poll.myAnswerIDs = entry.poll.votesByVoter[selfUserID] ?? []
  }

  /// La question et ses réponses. MSC3381 range tout sous une clé qui porte le
  /// même nom que l'event ; la forme stable, elle, le pose à plat.
  public static func poll(inStart content: MatrixJSON, type: String) -> Poll? {
    let body = content.value(at: type) ?? content
    guard let answersJSON = body["answers"]?.arrayValue, !answersJSON.isEmpty else { return nil }
    let question = text(in: body["question"]) ?? ""
    let answers = answersJSON.compactMap { entry -> Poll.Answer? in
      guard let id = entry["id"]?.stringValue, !id.isEmpty else { return nil }
      return Poll.Answer(id: id, text: text(in: entry) ?? id)
    }
    guard !answers.isEmpty else { return nil }
    let kindRaw = body["kind"]?.stringValue ?? ""
    return Poll(
      question: question,
      answers: answers,
      kind: kindRaw.hasSuffix("undisclosed") ? .undisclosed : .disclosed,
      maxSelections: max(body["max_selections"]?.intValue ?? 1, 1)
    )
  }

  public static func answerIDs(inResponse content: MatrixJSON, type: String) -> [String] {
    let body = content.value(at: type) ?? content
    return (body["answers"]?.arrayValue ?? []).compactMap(\.stringValue)
  }

  /// Le texte d'un morceau MSC1767 : `m.text`, `org.matrix.msc1767.text`, ou
  /// `body` chez les ponts qui n'ont retenu que la forme la plus ancienne.
  private static func text(in node: MatrixJSON?) -> String? {
    guard let node else { return nil }
    if let value = node[PollEventTypes.textStable]?.stringValue, !value.isEmpty { return value }
    if let value = node[PollEventTypes.textUnstable]?.stringValue, !value.isEmpty { return value }
    if let value = node["body"]?.stringValue, !value.isEmpty { return value }
    if let value = node.stringValue, !value.isEmpty { return value }
    return nil
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

  /// `m.typing` : `{ "user_ids": ["@alice:serveur"] }`.
  ///
  /// C'est une EDU, elle ne revient qu'au **changement** : une liste vide veut
  /// dire « plus personne », et l'absence d'event ne veut rien dire du tout.
  /// D'où la date, qui fait expirer l'indicateur toute seule.
  ///
  /// Les ponts mautrix relaient la frappe dans les deux sens pour WhatsApp et
  /// Signal ; Instagram l'envoie sans toujours la recevoir.
  private func applyTyping(_ event: MatrixEvent, to model: inout MatrixRoomModel) {
    guard event.type == "m.typing", let content = event.content else { return }
    let ids = (content["user_ids"]?.arrayValue ?? []).compactMap(\.stringValue)
    model.typingUserIDs = Set(ids)
    model.typingUpdatedAt = Date()
  }

  /// `m.room.redaction` : retire la réaction (ou le message) supprimé.
  /// Retirer une réaction, côté WhatsApp comme Signal, c'est rédiger son event.
  private func applyRedaction(_ event: MatrixEvent, to model: inout MatrixRoomModel) {
    guard event.type == "m.room.redaction", let target = event.redactedEventID else { return }
    model.reactionsByEventID.removeValue(forKey: target)
    model.messagesByID.removeValue(forKey: target)
    model.pollsByEventID.removeValue(forKey: target)
    model.markDeleted(target)
    // Une réaction dont la cible disparaît n'a plus de sens.
    for (id, reaction) in model.reactionsByEventID where reaction.targetEventID == target {
      model.reactionsByEventID.removeValue(forKey: id)
      model.markDeleted(id)
    }
  }

  /// Nom affichable d'un expéditeur : le membre du salon, sinon le localpart nu.
  /// Le nom d'une personne dans ce salon, ou **rien**.
  ///
  /// Le repli sur le localpart tient pour un vrai compte Matrix (`@meffysto`),
  /// jamais pour un ghost de pont : « whatsapp_lid-19876543210 » n'est pas
  /// quelqu'un, c'est une clé de base de données. Aux vues de choisir alors
  /// quoi montrer (le titre du fil, rien du tout) — cf. `displayedSenderName`.
  private func displayName(of userID: String, in model: MatrixRoomModel) -> String {
    if userID == selfUserID { return "Moi" }
    if let name = model.members[userID]?.displayName, !name.isEmpty { return name }
    guard !MatrixIdentity.isGhost(userID), !MatrixIdentity.isBridgeBot(userID) else { return "" }
    return MatrixIdentity.localpart(userID)
  }

  /// Le nom à écrire au-dessus d'une citation — un NOM, jamais un identifiant.
  ///
  /// Trois sources, dans l'ordre : le message cité s'il est chargé ; à défaut le
  /// MXID que porte le repli « > <@mxid> … », résolu contre les membres du
  /// salon ; à défaut encore, en tête-à-tête, le titre du fil — il n'y a qu'une
  /// personne en face. Sinon rien : la bulle citée montrera son seul texte.
  private func quotedSenderName(
    of quoted: ChatMessage?,
    fallbackBody: String,
    in model: MatrixRoomModel
  ) -> String {
    if let quoted {
      if quoted.isFromMe { return "Moi" }
      let name = displayName(of: quoted.senderID ?? "", in: model)
      if !name.isEmpty { return name }
    }
    if let mxid = Self.fallbackQuotedSenderID(in: fallbackBody), !mxid.isEmpty {
      let name = displayName(of: mxid, in: model)
      if !name.isEmpty { return name }
    }
    guard !model.isGroup(selfUserID: selfUserID) else { return "" }
    let title = model.title(selfUserID: selfUserID)
    return title == model.roomID ? "" : title
  }

  /// Quand la cible n'est pas (encore) dans le modèle, le repli de citation reste
  /// la seule source : « > <@whatsapp_x:serveur> On se voit demain ? ». Il en
  /// rend le MXID — à l'appelant de le traduire en nom, il a le salon sous la main.
  public static func fallbackQuotedSenderID(in body: String) -> String? {
    guard let first = body.split(separator: "\n", omittingEmptySubsequences: false).first,
          first.hasPrefix("> <"),
          let open = first.firstIndex(of: "<"),
          let close = first[first.index(after: open)...].firstIndex(of: ">")
    else { return nil }
    let mxid = String(first[first.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
    return mxid.isEmpty ? nil : mxid
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
