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

  /// Rail de réseaux : `nil` = « Tous ». Persisté (UserDefaults).
  var networkFilter: MessageNetwork? {
    didSet { UserDefaults.standard.set(networkFilter?.rawValue ?? "", forKey: Keys.networkFilter) }
  }

  var conversations: [Conversation] = [] {
    // La normalisation ré-assigne `conversations` : la passe suivante ne trouve
    // plus rien à corriger et laisse passer la notification.
    didSet {
      if normalizeArchiveState() { return }
      conversationsDidChange()
    }
  }
  /// Vue « Archivés » de la liste (⌘⇧E). Ne change rien au stockage.
  var isShowingArchived = false
  /// Champ `.searchable` de la liste. Vide = pas de filtrage.
  var searchQuery = ""
  /// Recherche dans le fil ouvert (⌘F).
  var isThreadSearchActive = false
  var threadSearchQuery = "" {
    didSet { refreshThreadSearchMatches() }
  }
  /// Identifiants des messages qui contiennent la requête, dans l'ordre du fil.
  private(set) var threadSearchMatchIDs: [String] = []
  /// Index du match courant dans `threadSearchMatchIDs`.
  private(set) var threadSearchCursor = 0
  var selectedConversationID: String?
  var messages: [ChatMessage] = []
  var draftText: String = ""
  /// Chemins locaux d’images à envoyer (Signal).
  var pendingAttachmentPaths: [String] = []
  /// True seulement pendant la frappe active (pas le simple focus).
  /// Le chrome Focus se tait le temps d’écrire, puis revient à la pause.
  var isComposerFocused = false
  var isLoading = false
  /// Sync receive en cours (poll live).
  var isLiveSyncing = false
  var isSending = false
  var lastErrorMessage: String?
  var iMessageStatusFR: String = "…"
  var signalStatusFR: String = "…"
  var matrixStatusFR: String = "…"
  var contactsStatusFR: String = "…"
  /// Affiche une bannière si Contacts n’est pas encore autorisé.
  var needsContactsPermission = false
  var messagesAutomationStatusFR = "…"
  var notificationStatusFR: String = "…"
  var isPresentingNewConversation = false
  /// Matrix joignable et session valide — conditionne WhatsApp dans l'UI.
  var isMatrixConnected = false
  /// Feuille « Connecter WhatsApp ».
  var isPresentingWhatsAppLogin = false
  var whatsAppLoginQRData: Data?
  var whatsAppLoginPairingCode: String?
  var whatsAppLoginStatusFR = "…"
  var usingDemoData = false
  /// true tant que le premier plein chargement n’a pas fini (après hydrate cache).
  var isInitialSync = true

  /// Préférences locales (pin / mute / timer) — pas dans le catalogue Signal.
  private(set) var pinnedIDs: Set<String> = []
  private(set) var mutedIDs: Set<String> = []
  /// Fils archivés — persistés, donc réappliqués à chaque fusion (le catalogue
  /// d'un réseau ne connaît pas notre archivage et renvoie toujours `isArchived: false`).
  private(set) var archivedIDs: Set<String> = []
  private(set) var disappearingSecondsByID: [String: Int] = [:]

  private let iMessageDB = IMessageDatabase()
  private let iMessageSender = IMessageSender()
  private let signal = SignalBridge()
  private let matrix = MatrixBridgeService()
  private var loadTask: Task<Void, Never>?
  private var liveSyncTask: Task<Void, Never>?
  /// Boucle `/sync` : long-poll dédié, indépendant du poll signal-cli.
  private var matrixSyncTask: Task<Void, Never>?
  private var whatsAppLoginTask: Task<Void, Never>?
  /// Dernier `lastMessageAt` déjà notifié, par conversation — évite de re-sonner
  /// pour un fil qu'un simple refresh a fait remonter sans nouveau message.
  private var lastNotifiedAt: [String: Date] = [:]
  /// État de référence pour la comparaison : `oldValue` du `didSet` ne convient pas,
  /// la normalisation de l'archivage produit une passe intermédiaire.
  private var notificationBaseline: [String: Conversation] = [:]
  /// Corps replié des messages, par conversation — l'index de recherche, en mémoire.
  /// Alimenté par les trois caches disque puis par chaque fil ouvert.
  private var searchIndex: [String: String] = [:]
  /// Le premier plein chargement ne notifie rien : sinon toute l'inbox sonne au lancement.
  private var isNotificationPrimed = false

  var selectedConversation: Conversation? {
    guard let selectedConversationID else { return nil }
    return conversations.first { $0.id == selectedConversationID }
  }

  var activeQueue: [Conversation] {
    conversations
      .filter { !$0.isArchived && matchesNetworkFilter($0) }
      .sorted(by: { sortForInbox($0, $1) })
  }

  /// File complète, rail ignoré — pour les compteurs et le repli de sélection.
  var unfilteredQueue: [Conversation] {
    conversations
      .filter { !$0.isArchived }
      .sorted(by: { sortForInbox($0, $1) })
  }

  private func matchesNetworkFilter(_ conversation: Conversation) -> Bool {
    guard let networkFilter else { return true }
    return conversation.network == networkFilter
  }

  /// Non-lus du rail. `nil` = « Tous ».
  func unreadCount(for network: MessageNetwork?) -> Int {
    conversations.reduce(0) { total, conversation in
      guard !conversation.isArchived else { return total }
      guard network == nil || conversation.network == network else { return total }
      return total + conversation.unreadCount
    }
  }

  /// Le rail n'affiche un réseau que s'il est réellement branché ou déjà peuplé.
  func hasConversations(on network: MessageNetwork) -> Bool {
    conversations.contains { !$0.isArchived && $0.network == network }
  }

  func setNetworkFilter(_ network: MessageNetwork?) {
    guard networkFilter != network else { return }
    networkFilter = network
  }

  /// Applique la recherche de la liste. Sans requête, renvoie la file telle quelle.
  private func searched(_ list: [Conversation]) -> [Conversation] {
    ConversationSearch.filter(list, query: searchQuery, index: searchIndex)
  }

  var isSearching: Bool { !ConversationSearch.fold(searchQuery).isEmpty }

  var inboxRecents: [Conversation] {
    // En recherche, la partition Récents / Groupes / Contacts n'a plus de sens :
    // tout ce qui correspond remonte dans une seule liste.
    if isSearching { return searched(activeQueue) }
    return activeQueue.filter(\.hasLivePreview)
  }

  var inboxGroups: [Conversation] {
    if isSearching { return [] }
    return activeQueue.filter { $0.isGroup && !$0.hasLivePreview }
      .sorted { lhs, rhs in
        if isPinned(lhs.id) != isPinned(rhs.id) { return isPinned(lhs.id) }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
      }
  }

  var inboxContacts: [Conversation] {
    if isSearching { return [] }
    return activeQueue.filter { !$0.isGroup && !$0.hasLivePreview }
      .sorted { lhs, rhs in
        if isPinned(lhs.id) != isPinned(rhs.id) { return isPinned(lhs.id) }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
      }
  }

  func isPinned(_ id: String) -> Bool { pinnedIDs.contains(id) }
  func isMuted(_ id: String) -> Bool { mutedIDs.contains(id) }
  func disappearingSeconds(for id: String) -> Int { disappearingSecondsByID[id] ?? 0 }

  private func sortForInbox(_ a: Conversation, _ b: Conversation) -> Bool {
    if isPinned(a.id) != isPinned(b.id) { return isPinned(a.id) }
    return Self.sortForInbox(a, b)
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
    if let raw = UserDefaults.standard.string(forKey: Keys.networkFilter), !raw.isEmpty {
      networkFilter = MessageNetwork(rawValue: raw)
    }
    pinnedIDs = Set(UserDefaults.standard.stringArray(forKey: Keys.pinnedIDs) ?? [])
    mutedIDs = Set(UserDefaults.standard.stringArray(forKey: Keys.mutedIDs) ?? [])
    archivedIDs = Set(UserDefaults.standard.stringArray(forKey: Keys.archivedIDs) ?? [])
    if let data = UserDefaults.standard.data(forKey: Keys.disappearing),
       let decoded = try? JSONDecoder().decode([String: Int].self, from: data)
    {
      disappearingSecondsByID = decoded
    }
    hydrateFromDiskCache()
  }

  /// Affiche tout de suite les caches iMessage + Signal (démarrage type Messages).
  private func hydrateFromDiskCache() {
    var list: [Conversation] = []

    var iMessage = IMessageConversationCache.load()
    if !iMessage.isEmpty {
      // Noms depuis cache Contacts — immédiat, sans permission.
      ContactDirectoryDisk.enrichIMessageTitles(&iMessage)
      list.append(contentsOf: iMessage)
      iMessageStatusFR = "Cache · \(iMessage.count) iMessage — sync…"
    } else {
      iMessageStatusFR = "iMessage : première sync…"
    }

    let (stored, msgs) = SignalConversationCache.load()
    if stored.isEmpty {
      signalStatusFR = list.isEmpty ? "Signal : première sync…" : "Signal : sync…"
    } else {
      var signalList = stored
      for i in signalList.indices {
        if let last = msgs[signalList[i].id]?.last {
          signalList[i].preview = last.text
          signalList[i].lastMessageAt = max(signalList[i].lastMessageAt, last.sentAt)
        }
      }
      list.append(contentsOf: signalList)
      let groups = signalList.filter(\.isGroup).count
      let live = signalList.filter { $0.hasLivePreview }.count
      signalStatusFR = "Cache · \(signalList.count) fils · \(groups) groupes · \(live) avec messages — sync…"
    }

    // Le cache Matrix est un simple fichier : lisible sans passer par l'actor.
    let (_, matrixConversations, matrixMessages) = MatrixConversationCache.load()
    seedSearchIndex(signal: msgs, matrix: matrixMessages)
    if !matrixConversations.isEmpty {
      list.append(contentsOf: matrixConversations)
      matrixStatusFR = "Cache · \(matrixConversations.count) fils WhatsApp — sync…"
    } else {
      matrixStatusFR = "Matrix : non connecté."
    }

    guard !list.isEmpty else { return }

    conversations = list.sorted(by: { sortForInbox($0, $1) })
    selectedConversationID = inboxRecents.first?.id
      ?? inboxGroups.first?.id
      ?? activeQueue.first?.id
    if let id = selectedConversationID {
      if let cached = msgs[id], !cached.isEmpty {
        messages = cached
      } else if let cached = matrixMessages[id], !cached.isEmpty {
        messages = cached
      }
    }
  }

  /// Point d’entrée app : hydrate (déjà fait) + plein load + boucle receive.
  func start() async {
    // Demande Contacts tout de suite (sinon l’app n’apparaît pas dans Confidentialité).
    await requestContactsPermission()
    requestMessagesAutomation()
    NotificationService.shared.onOpenConversation = { [weak self] id in
      guard let self else { return }
      Task { @MainActor in
        self.mode = .inbox
        await self.select(id)
      }
    }
    await NotificationService.shared.requestAuthorization()
    await load()
    // Ce qui est déjà là au démarrage n'est pas « nouveau » : on prend l'état pour
    // référence, puis seuls les messages suivants déclenchent une notification.
    primeNotifications()
    startLiveSync()
    startMatrixSync()
  }

  // MARK: - Recherche

  /// ⌘F : ouvre (ou referme) la barre de recherche du fil.
  func toggleThreadSearch() {
    isThreadSearchActive.toggle()
    if !isThreadSearchActive {
      threadSearchQuery = ""
    }
  }

  func closeThreadSearch() {
    isThreadSearchActive = false
    threadSearchQuery = ""
  }

  /// Message actuellement visé par la navigation ⌘F.
  var threadSearchCurrentID: String? {
    guard threadSearchMatchIDs.indices.contains(threadSearchCursor) else { return nil }
    return threadSearchMatchIDs[threadSearchCursor]
  }

  func threadSearchNext() {
    guard !threadSearchMatchIDs.isEmpty else { return }
    threadSearchCursor = (threadSearchCursor + 1) % threadSearchMatchIDs.count
  }

  func threadSearchPrevious() {
    guard !threadSearchMatchIDs.isEmpty else { return }
    threadSearchCursor = (threadSearchCursor - 1 + threadSearchMatchIDs.count) % threadSearchMatchIDs.count
  }

  private func refreshThreadSearchMatches() {
    threadSearchMatchIDs = ConversationSearch.matchingMessageIDs(in: messages, query: threadSearchQuery)
    // On repart du dernier match : c'est le plus récent, donc le plus probable.
    threadSearchCursor = max(0, threadSearchMatchIDs.count - 1)
  }

  /// Range le fil ouvert dans l'index de recherche de la liste.
  private func indexMessages(_ list: [ChatMessage], conversationID: String) {
    guard !list.isEmpty else { return }
    searchIndex[conversationID] = ConversationSearch.blob(for: list)
  }

  /// Index initial : ce que les caches disque contiennent déjà, sans une requête réseau.
  private func seedSearchIndex(
    signal: [String: [ChatMessage]],
    matrix: [String: [ChatMessage]]
  ) {
    for (id, list) in signal { searchIndex[id] = ConversationSearch.blob(for: list) }
    for (id, list) in matrix { searchIndex[id] = ConversationSearch.blob(for: list) }
  }

  /// Index iMessage : une passe SQL bornée, hors du fil principal.
  private func refreshIMessageSearchIndex() async {
    let db = iMessageDB
    let index = await Task.detached(priority: .utility) { () -> [String: String] in
      (try? db.fetchSearchIndex()) ?? [:]
    }.value
    guard !index.isEmpty else { return }
    searchIndex.merge(index) { _, fresh in fresh }
  }

  // MARK: - Notifications système

  /// Bouton « Autoriser les notifications » des Réglages.
  func requestNotificationPermission() async {
    await NotificationService.shared.requestAuthorization()
    notificationStatusFR = NotificationService.shared.authorizationStatusFR
  }

  func openNotificationSettings() {
    NotificationService.shared.openNotificationSettings()
  }

  private func primeNotifications() {
    for conversation in conversations {
      lastNotifiedAt[conversation.id] = conversation.lastMessageAt
    }
    isNotificationPrimed = true
    notificationStatusFR = NotificationService.shared.authorizationStatusFR
    updateDockBadge()
  }

  /// Un message entrant sur un fil non muet et non sélectionné = une notification.
  private func conversationsDidChange() {
    updateDockBadge()
    defer { notificationBaseline = Dictionary(conversations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }
    guard isNotificationPrimed else { return }
    for conversation in conversations {
      guard shouldNotify(conversation, previous: notificationBaseline[conversation.id]) else { continue }
      lastNotifiedAt[conversation.id] = conversation.lastMessageAt
      NotificationService.shared.postIncoming(
        conversationID: conversation.id,
        title: conversation.title,
        networkLabel: conversation.network.labelFR,
        body: conversation.preview
      )
    }
  }

  /// Réinstalle `isArchived` depuis la source de vérité persistée.
  /// Renvoie `true` si la liste a été ré-assignée (le `didSet` va repasser).
  @discardableResult
  private func normalizeArchiveState() -> Bool {
    guard let normalized = ArchiveState.normalized(conversations, archivedIDs: archivedIDs) else {
      return false
    }
    conversations = normalized
    return true
  }

  private func shouldNotify(_ conversation: Conversation, previous: Conversation?) -> Bool {
    NotificationPolicy.shouldNotify(
      current: conversation,
      previous: previous,
      isMuted: mutedIDs.contains(conversation.id),
      isSelected: conversation.id == selectedConversationID,
      alreadyNotifiedAt: lastNotifiedAt[conversation.id]
    )
  }

  /// Pastille du Dock : total des non-lus, hors fils archivés ou muets.
  private func updateDockBadge() {
    let total = conversations.reduce(0) { partial, conversation in
      guard !conversation.isArchived, !mutedIDs.contains(conversation.id) else { return partial }
      return partial + conversation.unreadCount
    }
    NotificationService.shared.updateDockBadge(count: total)
  }

  /// Boîte macOS « Correspondance souhaite contrôler Messages » (comme Beeper).
  @discardableResult
  func requestMessagesAutomation() -> Bool {
    let ok = iMessageSender.requestAutomationAccess()
    messagesAutomationStatusFR = ok
      ? "Messages : automatisation autorisée."
      : "Messages : autorise Correspondance dans Confidentialité → Automatisation."
    return ok
  }

  func openAutomationPrivacySettings() {
    let urls = [
      "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Automation",
      "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation",
    ]
    for raw in urls {
      if let url = URL(string: raw) {
        NSWorkspace.shared.open(url)
        return
      }
    }
  }

  func presentNewConversation() {
    isPresentingNewConversation = true
  }

  // MARK: - Matrix / WhatsApp

  /// Adresse par défaut du homeserver (NUC via Tailscale).
  static let defaultHomeserver = "http://relais.exemple.ts.net:8008"

  func connectMatrix(homeserver: String, user: String, password: String) async {
    let trimmed = homeserver.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
      matrixStatusFR = MatrixError.invalidHomeserver(trimmed).localizedDescription
      return
    }
    matrixStatusFR = "Matrix : connexion…"
    do {
      let creds = try await matrix.connect(homeserver: url, user: user, password: password)
      isMatrixConnected = true
      matrixStatusFR = "Matrix connecté (\(creds.userID))."
      startMatrixSync()
    } catch {
      isMatrixConnected = false
      matrixStatusFR = error.localizedDescription
    }
  }

  func disconnectMatrix() async {
    matrixSyncTask?.cancel()
    matrixSyncTask = nil
    stopWhatsAppLoginPolling()
    await matrix.disconnect()
    isMatrixConnected = false
    conversations.removeAll { $0.network.isMatrixBridged }
    if let id = selectedConversationID, !conversations.contains(where: { $0.id == id }) {
      await select(activeQueue.first?.id)
    }
    matrixStatusFR = "Matrix : déconnecté."
  }

  func refreshMatrixStatus() async {
    matrixStatusFR = await matrix.statusMessageFR()
    isMatrixConnected = await matrix.isConnected
  }

  /// Ouvre la feuille QR et lance la commande `login qr` auprès du bot.
  func presentWhatsAppLogin(phoneNumber: String? = nil) {
    whatsAppLoginQRData = nil
    whatsAppLoginPairingCode = nil
    whatsAppLoginStatusFR = "Demande du QR au bot WhatsApp…"
    isPresentingWhatsAppLogin = true
    whatsAppLoginTask?.cancel()
    whatsAppLoginTask = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        try await self.matrix.startWhatsAppLogin(usingPhoneNumber: phoneNumber)
      } catch {
        self.whatsAppLoginStatusFR = error.localizedDescription
        return
      }
      // Le bot répond en quelques secondes ; le QR tourne toutes les ~20 s.
      // Sans la moindre réponse en 90 s, on arrête : pas de boucle silencieuse.
      var silentRounds = 0
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(3))
        guard !Task.isCancelled else { return }
        do {
          let step = try await self.matrix.whatsAppLoginStep()
          if case .waiting = step {
            silentRounds += 1
            if silentRounds >= 30 {
              self.whatsAppLoginStatusFR = MatrixError.whatsAppBotSilent.localizedDescription
              return
            }
          } else {
            silentRounds = 0
          }
          switch step {
          case .qrCode(let data):
            self.whatsAppLoginQRData = data
            self.whatsAppLoginPairingCode = nil
            self.whatsAppLoginStatusFR = "Scanne ce QR : WhatsApp → Réglages → Appareils liés."
          case .pairingCode(let code):
            self.whatsAppLoginPairingCode = code
            self.whatsAppLoginStatusFR = "Saisis ce code dans WhatsApp → Appareils liés."
          case .success(let detail):
            self.whatsAppLoginStatusFR = "WhatsApp connecté. \(detail)"
            self.startMatrixSync()
            return
          case .failure(let detail):
            self.whatsAppLoginStatusFR = "Échec : \(detail)"
            return
          case .waiting:
            break
          }
        } catch {
          self.whatsAppLoginStatusFR = error.localizedDescription
          return
        }
      }
    }
  }

  func stopWhatsAppLoginPolling() {
    whatsAppLoginTask?.cancel()
    whatsAppLoginTask = nil
  }

  /// Nouvelle conversation WhatsApp : commande bot `pm <numéro>`, le salon arrive par /sync.
  func startWhatsAppConversation(phoneNumber: String) async {
    do {
      try await matrix.startWhatsAppConversation(phoneNumber: phoneNumber)
      matrixStatusFR = "WhatsApp : ouverture du fil vers \(phoneNumber)…"
      mode = .inbox
    } catch {
      lastErrorMessage = error.localizedDescription
    }
  }

  func openOrCreateConversation(network: MessageNetwork, handle: String, title: String) async {
    let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    if let existing = conversations.first(where: { Self.matchesHandle($0, network: network, handle: trimmed) }) {
      mode = .inbox
      await select(existing.id)
      return
    }

    // WhatsApp n'a pas de brouillon local : c'est le bridge qui crée le salon.
    if network.isMatrixBridged {
      await startWhatsAppConversation(phoneNumber: trimmed)
      return
    }

    let conversation = Conversation(
      id: "\(network.rawValue):compose:\(trimmed.lowercased())",
      network: network,
      address: trimmed,
      title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? trimmed : title,
      preview: "Nouvelle conversation",
      lastMessageAt: Date(),
      unreadCount: 0,
      isArchived: false,
      transportKey: trimmed,
      isGroup: false
    )
    conversations.insert(conversation, at: 0)
    mode = .inbox
    await select(conversation.id)
  }

  /// Déclenche la boîte système Contacts. À rappeler depuis Réglages / bannière.
  func requestContactsPermission() async {
    NSApp.activate(ignoringOtherApps: true)
    try? await Task.sleep(for: .milliseconds(250))

    // Reset TCC local de l’ancienne signature / état coincé (aide au debug).
    let statusBefore = ContactDirectory.shared.authorizationStatus
    contactsStatusFR = "Demande Contacts en cours… (statut \(statusBefore.rawValue))"

    // Si déjà refusé, macOS ne réaffiche plus la boîte — ouvrir Réglages.
    if statusBefore == .denied || statusBefore == .restricted {
      needsContactsPermission = true
      contactsStatusFR = "Contacts déjà refusés. Coche Correspondance dans Confidentialité → Contacts."
      openContactsPrivacySettings()
      return
    }

    let granted = await ContactDirectory.shared.requestAccessIfNeeded(force: true)
    let statusAfter = ContactDirectory.shared.authorizationStatus
    needsContactsPermission = !granted

    if granted {
      contactsStatusFR = "Contacts autorisés — noms et photos iMessage."
      Task { await enrichIMessageContactsInBackground() }
      return
    }

    switch statusAfter {
    case .denied, .restricted:
      contactsStatusFR = "Contacts refusés. Coche Correspondance dans Confidentialité → Contacts."
      openContactsPrivacySettings()
    case .notDetermined:
      contactsStatusFR = "Pas de boîte système — rebuild avec entitlement Address Book, puis reclique."
    default:
      contactsStatusFR = "Contacts non autorisés (statut \(statusAfter.rawValue))."
    }
  }

  func openContactsPrivacySettings() {
    let urls = [
      "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?path=Contacts",
      "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts",
    ]
    for raw in urls {
      if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
    }
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
    matrixSyncTask?.cancel()
    matrixSyncTask = nil
  }

  /// Boucle `/sync` Matrix : long-poll côté serveur, donc pas de sleep entre deux passes.
  func startMatrixSync() {
    matrixSyncTask?.cancel()
    matrixSyncTask = Task { @MainActor [weak self] in
      guard let self else { return }
      guard await self.matrix.restoreCursorAndCheckSession() else {
        self.isMatrixConnected = false
        self.matrixStatusFR = "Matrix : non connecté."
        return
      }
      self.isMatrixConnected = true
      var backoffSeconds = 2
      while !Task.isCancelled {
        do {
          var updated = try await self.matrix.syncOnce()
          guard !Task.isCancelled else { return }
          backoffSeconds = 2
          await ContactDirectory.shared.enrichBridgedTitles(&updated)
          self.mergeMatrixConversations(updated)
          self.matrixStatusFR = "Matrix live · \(updated.count) fils WhatsApp"
          await self.refreshSelectedMatrixMessages()
        } catch is CancellationError {
          return
        } catch {
          self.matrixStatusFR = "Matrix : \(error.localizedDescription)"
          // Coupure réseau ou homeserver au tapis : on ralentit au lieu de marteler.
          try? await Task.sleep(for: .seconds(backoffSeconds))
          backoffSeconds = min(backoffSeconds * 2, 60)
        }
      }
    }
  }

  func select(_ id: String?) async {
    selectedConversationID = id
    draftText = ""
    pendingAttachmentPaths = []
    if let id { clearUnread(for: id) }
    await loadMessagesForSelection()
    if let id { indexMessages(messages, conversationID: id) }
    refreshThreadSearchMatches()
  }

  func setMode(_ newMode: InboxMode) {
    mode = newMode
  }

  func markUnread(conversationID: String) {
    guard let idx = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
    var updated = conversations[idx]
    updated.unreadCount = max(1, updated.unreadCount)
    conversations[idx] = updated
  }

  func togglePinned(conversationID: String) {
    if pinnedIDs.contains(conversationID) {
      pinnedIDs.remove(conversationID)
    } else {
      pinnedIDs.insert(conversationID)
    }
    persistFlags()
    conversations.sort(by: { sortForInbox($0, $1) })
  }

  func toggleMuted(conversationID: String) {
    if mutedIDs.contains(conversationID) {
      mutedIDs.remove(conversationID)
    } else {
      mutedIDs.insert(conversationID)
    }
    persistFlags()
    updateDockBadge()
  }

  func clearChatHistory(conversationID: String) async {
    await signal.clearLocalHistory(conversationID: conversationID)
    if selectedConversationID == conversationID {
      messages = []
    }
    if let idx = conversations.firstIndex(where: { $0.id == conversationID }) {
      var updated = conversations[idx]
      updated.preview = updated.isGroup ? "Groupe Signal" : "Écrire sur Signal…"
      conversations[idx] = updated
    }
  }

  func leaveGroup(conversationID: String) async {
    guard let conversation = conversations.first(where: { $0.id == conversationID }),
          conversation.network == .signal,
          conversation.isGroup
    else { return }

    do {
      try await signal.quitGroup(conversation: conversation, deleteLocal: true)
      conversations.removeAll { $0.id == conversationID }
      pinnedIDs.remove(conversationID)
      mutedIDs.remove(conversationID)
      archivedIDs.remove(conversationID)
      disappearingSecondsByID.removeValue(forKey: conversationID)
      persistFlags()
      if selectedConversationID == conversationID {
        await select(activeQueue.first?.id)
      }
    } catch {
      lastErrorMessage = error.localizedDescription
    }
  }

  func setDisappearingMessages(conversationID: String, seconds: Int) async {
    guard let conversation = conversations.first(where: { $0.id == conversationID }),
          conversation.network == .signal
    else { return }

    do {
      try await signal.setDisappearingMessages(conversation: conversation, expirationSeconds: seconds)
      if seconds <= 0 {
        disappearingSecondsByID.removeValue(forKey: conversationID)
      } else {
        disappearingSecondsByID[conversationID] = seconds
      }
      persistFlags()
    } catch {
      lastErrorMessage = error.localizedDescription
    }
  }

  func isArchived(_ id: String) -> Bool { archivedIDs.contains(id) }

  /// File des fils archivés — la vue « Archivés » de la liste.
  var archivedQueue: [Conversation] {
    searched(
      conversations
        .filter { $0.isArchived && matchesNetworkFilter($0) }
        .sorted { $0.lastMessageAt > $1.lastMessageAt }
    )
  }

  func archiveSelected() async {
    guard let id = selectedConversationID else { return }
    await setArchived(true, conversationID: id)
  }

  /// ⌘E : archive, ou désarchive si le fil l'est déjà.
  func toggleArchived(conversationID: String) async {
    await setArchived(!archivedIDs.contains(conversationID), conversationID: conversationID)
  }

  func unarchive(conversationID: String) async {
    await setArchived(false, conversationID: conversationID)
  }

  private func setArchived(_ archived: Bool, conversationID: String) async {
    guard conversations.contains(where: { $0.id == conversationID }) else { return }
    if archived {
      archivedIDs.insert(conversationID)
    } else {
      archivedIDs.remove(conversationID)
    }
    persistFlags()
    normalizeArchiveState()
    // Archiver le fil ouvert enchaîne sur le suivant : c'est le geste Focus.
    if archived, selectedConversationID == conversationID {
      await select(activeQueue.first?.id)
    } else if !archived {
      // Désarchiver ramène le fil sous les yeux.
      isShowingArchived = false
      await select(conversationID)
    }
  }

  func setShowingArchived(_ showing: Bool) {
    isShowingArchived = showing
  }

  /// ⌘Entrée : envoyer, puis archiver — la boucle « je réponds, je passe au suivant ».
  func sendDraftAndArchive() async {
    guard let id = selectedConversationID else { return }
    let hadDraft = !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !pendingAttachmentPaths.isEmpty
    guard hadDraft else {
      await setArchived(true, conversationID: id)
      return
    }
    await sendDraft()
    // Un envoi qui a échoué restaure le brouillon : on n'archive pas dans ce cas.
    guard draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          pendingAttachmentPaths.isEmpty
    else { return }
    await setArchived(true, conversationID: id)
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
    if conversation.network == .iMessage, !iMessageSender.automationAuthorized() {
      let granted = requestMessagesAutomation()
      if !granted {
        lastErrorMessage = IMessageSendError.automationDenied.localizedDescription
        openAutomationPrivacySettings()
        return
      }
    }

    if conversation.network == .iMessage, !attachments.isEmpty {
      lastErrorMessage = "Envoi d’images iMessage pas encore branché — Signal seulement pour l’instant."
      return
    }
    if conversation.network.isMatrixBridged, !isMatrixConnected {
      lastErrorMessage = "Matrix n’est pas connecté — vérifie Réglages → Matrix."
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
      case .whatsapp:
        try await matrix.send(
          conversationID: conversation.id,
          text: text,
          attachmentPaths: attachments,
          // Le txnId dérive de l'id optimiste : un renvoi ne duplique pas le message.
          localID: optimistic.id
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
        }
        // Ne jamais écraser un bon nom de groupe/contact par un id technique.
        existing.preferTitle(incoming.title)
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

    conversations = Array(byID.values).sorted(by: { sortForInbox($0, $1) })
  }

  /// Fusion des fils bridgés — même logique que Signal, sans jamais toucher aux autres réseaux.
  private func mergeMatrixConversations(_ incomingList: [Conversation]) {
    guard !incomingList.isEmpty else { return }
    var byID = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })

    for incoming in incomingList {
      if var existing = byID[incoming.id] {
        if incoming.hasLivePreview {
          existing.preview = incoming.preview
          existing.lastMessageAt = max(existing.lastMessageAt, incoming.lastMessageAt)
        }
        existing.preferTitle(incoming.title)
        existing.isGroup = incoming.isGroup
        // Le fil ouvert est lu : ne pas y réinstaller un badge.
        existing.unreadCount = incoming.id == selectedConversationID ? 0 : incoming.unreadCount
        byID[incoming.id] = existing
      } else {
        byID[incoming.id] = incoming
      }
    }

    // Un salon quitté côté WhatsApp disparaît de l'inbox.
    let live = Set(incomingList.map(\.id))
    for (id, conversation) in byID where conversation.network.isMatrixBridged && !live.contains(id) {
      byID.removeValue(forKey: id)
    }

    conversations = Array(byID.values).sorted(by: { sortForInbox($0, $1) })
  }

  private func refreshSelectedMatrixMessages() async {
    guard let id = selectedConversationID,
          let conversation = conversations.first(where: { $0.id == id }),
          conversation.network.isMatrixBridged
    else { return }
    let fetched = await matrix.messages(conversationID: id)
    guard !fetched.isEmpty else { return }
    messages = await matrix.ensureLocalAttachments(fetched)
    applySidebarPreview(conversationID: id, from: messages)
    clearUnread(for: id)
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

    // 1) iMessage d’abord (rapide) — ne pas bloquer derrière signal-cli.
    let im = await loadIMessageOffMain()
    if Task.isCancelled { return }

    var merged: [Conversation] = []
    usingDemoData = false
    var shouldEnrichIMessage = false

    switch im {
    case .success(let list):
      // Fusionne avec le cache : garde les titres Contacts déjà résolus.
      let cachedTitles = Dictionary(
        uniqueKeysWithValues: conversations
          .filter { $0.network == .iMessage }
          .map { ($0.id, $0.title) }
      )
      var fresh = list
      for i in fresh.indices {
        if let cached = cachedTitles[fresh[i].id], !cached.isEmpty {
          fresh[i].preferTitle(cached)
        }
      }
      ContactDirectoryDisk.enrichIMessageTitles(&fresh)
      merged.append(contentsOf: fresh)
      IMessageConversationCache.save(fresh)
      shouldEnrichIMessage = !fresh.isEmpty
      iMessageStatusFR = fresh.isEmpty
        ? "Messages accessible — aucune conversation texte récente."
        : "\(fresh.count) conversations iMessage."
    case .denied(let message):
      // Garde le cache si on l’a — mieux que la démo vide.
      let cached = conversations.filter { $0.network == .iMessage }
      if !cached.isEmpty {
        merged.append(contentsOf: cached)
        iMessageStatusFR = "Cache iMessage · \(cached.count) (accès disque refusé)"
      } else {
        iMessageStatusFR = message
        merged.append(contentsOf: Self.demoConversations())
        usingDemoData = true
      }
    case .failure(let message):
      let cached = conversations.filter { $0.network == .iMessage }
      if !cached.isEmpty {
        merged.append(contentsOf: cached)
        iMessageStatusFR = "Cache iMessage · \(cached.count) (\(message))"
      } else {
        iMessageStatusFR = message
        merged.append(contentsOf: Self.demoConversations())
        usingDemoData = true
      }
    }

    // Garder le Signal déjà en mémoire pendant que signal-cli tourne.
    let previousSignal = conversations.filter { $0.network == .signal }
    if !previousSignal.isEmpty {
      merged.append(contentsOf: previousSignal)
    }

    preserveComposing(into: &merged)

    let keepSelection = selectedConversationID
    conversations = merged.sorted(by: { sortForInbox($0, $1) })
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

    if shouldEnrichIMessage {
      Task { await self.enrichIMessageContactsInBackground() }
      Task { await self.refreshIMessageSearchIndex() }
    }

    // 2) Signal ensuite (peut être long — listGroups / receive / contacts).
    let status = await signal.statusMessageFR()
    if Task.isCancelled { return }
    signalStatusFR = status

    let signalResult: Result<[Conversation], Error>
    do {
      signalResult = .success(try await signal.fetchConversations())
    } catch {
      signalResult = .failure(error)
    }
    if Task.isCancelled { return }

    var next = conversations.filter { $0.network != .signal }

    switch signalResult {
    case .success(let list):
      if usingDemoData {
        next.removeAll { $0.network == .signal && $0.transportKey == "demo" }
      }
      var signalList = list
      let previews = await signal.previewMap()
      for i in signalList.indices {
        if let p = previews[signalList[i].id] {
          signalList[i].preview = p.text
          signalList[i].lastMessageAt = max(signalList[i].lastMessageAt, p.date)
        }
      }
      next.append(contentsOf: signalList)
      let groups = signalList.filter(\.isGroup).count
      let dms = signalList.count - groups
      if signalList.isEmpty {
        signalStatusFR += " Aucune conversation — réessaie Actualiser."
      } else {
        let liveGroups = signalList.filter { $0.isGroup && $0.hasLivePreview }.count
        signalStatusFR += " \(dms) DM · \(groups) groupes (\(liveGroups) avec messages)."
      }
    case .failure(let error):
      next.append(contentsOf: previousSignal)
      lastErrorMessage = "Signal : \(error.localizedDescription)"
      if !previousSignal.isEmpty {
        signalStatusFR += " (cache local · \(previousSignal.filter(\.isGroup).count) groupes)"
      }
    }

    preserveComposing(into: &next)

    let selection = selectedConversationID
    conversations = next.sorted(by: { sortForInbox($0, $1) })
    if selection == nil || !conversations.contains(where: { $0.id == selection }) {
      selectedConversationID = inboxRecents.first?.id
        ?? inboxGroups.first?.id
        ?? activeQueue.first?.id
    }
    await loadMessagesForSelection()
  }

  /// Noms (+ index photos) Contacts — ne bloque jamais le chargement inbox.
  private func enrichIMessageContactsInBackground() async {
    var list = conversations.filter { $0.network == .iMessage }
    guard !list.isEmpty else { return }
    await ContactDirectory.shared.enrichIMessageTitles(&list)

    var byID = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })
    var changed = 0
    for updated in list {
      guard var existing = byID[updated.id] else { continue }
      let before = existing.title
      existing.preferTitle(updated.title)
      if existing.title != before {
        byID[updated.id] = existing
        changed += 1
        await ConversationAvatarStore.shared.invalidate(conversationID: updated.id)
      }
    }
    if changed > 0 {
      conversations = Array(byID.values).sorted(by: { sortForInbox($0, $1) })
      IMessageConversationCache.save(conversations.filter { $0.network == .iMessage })
    }
    let named = list.filter { !$0.hasPlaceholderTitle }.count
    iMessageStatusFR = "\(list.count) conversations iMessage · \(named) noms Contacts."
  }

  private enum IMessageLoad: Sendable {
    case success([Conversation])
    case denied(String)
    case failure(String)
  }

  private func loadIMessageOffMain() async -> IMessageLoad {
    let db = iMessageDB
    let work = Task.detached(priority: .userInitiated) { () -> IMessageLoad in
      do {
        let list = try db.fetchConversations()
        return .success(list)
      } catch let error as IMessageAccessError {
        if case .authorizationDenied = error {
          return .denied(error.localizedDescription)
        }
        return .failure(error.localizedDescription)
      } catch is CancellationError {
        return .failure("Lecture Messages trop longue — vérifie l’accès disque.")
      } catch {
        return .failure(error.localizedDescription)
      }
    }
    let timeout = Task {
      try? await Task.sleep(for: .seconds(45))
      work.cancel()
    }
    let result = await work.result
    timeout.cancel()
    switch result {
    case .success(let value):
      return value
    case .failure:
      return .failure("Lecture Messages trop longue — vérifie l’accès disque.")
    }
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
        cached = await signal.ensureLocalAttachments(cached, conversationID: conversation.id)
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

    case .whatsapp:
      var cached = await matrix.messages(conversationID: conversation.id)
      if cached.isEmpty {
        // Fil jamais ouvert : on va chercher l'historique que le bridge a backfillé.
        cached = await matrix.backfill(conversationID: conversation.id)
      }
      if cached.isEmpty {
        messages = [
          ChatMessage(
            id: "matrix-empty-\(conversation.id)",
            conversationID: conversation.id,
            network: .whatsapp,
            text: isMatrixConnected
              ? "Pas encore de messages ici. Écris ci-dessous."
              : "Matrix n’est pas connecté — ouvre Réglages → Matrix.",
            sentAt: Date(),
            isFromMe: false
          )
        ]
        return
      }
      messages = await matrix.ensureLocalAttachments(cached)
      applySidebarPreview(conversationID: conversation.id, from: messages)
    }
  }

  private func applySidebarPreview(conversationID: String, from messages: [ChatMessage]) {
    guard let last = messages.last,
          let idx = conversations.firstIndex(where: { $0.id == conversationID })
    else { return }
    if last.id.hasPrefix("signal-empty-") || last.id.hasPrefix("signal-sync-") { return }
    if last.id.hasPrefix("matrix-empty-") { return }
    indexMessages(messages, conversationID: conversationID)
    var updated = conversations[idx]
    updated.preview = last.sidebarPreviewText
    updated.lastMessageAt = last.sentAt
    updated.lastDelivery = Self.delivery(after: last, previous: updated.lastDelivery)
    updated.lastMessageIsFromMe = last.isFromMe
    conversations[idx] = updated
  }

  /// Le dernier message reçu efface la coche ; un envoi optimiste la met à « Envoi… ».
  /// Un état plus riche déjà connu du réseau (livré / vu) n'est jamais rétrogradé.
  private static func delivery(
    after last: ChatMessage,
    previous: MessageDelivery?
  ) -> MessageDelivery? {
    guard last.isFromMe else { return nil }
    if last.isPending { return .sending }
    if previous == .delivered || previous == .read { return previous }
    return .sent
  }

  /// Une conv. ouverte au composeur ne doit pas disparaître au refresh.
  private func preserveComposing(into merged: inout [Conversation]) {
    let drafts = conversations.filter { $0.id.contains(":compose:") }
    for draft in drafts {
      if merged.contains(where: { Self.matchesHandle($0, network: draft.network, handle: draft.address) }) {
        continue
      }
      merged.append(draft)
    }
  }

  private static func matchesHandle(_ conversation: Conversation, network: MessageNetwork, handle: String) -> Bool {
    guard conversation.network == network else { return false }
    let needle = normalizeHandle(handle)
    if normalizeHandle(conversation.address) == needle { return true }
    return conversation.transportKey
      .split(separator: ",")
      .map { normalizeHandle(String($0)) }
      .contains(needle)
  }

  private static func normalizeHandle(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if trimmed.contains("@") { return trimmed }
    return trimmed.filter(\.isNumber)
  }

  private func persistFlags() {
    UserDefaults.standard.set(Array(pinnedIDs), forKey: Keys.pinnedIDs)
    UserDefaults.standard.set(Array(mutedIDs), forKey: Keys.mutedIDs)
    UserDefaults.standard.set(Array(archivedIDs), forKey: Keys.archivedIDs)
    if let data = try? JSONEncoder().encode(disappearingSecondsByID) {
      UserDefaults.standard.set(data, forKey: Keys.disappearing)
    }
  }

  private enum Keys {
    static let mode = "correspondance.inboxMode"
    static let networkFilter = "correspondance.networkFilter"
    static let pinnedIDs = "correspondance.pinnedConversationIDs"
    static let mutedIDs = "correspondance.mutedConversationIDs"
    static let archivedIDs = "correspondance.archivedConversationIDs"
    static let disappearing = "correspondance.disappearingSeconds"
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
