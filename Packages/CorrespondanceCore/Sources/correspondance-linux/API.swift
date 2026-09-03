import CorrespondanceCore
import CorrespondanceMatrixClient
import Foundation
import Observation

/// L'API que l'interface (dans le navigateur) parle au magasin.
///
/// Un seul principe : l'interface ne calcule rien, elle MONTRE. Ce qui est
/// visible, dans quel ordre, ce qui est lu, muet, épinglé, archivé, en
/// rappel — tout vient de `RelayStore` et des fonctions pures de Core, les
/// mêmes que sur le Mac et l'iPhone. Le JSON n'est qu'une projection.
///
/// La sécurité tient en trois gardes, parce qu'un serveur sur `127.0.0.1`
/// est joignable par tout ce qui tourne sur la machine — y compris une page
/// web ouverte ailleurs dans le navigateur :
/// - un jeton tiré au lancement, donné à la page par le fragment de l'URL
///   (jamais envoyé au serveur par l'URL), exigé sur chaque appel `/api` ;
/// - l'en-tête `Host` doit être local (contre le DNS rebinding) ;
/// - l'`Origin`, quand il est là, doit être le nôtre.
@MainActor
final class API {
  let store: RelayStore
  let token: String
  let uiDirectory: URL
  let fontsDirectory: URL
  private(set) var origin = ""

  /// Les flux d'événements ouverts : à chaque changement du magasin, tous
  /// reçoivent `changed`, et la page redemande ce qu'elle montre.
  private var sinks: [HTTPServer.EventSink] = []
  private var revision = 0
  /// Réponse récente d'un `/api/avatar` : les photos ne se relisent pas à
  /// chaque rafraîchissement de la liste.
  private var avatarCache: [String: Data] = [:]
  /// Par où la dernière connexion est passée : l'écran le dit une fois.
  @MainActor static var derniereNote: String?

  init(store: RelayStore, uiDirectory: URL, fontsDirectory: URL) {
    self.store = store
    self.uiDirectory = uiDirectory
    self.fontsDirectory = fontsDirectory
    var bytes = [UInt8](repeating: 0, count: 24)
    for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
    token = Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    observe()
  }

  func setOrigin(_ origin: String) { self.origin = origin }

  // MARK: - Observation → événements

