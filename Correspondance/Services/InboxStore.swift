import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class InboxStore {
  var mode: InboxMode = .focus {
    didSet { UserDefaults.standard.set(mode.rawValue, forKey: Keys.mode) }
  }

  var conversations: [Conversation] = []
  var selectedConversationID: String?
  var messages: [ChatMessage] = []
  var draftText: String = ""
  /// Chemins locaux d’images à envoyer (Signal).
  var pendingAttachmentPaths: [String] = []
  var isLoading = false
  /// Sync receive en cours (poll live).
  var isLiveSyncing = false
  var isSending = false
  var lastErrorMessage: String?
  var iMessageStatusFR: String = "…"
  var signalStatusFR: String = "…"
  var usingDemoData = false
  /// true tant que le premier plein chargement n’a pas fini (après hydrate cache).
  var isInitialSync = true

  private let iMessageDB = IMessageDatabase()
  private let iMessageSender = IMessageSender()
  private let signal = SignalBridge()
  private var loadTask: Task<Void, Never>?
  private var liveSyncTask: Task<Void, Never>?

  var selectedConversation: Conversation? {
    guard let selectedConversationID else { return nil }
    return conversations.first { $0.id == selectedConversationID }
  }

  var activeQueue: [Conversation] {
    conversations
      .filter { !$0.isArchived }
      .sorted(by: Self.sortForInbox)
  }

  var inboxRecents: [Conversation] {
    activeQueue.filter(\.hasLivePreview)
  }

  var inboxGroups: [Conversation] {
    activeQueue.filter { $0.isGroup && !$0.hasLivePreview }
      .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
  }

  var inboxContacts: [Conversation] {
    activeQueue.filter { !$0.isGroup && !$0.hasLivePreview }
      .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
  }

  private static func sortForInbox(_ a: Conversation, _ b: Conversation) -> Bool {
    let rank: (Conversation) -> Int = { c in
      if c.hasLivePreview { return 0 }
      if c.isGroup { return 1 }
      return 2
    }
    let ra = rank(a), rb = rank(b)
    if ra != rb { return ra < rb }
    if a.hasLivePreview || b.hasLivePreview {
      return a.lastMessageAt > b.lastMessageAt
    }
    return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
  }

  var focusIndex: Int? {
    guard let id = selectedConversationID else { return nil }
    return activeQueue.firstIndex { $0.id == id }
  }

  init() {
    if let raw = UserDefaults.standard.string(forKey: Keys.mode),
       let stored = InboxMode(rawValue: raw)
    {
      mode = stored
    } else {
      mode = .focus
    }
    hydrateFromDiskCache()
  }

  /// Affiche tout de suite le cache Signal (pas d’écran vide 20 s).
  private func hydrateFromDiskCache() {
    let (stored, msgs) = SignalConversationCache.load()
    guard !stored.isEmpty else {
      signalStatusFR = "Signal : première sync…"
      return
    }
    var list = stored
    for i in list.indices {
      if let last = msgs[list[i].id]?.last {
        list[i].preview = last.text
        list[i].lastMessageAt = max(list[i].lastMessageAt, last.sentAt)
      }
    }
    conversations = list.sorted(by: Self.sortForInbox)
    selectedConversationID = inboxRecents.first?.id
      ?? inboxGroups.first?.id
      ?? activeQueue.first?.id
    let groups = list.filter(\.isGroup).count
    let live = list.filter { $0.hasLivePreview }.count
    signalStatusFR = "Cache · \(list.count) fils · \(groups) groupes · \(live) avec messages — sync…"
    if let id = selectedConversationID, let cached = msgs[id], !cached.isEmpty {
      messages = cached
    }
  }

  /// Point d’entrée app : hydrate (déjà fait) + plein load + boucle receive.
  func start() async {
    await load()
    startLiveSync()
  }

  func load() async {
    loadTask?.cancel()
    let task = Task { @MainActor in
      await self.performLoad()
    }
    loadTask = task
    await task.value
  }

  func refresh() async {
    await load()
  }

  func startLiveSync() {
    liveSyncTask?.cancel()
    liveSyncTask = Task { @MainActor [weak self] in
      // Petite pause après le load initial pour ne pas empiler 2 signal-cli.
      try? await Task.sleep(for: .seconds(2))
      while let self, !Task.isCancelled {
        await self.pollSignalOnce()
        try? await Task.sleep(for: .seconds(10))
      }
    }
  }

  func stopLiveSync() {
    liveSyncTask?.cancel()
    liveSyncTask = nil
  }

  func select(_ id: String?) async {
    selectedConversationID = id
    draftText = ""
    pendingAttachmentPaths = []
    if let id { clearUnread(for: id) }
    await loadMessagesForSelection()
  }

  func setMode(_ newMode: InboxMode) {
    mode = newMode
  }

  func archiveSelected() async {
    guard let id = selectedConversationID,
          let index = conversations.firstIndex(where: { $0.id == id })
    else { return }

    conversations[index].isArchived = true
    let next = activeQueue.first?.id
    await select(next)
  }

  func focusNext() async {
    guard let index = focusIndex, index + 1 < activeQueue.count else { return }
    await select(activeQueue[index + 1].id)
  }

  func focusPrevious() async {
    guard let index = focusIndex, index > 0 else { return }
    await select(activeQueue[index - 1].id)
  }

  func pickAttachments() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.allowedContentTypes = [.image]
    panel.message = "Choisir une ou plusieurs images"
    guard panel.runModal() == .OK else { return }
    let paths = panel.urls.map(\.path)
    pendingAttachmentPaths.append(contentsOf: paths)
  }

  func sendDraft() async {
    let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
    let attachments = pendingAttachmentPaths
    guard let conversation = selectedConversation else { return }
    guard !text.isEmpty || !attachments.isEmpty else { return }

    if usingDemoData && conversation.network == .iMessage {
      lastErrorMessage = "Données démo — accorde l’accès disque pour envoyer via Messages."
      return
    }

    if conversation.network == .iMessage, !attachments.isEmpty {
      lastErrorMessage = "Envoi d’images iMessage pas encore branché — Signal seulement pour l’instant."
      return
    }

    isSending = true
    defer { isSending = false }

    let outgoingAttachments: [MessageAttachment] = attachments.map { path in
      let url = URL(fileURLWithPath: path)
      return MessageAttachment(
        id: url.lastPathComponent,
        contentType: "image/jpeg",
        filename: url.lastPathComponent,
        localPath: path
      )
    }

    let optimistic = ChatMessage(
      id: "local-\(UUID().uuidString)",
      conversationID: conversation.id,
      network: conversation.network,
      text: text.isEmpty && !attachments.isEmpty ? "📷 Photo" : text,
      sentAt: Date(),
      isFromMe: true,
      isPending: true,
      attachments: outgoingAttachments
    )
    messages.append(optimistic)
    draftText = ""
    pendingAttachmentPaths = []

    do {
      switch conversation.network {
      case .iMessage:
        try await iMessageSender.send(text: text, toAddress: conversation.address)
      case .signal:
        try await signal.send(
          text: text,
          conversation: conversation,
          attachmentPaths: attachments
        )
      }
      if let idx = messages.firstIndex(where: { $0.id == optimistic.id }) {
        messages[idx].isPending = false
      }
      applySidebarPreview(conversationID: conversation.id, from: messages)
    } catch {
      messages.removeAll { $0.id == optimistic.id }
      draftText = text
      pendingAttachmentPaths = attachments
      lastErrorMessage = error.localizedDescription
    }
  }

  // MARK: - Private

  private func pollSignalOnce() async {
    // Évite de concurrencer un plein refresh.
    guard !isLoading else { return }
    isLiveSyncing = true
    defer { isLiveSyncing = false }

    do {
      let countsBefore = await signal.messageCounts()
      let updated = try await signal.pollReceive(timeoutSeconds: 8)
      guard !Task.isCancelled else { return }
      let countsAfter = await signal.messageCounts()
      var deltas: [String: Int] = [:]
      for (id, after) in countsAfter {
        let before = countsBefore[id] ?? 0
        let delta = after - before
        if delta > 0 { deltas[id] = delta }
      }
      await mergeSignalConversations(updated, newMessageDeltas: deltas)
      signalStatusFR = "Signal live · \(updated.filter(\.isGroup).count) groupes · \(updated.filter(\.hasLivePreview).count) actifs"
      if let id = selectedConversationID,
         conversations.first(where: { $0.id == id })?.network == .signal
      {
        let cached = await signal.fetchMessages(conversationID: id)
        if !cached.isEmpty {
          messages = cached
          applySidebarPreview(conversationID: id, from: cached)
        }
        clearUnread(for: id)
      }
    } catch {
      // Silencieux en live — pas d’alerte toutes les 10 s.
      signalStatusFR = "Signal live : \(error.localizedDescription)"
    }
  }

  private func mergeSignalConversations(
    _ signalList: [Conversation],
    newMessageDeltas: [String: Int] = [:]
  ) async {
    var previews = await signal.previewMap()
    var byID = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })

    for var incoming in signalList {
      if let p = previews[incoming.id] {
        incoming.preview = p.text
        incoming.lastMessageAt = max(incoming.lastMessageAt, p.date)
      }
      if var existing = byID[incoming.id] {
        if incoming.hasLivePreview {
          existing.preview = incoming.preview
          existing.lastMessageAt = max(existing.lastMessageAt, incoming.lastMessageAt)
          existing.title = incoming.title
        }
        existing.isGroup = incoming.isGroup || existing.isGroup
        byID[incoming.id] = existing
      } else {
        // Ne pas copier un unreadCount venant du catalogue Signal (souvent 0).
        incoming.unreadCount = byID[incoming.id]?.unreadCount ?? 0
        byID[incoming.id] = incoming
      }
    }

    for (id, p) in previews {
      guard var c = byID[id] else { continue }
      c.preview = p.text
      c.lastMessageAt = max(c.lastMessageAt, p.date)
      byID[id] = c
    }

    for (id, delta) in newMessageDeltas where delta > 0 {
      guard id != selectedConversationID, var c = byID[id] else { continue }
      c.unreadCount += delta
      byID[id] = c
    }

    conversations = Array(byID.values).sorted(by: Self.sortForInbox)
  }

  private func clearUnread(for id: String) {
    guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
    guard conversations[idx].unreadCount != 0 else { return }
    var updated = conversations[idx]
    updated.unreadCount = 0
    conversations[idx] = updated
  }

  private func performLoad() async {
    isLoading = true
    defer {
      isLoading = false
      isInitialSync = false
    }

    iMessageStatusFR = "iMessage : actualisation…"
    if conversations.isEmpty {
      signalStatusFR = "Signal : actualisation…"
    } else {
      signalStatusFR = "Signal : sync en arrière-plan…"
    }

    async let iMessagePart: IMessageLoad = loadIMessageOffMain()

    let status = await signal.statusMessageFR()
    if Task.isCancelled { return }
    signalStatusFR = status

    let signalResult: Result<[Conversation], Error>
    do {
      signalResult = .success(try await signal.fetchConversations())
    } catch {
      signalResult = .failure(error)
    }

    let im = await iMessagePart
    if Task.isCancelled { return }

    var merged: [Conversation] = []
    usingDemoData = false

    switch im {
    case .success(let list):
      merged.append(contentsOf: list)
      iMessageStatusFR = list.isEmpty
        ? "Messages accessible — aucune conversation texte récente."
        : "\(list.count) conversations iMessage."
    case .denied(let message):
      iMessageStatusFR = message
      merged.append(contentsOf: Self.demoConversations())
      usingDemoData = true
    case .failure(let message):
      iMessageStatusFR = message
      merged.append(contentsOf: Self.demoConversations())
      usingDemoData = true
    }

    switch signalResult {
    case .success(let list):
      if usingDemoData {
        merged.removeAll { $0.network == .signal && $0.transportKey == "demo" }
      }
      var signalList = list
      let previews = await signal.previewMap()
      for i in signalList.indices {
        if let p = previews[signalList[i].id] {
          signalList[i].preview = p.text
          signalList[i].lastMessageAt = max(signalList[i].lastMessageAt, p.date)
        }
      }
      merged.append(contentsOf: signalList)
      let groups = signalList.filter(\.isGroup).count
      let dms = signalList.count - groups
      if signalList.isEmpty {
        signalStatusFR += " Aucune conversation — réessaie Actualiser."
      } else {
        let liveGroups = signalList.filter { $0.isGroup && $0.hasLivePreview }.count
        signalStatusFR += " \(dms) DM · \(groups) groupes (\(liveGroups) avec messages)."
      }
    case .failure(let error):
      let previousSignal = conversations.filter { $0.network == .signal }
      merged.append(contentsOf: previousSignal)
      lastErrorMessage = "Signal : \(error.localizedDescription)"
      if !previousSignal.isEmpty {
        signalStatusFR += " (cache local · \(previousSignal.filter(\.isGroup).count) groupes)"
      }
    }

    let keepSelection = selectedConversationID
    conversations = merged.sorted(by: Self.sortForInbox)

    if keepSelection == nil
      || !conversations.contains(where: { $0.id == keepSelection })
    {
      selectedConversationID = inboxRecents.first?.id
        ?? inboxGroups.first?.id
        ?? activeQueue.first?.id
    } else {
      selectedConversationID = keepSelection
    }
    await loadMessagesForSelection()
  }

  private enum IMessageLoad: Sendable {
    case success([Conversation])
    case denied(String)
    case failure(String)
  }

  private func loadIMessageOffMain() async -> IMessageLoad {
    let db = iMessageDB
    return await Task.detached(priority: .userInitiated) {
      do {
        let list = try db.fetchConversations()
        return .success(list)
      } catch let error as IMessageAccessError {
        if case .authorizationDenied = error {
          return .denied(error.localizedDescription)
        }
        return .failure(error.localizedDescription)
      } catch {
        return .failure(error.localizedDescription)
      }
    }.value
  }

  private func loadMessagesForSelection() async {
    guard let conversation = selectedConversation else {
      messages = []
      return
    }

    switch conversation.network {
    case .iMessage:
      if usingDemoData {
        messages = Self.demoMessages(for: conversation.id)
        return
      }
      guard let guid = IMessageDatabase.guid(fromConversationID: conversation.id) else {
        messages = []
        return
      }
      let db = iMessageDB
      do {
        messages = try await Task.detached(priority: .userInitiated) {
          try db.fetchMessages(chatGUID: guid)
        }.value
      } catch {
        lastErrorMessage = error.localizedDescription
        messages = []
      }
    case .signal:
      await signal.ensureMemoryCacheLoaded()
      var cached = await signal.fetchMessages(conversationID: conversation.id)
      if cached.isEmpty && isInitialSync {
        messages = [
          ChatMessage(
            id: "signal-sync-\(conversation.id)",
            conversationID: conversation.id,
            network: .signal,
            text: "Synchronisation Signal…",
            sentAt: Date(),
            isFromMe: false
          )
        ]
      }
      if cached.isEmpty {
        cached = await signal.pullLatestMessages(for: conversation.id)
      }
      if !cached.isEmpty {
        messages = cached
        applySidebarPreview(conversationID: conversation.id, from: cached)
      } else if messages.isEmpty || messages.first?.id.hasPrefix("signal-") == true {
        messages = [
          ChatMessage(
            id: "signal-empty-\(conversation.id)",
            conversationID: conversation.id,
            network: .signal,
            text: isInitialSync || isLiveSyncing
              ? "Synchronisation… les messages arriveront tout seuls (comme Signal)."
              : "Pas encore de messages pour ce fil. Écris ci-dessous, ou attends le prochain message.",
            sentAt: Date(),
            isFromMe: false
          )
        ]
      }
    }
  }

  private func applySidebarPreview(conversationID: String, from messages: [ChatMessage]) {
    guard let last = messages.last,
          let idx = conversations.firstIndex(where: { $0.id == conversationID })
    else { return }
    if last.id.hasPrefix("signal-empty-") || last.id.hasPrefix("signal-sync-") { return }
    var updated = conversations[idx]
    updated.preview = last.sidebarPreviewText
    updated.lastMessageAt = last.sentAt
    conversations[idx] = updated
  }

  private enum Keys {
    static let mode = "correspondance.inboxMode"
  }

  private static func demoConversations() -> [Conversation] {
    let now = Date()
    return [
      Conversation(
        id: "imessage:demo-1",
        network: .iMessage,
        address: "+33600000001",
        title: "Marie (démo)",
        preview: "On se voit demain ?",
        lastMessageAt: now.addingTimeInterval(-400),
        unreadCount: 1,
        isArchived: false,
        transportKey: "demo",
        isGroup: false
      ),
      Conversation(
        id: "imessage:demo-2",
        network: .iMessage,
        address: "+33600000002",
        title: "Julien (démo)",
        preview: "Merci pour le lien.",
        lastMessageAt: now.addingTimeInterval(-8_000),
        unreadCount: 0,
        isArchived: false,
        transportKey: "demo",
        isGroup: false
      ),
    ]
  }

  private static func demoMessages(for conversationID: String) -> [ChatMessage] {
    let now = Date()
    return [
      ChatMessage(
        id: "d1",
        conversationID: conversationID,
        network: .iMessage,
        text: "Salut — tu as deux minutes ?",
        sentAt: now.addingTimeInterval(-3_600),
        isFromMe: false
      ),
      ChatMessage(
        id: "d2",
        conversationID: conversationID,
        network: .iMessage,
        text: "Oui, dis-moi.",
        sentAt: now.addingTimeInterval(-3_400),
        isFromMe: true
      ),
      ChatMessage(
        id: "d3",
        conversationID: conversationID,
        network: .iMessage,
        text: "On se voit demain ?",
        sentAt: now.addingTimeInterval(-400),
        isFromMe: false
      ),
    ]
  }
}