  /// `withObservationTracking` ne sonne qu'une fois : on se réarme après
  /// chaque changement, et on coalesce dans la même passe du run loop.
  private func observe() {
    withObservationTracking {
      _ = store.session
      _ = store.conversations
      _ = store.messages
      _ = store.state
      _ = store.connectionError
      _ = store.syncError
      _ = store.typingLabels
      _ = store.seenByLabels
      _ = store.mergedContacts
      _ = store.scheduled
      _ = store.scope
      _ = store.networkFilter
      _ = store.filter
      _ = store.selectedConversationID
      _ = store.focusConversationID
      _ = store.lastSent
      _ = store.isLoadingOlder
      _ = store.forwardingMessage
      _ = store.agentDefaultMode
    } onChange: {
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.revision += 1
        self.broadcast()
        self.observe()
      }
    }
  }

  private func broadcast() {
    sinks.removeAll { !$0.isOpen }
    let payload = "{\"revision\":\(revision)}"
    for sink in sinks { sink.send(event: "changed", data: payload) }
  }

  // MARK: - Routage

  nonisolated func handle(_ request: HTTPServer.Request) async -> HTTPServer.Response {
    await route(request)
  }

  private func route(_ request: HTTPServer.Request) async -> HTTPServer.Response {
    // Le DNS rebinding : une page tierce ne doit pas pouvoir nous joindre
    // sous un autre nom d'hôte.
    let host = (request.header("host") ?? "").lowercased()
    guard host.hasPrefix("127.0.0.1") || host.hasPrefix("localhost") || host.hasPrefix("[::1]") else {
      return .text("hôte refusé", status: 403)
    }
    if let requestOrigin = request.header("origin"), !origin.isEmpty, requestOrigin != origin {
      return .text("origine refusée", status: 403)
    }

    if request.path == "/" || request.path == "/index.html" { return page() }
    if request.path.hasPrefix("/static/") { return staticFile(String(request.path.dropFirst("/static/".count))) }
    if request.path.hasPrefix("/fonts/") { return font(String(request.path.dropFirst("/fonts/".count))) }
    if request.path == "/favicon.ico" || request.path == "/icon.png" { return staticFile("icon.png") }

    guard request.path.hasPrefix("/api/") || request.path == "/events" else {
      return .text("introuvable", status: 404)
    }
    let given = request.header("x-correspondance-token") ?? request.query["token"] ?? ""
    guard given == token else { return .json(["error": "jeton manquant ou faux"], status: 401) }

    if request.path == "/events" { return events() }
    let body = request.json
    switch (request.method, request.path) {
    case ("GET", "/api/state"): return .json(stateJSON())
    case ("GET", "/api/thread"): return .json(threadJSON(request.query["id"] ?? ""))
    case ("GET", "/api/file"): return file(request.query["path"] ?? "")
    case ("GET", "/api/avatar"): return await avatar(request.query["id"] ?? "")
    case ("GET", "/api/search"): return .json(searchJSON(request.query["q"] ?? ""))
    case ("GET", "/api/facets"): return .json(facetsJSON(facet: request.query["facet"] ?? "", query: request.query["q"] ?? ""))
    case ("GET", "/api/members"): return await membersJSON(body: request.query)
    case ("GET", "/api/forwardTargets"): return .json(["targets": store.forwardTargets(request.query["q"] ?? "").map(conversationJSON)])
    case ("POST", _): return action(request.path, body: body, raw: request)
    default: return .json(["error": "méthode refusée"], status: 405)
    }
  }

  // MARK: - Les actions

  private func action(_ path: String, body: [String: Any], raw: HTTPServer.Request) -> HTTPServer.Response {
    let id = body["id"] as? String ?? ""
    let messageID = body["messageID"] as? String ?? ""
    let text = body["text"] as? String ?? ""
    let value = body["value"] as? Bool ?? true
    let store = self.store

    switch path {
    case "/api/connect":
      if let code = body["code"] as? String, !code.trimmingCharacters(in: .whitespaces).isEmpty {
        guard let pairing = RelayPairingCode(encoded: code) else {
          return .json(["error": "Ce code d'appairage ne se lit pas."], status: 400)
        }
        guard !pairing.isExpired() else {
          return .json(["error": "Ce code d'appairage a expiré — l'installeur du Relais en donne un neuf."], status: 400)
        }
        Task { @MainActor in
          let note = await store.connecterParLeCode(pairing)
          Self.derniereNote = note
        }
        return .json(["ok": true, "chemin": pairing.chemin.titreFR, "empreinte": pairing.fingerprintWords()])
      }
      let homeserver = body["homeserver"] as? String ?? ""
      let user = body["user"] as? String ?? ""
      let password = body["password"] as? String ?? ""
      Task { await store.connect(homeserver: homeserver, user: user, password: password) }
      return .json(["ok": true])
    case "/api/signout":
      Task { await store.signOut() }
    case "/api/reload":
      Task { await store.reloadFromRelay() }
    case "/api/visibility":
      store.isWindowVisible = value
    case "/api/mode":
      // Focus ou Inbox : la portée reste ; la page mémorise le mode.
      break
    case "/api/scope":
      if let scope = InboxScope(rawValue: body["scope"] as? String ?? "") { store.scope = scope }
    case "/api/filter":
      if let filter = ConversationFilter(rawValue: body["filter"] as? String ?? "") { store.filter = filter }
    case "/api/network":
      let raw = body["network"] as? String ?? ""
      store.networkFilter = raw.isEmpty ? nil : MessageNetwork(rawValue: raw)
    case "/api/select":
      let focus = body["focus"] as? Bool ?? false
      if focus { store.focusConversationID = id.isEmpty ? nil : id } else { store.selectedConversationID = id.isEmpty ? nil : id }
      if !id.isEmpty { Task { await store.open(conversationID: id) } }
    case "/api/open":
      Task { await store.open(conversationID: id) }
    case "/api/markRead":
      Task { await store.markRead(conversationID: id) }
    case "/api/loadOlder":
      Task { await store.loadOlder(conversationID: id) }
    case "/api/draft":
      store.setDraft(text, conversationID: id)
    case "/api/send":
      Task { await store.send(conversationID: id) }
    case "/api/undoSend":
      store.undoSend(messageID)
    case "/api/react":
      let emoji = body["emoji"] as? String ?? ""
      Task { await store.react(conversationID: id, messageID: messageID, emoji: emoji) }
    case "/api/reply":
      store.setReplyTarget(messageID.isEmpty ? nil : messageID, conversationID: id)
    case "/api/beginEdit":
      if let message = store.visibleMessages(id).first(where: { $0.id == messageID }) {
        store.beginEditing(message, conversationID: id)
      }
    case "/api/endEdit":
      store.endEditing(id)
    case "/api/edit":
      Task { await store.editMessage(messageID: messageID, newText: text, conversationID: id) }
    case "/api/hide":
      store.hide(messageID: messageID, conversationID: id)
    case "/api/deleteEverywhere":
      Task { await store.deleteEverywhere(messageID: messageID, conversationID: id) }
    case "/api/vote":
      let answer = body["answerID"] as? String ?? ""
      Task { await store.votePoll(conversationID: id, messageID: messageID, answerID: answer) }
    case "/api/forward":
      let target = body["target"] as? String ?? ""
      if let message = store.visibleMessages(id).first(where: { $0.id == messageID }) {
        Task { await store.forward(message, to: target) }
      }
    case "/api/archive":
      store.setArchived(value, conversationID: id)
    case "/api/pin":
      store.togglePinned(id)
    case "/api/mute":
      store.toggleMuted(id)
    case "/api/archiveAllRead":
      store.archiveAllRead()
    case "/api/reminder":
      let seconds = body["wakeAt"] as? Double
      store.setReminder(seconds.map { Date(timeIntervalSince1970: $0) }, conversationID: id)
    case "/api/request":
      let raw = body["decision"] as? String ?? ""
      store.decideRequest(ConversationRequest.Decision(rawValue: raw), conversationID: id)
    case "/api/focus/next":
      store.focusNext()
    case "/api/focus/previous":
      store.focusPrevious()
    case "/api/focus/archive":
      store.focusArchiveAndAdvance()
    case "/api/selfNote":
      Task { await store.openSelfNote() }
    case "/api/incognito":
      store.isIncognito = value
    case "/api/agent/mode":
      if let mode = AgentSettings.Mode(rawValue: body["mode"] as? String ?? "") { store.setAgentDefaultMode(mode) }
    case "/api/agent/invite":
      Task { try? await store.inviteAgent(id) }
    case "/api/proposal/send":
      if let message = store.visibleMessages(id).first(where: { $0.id == messageID }) {
        Task { await store.sendAgentProposal(message, conversationID: id) }
      }
    case "/api/proposal/edit":
      if let message = store.visibleMessages(id).first(where: { $0.id == messageID }) {
        store.editAgentProposal(message, conversationID: id)
      }
    case "/api/proposal/ignore":
      if let message = store.visibleMessages(id).first(where: { $0.id == messageID }) {
        store.ignoreAgentProposal(message, conversationID: id)
      }
    case "/api/newChat":
      let raw = body["network"] as? String ?? ""
      let identifier = body["identifier"] as? String ?? ""
      guard let network = MessageNetwork(rawValue: raw) else { return .json(["error": "réseau inconnu"], status: 400) }
      Task {
        do { try await store.startBridgeChat(network: network, identifier: identifier) } catch { store.connectionError = RelayStore.readable(error) }
      }
    case "/api/group/rename":
      Task { try? await store.renameGroup(text, conversationID: id) }
    case "/api/group/invite":
      Task { try? await store.inviteMember(text, conversationID: id) }
    case "/api/group/remove":
      Task { try? await store.removeMember(body["userID"] as? String ?? "", conversationID: id) }
    case "/api/upload":
      return upload(raw, conversationID: raw.query["id"] ?? "")
    case "/api/attachments/remove":
      store.removeAttachment(body["path"] as? String ?? "", conversationID: id)
    case "/api/undoSendDelay":
      if let seconds = body["seconds"] as? Int { store.undoSendDelay = UndoSendDelay.fromStored(seconds) }
    default:
      return .json(["error": "action inconnue : \(path)"], status: 404)
    }
    return .json(["ok": true])
  }

  // MARK: - L'état

  private func stateJSON() -> [String: Any] {
    let store = self.store
    let visible = store.visibleConversations
    let queue = store.focusQueue
    var networks: [[String: Any]] = []
    for network in store.networksInUse {
      networks.append([
        "id": network.rawValue,
        "label": network.labelFR,
        "unread": store.unreadCount(for: network),
      ])
    }
    let session: String = switch store.session {
    case .unknown: "unknown"
    case .disconnected: "disconnected"
    case .connecting: "connecting"
    case .connected: "connected"
    }
    return [
      "revision": revision,
      "session": session,
      "connectionError": store.connectionError as Any,
      "syncError": store.syncError as Any,
      "rememberedHomeserver": store.rememberedHomeserver,
      "scope": store.scope.rawValue,
      "scopes": InboxScope.allCases.map { ["id": $0.rawValue, "label": $0.labelFR] },
      "filter": store.filter.rawValue,
      "filters": ConversationFilter.allCases.map { ["id": $0.rawValue, "label": $0.labelFR] },
      "networkFilter": store.networkFilter?.rawValue as Any,
      "networks": networks,
      "unreadTotal": store.unreadCount(for: nil),
      "conversations": visible.map(conversationJSON),
      "focusQueue": queue.map(\.id),
      "selectedID": store.selectedConversationID as Any,
      "focusID": store.focusConversationID as Any,
      "isIncognito": store.isIncognito,
      "agentMode": store.agentDefaultMode.rawValue,
      "agentModes": AgentSettings.Mode.allCases.map { ["id": $0.rawValue, "label": $0.labelFR, "subtitle": $0.subtitleFR] },
      "readArchivableCount": store.readArchivableConversations.count,
      "scheduledCount": store.scheduled.count,
      "reminderSuggestions": ConversationReminder.suggestions().map { ["title": $0.title, "at": $0.date.timeIntervalSince1970] },
      "undoSendDelay": store.undoSendDelay.rawValue,
      "undoSendDelays": UndoSendDelay.allCases.map { ["seconds": $0.rawValue, "label": $0.labelFR] },
      "forwarding": store.forwardingMessage.map { ["id": $0.id, "conversationID": $0.conversationID, "text": $0.sidebarPreviewText] } as Any,
      "device": Platform.deviceDisplayName,
      "tailcat": store.tailcat?.estActif == true,
      "note": Self.derniereNote as Any,
    ]
  }

  private func conversationJSON(_ conversation: Conversation) -> [String: Any] {
    let store = self.store
    let id = conversation.id
    let state = store.viewState
    let signals = store.isRequest(id) ? store.requestSignals(conversation) : nil
    var json: [String: Any] = [
      "id": id,
      "network": conversation.network.rawValue,
      "networkLabel": conversation.network.labelFR,
      "title": conversation.title,
      "preview": conversation.preview,
      "lastMessageAt": conversation.lastMessageAt.timeIntervalSince1970,
      "unread": conversation.unreadCount,
      "isGroup": conversation.isGroup,
      "isFromMe": conversation.lastMessageIsFromMe,
      "isPinned": state.isPinned(id),
      "isMuted": state.isMuted(id),
      "isArchived": state.isArchived(id),
      "isRequest": store.isRequest(id),
      "isMerged": MergedContact.isMergedID(id),
      "privacy": conversation.privacy.labelFR,
      "hasClosedLock": conversation.privacy.showsClosedLock,
      "draft": state.drafts[id] ?? "",
      "hasAvatar": conversation.groupPhotoPath != nil || conversation.remoteAvatarID != nil,
      "memberAvatars": conversation.memberAvatarIDs.prefix(4).map { $0 },
      "delivery": conversation.lastDelivery?.rawValue as Any,
      "typing": store.typingLabel(id) as Any,
      "isScheduled": store.scheduled.contains { $0.conversationID == id },
    ]
    if let reminder = state.reminder(id) {
      json["reminder"] = ["wakeAt": reminder.wakeAt.timeIntervalSince1970, "label": reminder.labelFR()]
    }
    if let signals {
      json["request"] = [
        "hasWrittenBack": signals.hasWrittenBack as Any,
        "isKnown": signals.isKnownCorrespondent,
        "flagged": signals.isFlaggedByNetwork,
      ]
    }
    if MergedContact.isMergedID(id) {
      json["members"] = store.memberConversations(of: id).map { ["id": $0.id, "network": $0.network.rawValue, "label": $0.network.labelFR] }
    }
    return json
  }

  // MARK: - Le fil

  private func threadJSON(_ id: String) -> [String: Any] {
    let store = self.store
    guard !id.isEmpty, let conversation = store.conversation(id) else { return ["error": "fil inconnu"] }
    let messages = store.visibleMessages(id)
    let groups = store.groups(id, messages: messages)
    let editing = store.editingMessage(id)
    let replyTarget = store.replyTarget(id)
    let capabilities = conversation.network.capabilities
    var json: [String: Any] = [
      "id": id,
      "conversation": conversationJSON(conversation),
      "groups": groups.map(groupJSON),
      "count": messages.count,
      "draft": store.draftText(id),
      "attachments": store.attachments(id).map { ["path": $0, "name": URL(fileURLWithPath: $0).lastPathComponent, "isImage": Self.looksLikeImage($0)] },
      "canSend": store.canSend(id),
      "isSending": store.isSending(id),
      "isLoadingOlder": store.isLoadingOlder,
      "sendingNetwork": store.sendingNetwork(id)?.labelFR as Any,
      "typing": store.typingLabel(id) as Any,
      "seenBy": store.seenByLabel(id) as Any,
      "capabilities": [
        "edits": capabilities.editsSentMessages,
        "renamesGroup": store.canRenameGroup(id),
        "removesMember": store.canRemoveMember(id),
        "addsMember": store.canInviteMember(id),
      ],
    ]
    if let editing { json["editing"] = ["id": editing.id, "text": editing.text] }
    if let replyTarget { json["replyTo"] = ["id": replyTarget.id, "sender": replyTarget.displayedSenderName ?? (replyTarget.isFromMe ? "Moi" : conversation.title), "text": replyTarget.sidebarPreviewText] }
    return json
  }

  private func groupJSON(_ group: MessageGroup) -> [String: Any] {
    var json: [String: Any] = [
      "id": group.id,
      "isFromMe": group.isFromMe,
      "messages": group.messages.map(messageJSON),
      "showsNetworkOrigin": group.showsNetworkOrigin,
    ]
    if let label = group.senderLabel { json["sender"] = label }
    if let separator = group.timeSeparator { json["separator"] = separator.timeIntervalSince1970 }
    if let network = group.network { json["network"] = network.rawValue; json["networkLabel"] = network.labelFR }
    return json
  }

  private func messageJSON(_ message: ChatMessage) -> [String: Any] {
    let store = self.store
    var json: [String: Any] = [
      "id": message.id,
      "text": message.text,
      "sentAt": message.sentAt.timeIntervalSince1970,
      "isFromMe": message.isFromMe,
      "isPending": message.isPending,
      "isRetracted": message.isRetracted,
      "isEmojiOnly": message.isEmojiOnly,
      "senderName": message.displayedSenderName as Any,
      "canEdit": store.canEdit(message),
      "canDelete": store.canDeleteEverywhere(message),
      "canForward": store.canForward(message),
      "canUndo": store.canUndoSend(message.id),
      "myReaction": message.myReactionEmoji as Any,
      "reactions": message.reactions.map { ["emoji": $0.emoji, "count": $0.count, "isMine": $0.isMine, "senders": $0.senders] },
      "attachments": message.attachments.map(AttachmentRepair.repaired).map(attachmentJSON),
      "links": TextLinks.detect(in: message.text).map { ["text": String(message.text[$0.range]), "url": $0.url.absoluteString] },
    ]
    if let editedAt = message.editedAt { json["editedAt"] = editedAt.timeIntervalSince1970 }
    if let quote = message.replyTo { json["replyTo"] = ["id": quote.messageID as Any, "sender": quote.senderName, "text": quote.text] }
    if let system = message.systemEventText { json["system"] = system }
    if let preview = message.linkPreview {
      json["linkPreview"] = ["url": preview.url, "title": preview.title as Any, "description": preview.description as Any, "image": preview.imageLocalPath as Any]
    }
    if let poll = message.poll {
      let total = poll.votesByVoter.values.reduce(0) { $0 + $1.count }
      json["poll"] = [
        "question": poll.question,
        "isClosed": poll.isClosed,
        "maxSelections": poll.maxSelections,
        "total": total,
        "answers": poll.answers.map { answer in
          [
            "id": answer.id,
            "text": answer.text,
            "count": poll.votesByVoter.values.filter { $0.contains(answer.id) }.count,
            "mine": poll.myAnswerIDs.contains(answer.id),
          ]
        },
      ]
    }
    if let proposal = message.agentProposal { json["proposal"] = ["agent": proposal.agent, "text": proposal.text] }
    if let aside = message.agentAside { json["aside"] = aside.footnoteFR }
    if let effect = message.expressiveEffectName { json["effect"] = effect }
    return json
  }

  private func attachmentJSON(_ attachment: MessageAttachment) -> [String: Any] {
    var json: [String: Any] = [
      "id": attachment.id,
      "contentType": attachment.contentType,
      "filename": attachment.filename as Any,
      "isImage": attachment.isImage,
      "isVideo": attachment.isVideo,
      "isGIF": attachment.isGIF,
      "isAudio": attachment.isAudio,
      "localPath": attachment.resolvedFileURL?.path as Any,
    ]
    if let voice = attachment.voice { json["voice"] = ["duration": voice.duration, "waveform": voice.waveform] }
    return json
  }

  // MARK: - Recherche

  private func searchJSON(_ query: String) -> [String: Any] {
    let store = self.store
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return ["conversations": [], "messages": []] }
    let index = store.searchIndex(query: trimmed)
    let needle = trimmed.lowercased()
    let conversations = store.conversations.filter { conversation in
      conversation.title.lowercased().contains(needle) || index[conversation.id] != nil
    }.prefix(40)
    let messages = store.conversations.flatMap { conversation in
      store.visibleMessages(conversation.id).filter { $0.text.lowercased().contains(needle) }.suffix(3).map { message in
        ["conversationID": conversation.id, "title": conversation.title, "messageID": message.id, "text": message.sidebarPreviewText, "sentAt": message.sentAt.timeIntervalSince1970] as [String: Any]
      }
    }.prefix(60)
    return [
      "conversations": conversations.map { ["id": $0.id, "title": $0.title, "network": $0.network.rawValue, "excerpt": index[$0.id] ?? $0.preview] },
      "messages": Array(messages),
    ]
  }

  private func facetsJSON(facet raw: String, query: String) -> [String: Any] {
    guard let facet = MessageFacet(rawValue: raw) else { return ["hits": []] }
    let hits = store.facetHits(facet: facet, query: query).prefix(80)
    return ["hits": hits.map { hit in
      ["conversationID": hit.conversation.id, "title": hit.conversation.title, "message": messageJSON(hit.message)] as [String: Any]
    }]
  }

  private func membersJSON(body: [String: String]) async -> HTTPServer.Response {
    let id = body["id"] ?? ""
    let members = await store.members(id)
    return .json(["members": members.map { ["userID": $0.userID, "name": $0.name] }])
  }

  // MARK: - Fichiers

  private func page() -> HTTPServer.Response {
    guard var response = HTTPServer.Response.file(uiDirectory.appendingPathComponent("index.html")) else {
      return .text("L'interface est introuvable : \(uiDirectory.path). Donne son dossier avec --ui ou CORRESPONDANCE_UI.", status: 500)
    }
    response.headers["Cache-Control"] = "no-store"
    return response
  }

  private func staticFile(_ name: String) -> HTTPServer.Response {
    guard !name.contains(".."), let response = HTTPServer.Response.file(uiDirectory.appendingPathComponent(name)) else {
      return .text("introuvable", status: 404)
    }
    return response
  }

  private func font(_ name: String) -> HTTPServer.Response {
    guard !name.contains(".."), name.hasSuffix(".ttf") || name.hasSuffix(".woff2"),
          var response = HTTPServer.Response.file(fontsDirectory.appendingPathComponent(name))
    else { return .text("introuvable", status: 404) }
    response.headers["Cache-Control"] = "public, max-age=31536000, immutable"
    return response
  }

  /// Un fichier du disque, seulement s'il vient d'un dossier à nous : le
  /// cache des pièces jointes, le dossier de données, ou ce qu'on vient de
  /// déposer pour l'envoi.
  private func file(_ path: String) -> HTTPServer.Response {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    let allowed = [MatrixAttachmentStore.directory, CorrespondanceHome.directory(), Self.uploadDirectory]
      .map { $0.standardizedFileURL.path }
    guard allowed.contains(where: { url.path.hasPrefix($0 + "/") }) else { return .text("refusé", status: 403) }
    guard let response = HTTPServer.Response.file(url) else { return .text("introuvable", status: 404) }
    return response
  }

  private func avatar(_ id: String) async -> HTTPServer.Response {
    guard let conversation = store.conversation(id) else { return .text("introuvable", status: 404) }
    if let path = conversation.groupPhotoPath, let response = HTTPServer.Response.file(URL(fileURLWithPath: path)) {
      return response
    }
    guard let mxc = conversation.remoteAvatarID, mxc.hasPrefix("mxc://") else { return .text("pas de photo", status: 404) }
    if let cached = avatarCache[mxc] {
      return HTTPServer.Response(status: 200, headers: ["Content-Type": "image/jpeg", "Cache-Control": "private, max-age=86400"], body: cached)
    }
    guard let data = await store.matrix.avatarData(mxcURI: mxc) else { return .text("pas de photo", status: 404) }
    avatarCache[mxc] = data
    return HTTPServer.Response(status: 200, headers: ["Content-Type": "image/jpeg", "Cache-Control": "private, max-age=86400"], body: data)
  }

  /// Le dossier où atterrit ce que le navigateur dépose avant l'envoi.
  static let uploadDirectory: URL = {
    let dir = CorrespondanceHome.directory().appendingPathComponent("envois", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }()

  /// Un fichier arrive en corps brut, son nom dans l'en-tête `X-File-Name`.
  private func upload(_ request: HTTPServer.Request, conversationID: String) -> HTTPServer.Response {
    guard !conversationID.isEmpty else { return .json(["error": "fil manquant"], status: 400) }
    let rawName = (request.header("x-file-name") ?? "fichier").removingPercentEncoding ?? "fichier"
    let safe = rawName.components(separatedBy: CharacterSet(charactersIn: "/\\")).last ?? "fichier"
    let url = Self.uploadDirectory.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(safe)")
    do { try request.body.write(to: url) } catch { return .json(["error": "écriture impossible"], status: 500) }
    store.addAttachment(url.path, conversationID: conversationID)
    return .json(["ok": true, "path": url.path])
  }

  private static func looksLikeImage(_ path: String) -> Bool {
    ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
  }

  // MARK: - Événements

  private func events() -> HTTPServer.Response {
    let api = self
    return .eventStream { sink in
      Task { @MainActor in
        api.sinks.append(sink)
        sink.send(event: "hello", data: "{\"revision\":\(api.revision)}")
      }
      // Un battement toutes les vingt secondes : c'est ce qui dit qu'un
      // navigateur fermé a lâché la connexion, et évite qu'un mandataire
      // ne la coupe pour inactivité.
      while sink.isOpen {
        Thread.sleep(forTimeInterval: 20)
        sink.send(event: "ping", data: "{}")
      }
    }
  }
}
