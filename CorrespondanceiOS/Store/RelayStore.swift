import CorrespondanceCore
import Foundation
import Observation
import OSLog
import SwiftUI

/// L'inbox de l'iPhone, au-dessus de Core.
///
/// Ce n'est PAS `InboxStore` : le Mac porte iMessage, des fenêtres détachées,
/// l'automatisation Accessibilité, le carnet d'adresses — 2 700 lignes dont
/// aucune n'a de sens ici. L'iPhone est un client Matrix pur (décision 2 de la
/// révision iOS) : il tient une boucle `/sync`, une liste de conversations, un
/// fil par conversation ouverte, et l'état de conversation du Relais.
///
/// La discipline d'écriture est celle de la phase B, à la lettre : geste
/// immédiat côté appareil, écriture déposée dans `relayQueue`, envoi au premier
/// moment raisonnable, et tant qu'elle n'est pas partie elle prime sur ce que
/// le `/sync` raconte (`RelayStore+Relay.swift`).
@MainActor
@Observable
final class RelayStore {
  static let log = Logger(subsystem: "com.correspondance.ios", category: "relais")

  /// Où en est la session avec le Relais. L'écran de connexion ne s'affiche
  /// que sur `.disconnected` — jamais sur `.unknown`, sinon il clignoterait au
  /// lancement le temps de lire le Trousseau.
  enum Session: Equatable {
    case unknown
    case disconnected
    case connecting
    case connected
  }

  // MARK: - Session

  private(set) var session: Session = .unknown
  /// Dernière erreur montrable, en français. `nil` = rien à dire.
  var connectionError: String?
  /// Le `/sync` a échoué mais la session tient : bandeau discret, pas d'écran d'erreur.
  private(set) var syncError: String?
  private(set) var isSyncing = false

  let matrix: MatrixBridgeService

  // MARK: - Contenu

  private(set) var conversations: [Conversation] = []
  private(set) var messages: [String: [ChatMessage]] = [:]
  /// L'état de conversation, déjà traduit en identifiants de fil. Écrit par le
  /// geste (tout de suite) et par l'adoption de l'instantané du Relais.
  var state = InboxState()
  var hiddenMessageIDs: Set<String> = HiddenMessageStore.load()
  var mergedContacts: [MergedContact] = []
  /// Les messages qui attendent leur heure (`RelayStore+Scheduled`).
  var scheduled: [ScheduledMessage] = ScheduledMessageStore.load()

  // MARK: - Ce que l'écran choisit

  var scope: InboxScope = .inbox
  var networkFilter: MessageNetwork?
  var filter: ConversationFilter = .all
  /// Le fil ouvert dans l'inbox. Survit au changement de size class : c'est le
  /// store qui le tient, pas la vue.
  var selectedConversationID: String?
  /// Le fil montré en Focus. Séparé du précédent : passer en Focus puis revenir
  /// ne doit pas déplacer la sélection de l'inbox.
  var focusConversationID: String?

  // MARK: - Composer

  /// Brouillons en cours de frappe. Priment sur `state.drafts` : ce qu'on tape
  /// maintenant est plus vrai que ce que le Relais a renvoyé il y a dix secondes.
  private(set) var localDrafts: [String: String] = [:]
  private(set) var pendingAttachments: [String: [String]] = [:]
  private(set) var replyTargets: [String: String] = [:]
  private(set) var sendingConversationIDs: Set<String> = []

  // MARK: - Écriture vers le Relais (phase B)

  var relayQueue = RelayWriteQueue.load(from: .standard, key: RelayStore.relayQueueKey)
  var relayDraftTasks: [String: Task<Void, Never>] = [:]
  var isFlushingRelay = false
  static let relayQueueKey = "correspondance.ios.relayWriteQueue"

  private var syncTask: Task<Void, Never>?
  /// Les fils dont on a déjà demandé l'historique cette session.
  private var openedConversationIDs: Set<String> = []
  /// Vrai en mode démonstration : aucun réseau, des conversations en dur.
  let isDemo: Bool

  // MARK: - Cycle de vie

  init(demo: Bool = false) {
    isDemo = demo
    matrix = MatrixBridgeService()
    if demo {
      session = .connected
      let catalogue = DemoRelay.catalogue()
      conversations = catalogue.conversations
      messages = catalogue.messages
      state = catalogue.state
    }
  }

  /// Reprend la session du Trousseau, s'il y en a une, et lance la boucle.
  func start() async {
    guard !isDemo, session == .unknown else { return }
    guard MatrixCredentialStore.load() != nil else {
      session = .disconnected
      return
    }
    let alive = await matrix.restoreCursorAndCheckSession()
    guard alive else {
      session = .disconnected
      connectionError = "La session enregistrée n'est plus valable — reconnecte-toi."
      return
    }
    session = .connected
    conversations = mergedRows(await matrix.conversations())
    await reloadRelayState()
    refreshPendingRequests()
    startSyncLoop()
    // Ce que le Relais dit avoir rejoint, comparé à la base : un portail créé
    // pendant que l'iPhone dormait n'apparaît dans aucun `/sync` incrémental.
    // En arrière-plan — l'écran ne l'attend pas.
    Task { @MainActor [weak self] in
      guard let self else { return }
      let adopted = await self.matrix.reconcileJoinedRooms()
      guard !adopted.isEmpty else { return }
      self.conversations = self.mergedRows(await self.matrix.conversations())
    }
  }

  /// « Recharger depuis le Relais » : la base locale se vide et le prochain
  /// `/sync` — initial — la repeuple. La porte de secours du jour où l'inbox ne
  /// ressemblerait plus à ce que raconte le Relais.
  func reloadFromRelay() async {
    guard !isDemo, session == .connected else { return }
    syncTask?.cancel()
    syncTask = nil
    await matrix.reloadFromRelay()
    conversations = []
    messages = [:]
    openedConversationIDs = []
    startSyncLoop()
  }

  func connect(homeserver raw: String, user: String, password: String) async {
    connectionError = nil
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = Self.homeserverURL(from: trimmed) else {
      connectionError = "Adresse du Relais illisible. Exemple : http://relais.local:8008"
      return
    }
    session = .connecting
    do {
      _ = try await matrix.connect(
        homeserver: url,
        user: user.trimmingCharacters(in: .whitespacesAndNewlines),
        password: password
      )
      UserDefaults.standard.set(trimmed, forKey: Self.lastHomeserverKey)
      session = .connected
      await reloadRelayState()
      startSyncLoop()
    } catch {
      session = .disconnected
      connectionError = Self.readable(error)
    }
  }

  /// La déconnexion. L'ordre compte : le pusher part AVANT le jeton d'accès —
  /// après, le Relais ne nous écouterait plus, et continuerait de réveiller un
  /// téléphone qui n'a plus de session.
  func signOut(push: PushRegistration? = nil) async {
    await push?.removeFromRelay()
    syncTask?.cancel()
    syncTask = nil
    for task in relayDraftTasks.values { task.cancel() }
    relayDraftTasks = [:]
    await matrix.disconnect()
    conversations = []
    messages = [:]
    state = InboxState()
    localDrafts = [:]
    selectedConversationID = nil
    focusConversationID = nil
    openedConversationIDs = []
    SharedRelayState.saveMutedRoomIDs([])
    session = .disconnected
  }

  /// L'adresse mémorisée du Relais — jamais une IP en dur, seulement ce que
  /// l'utilisateur a saisi la dernière fois.
  static let lastHomeserverKey = "correspondance.ios.lastHomeserver"
  var rememberedHomeserver: String {
    UserDefaults.standard.string(forKey: Self.lastHomeserverKey) ?? ""
  }

  /// « relais.local:8008 » vaut « http://relais.local:8008 » : sur un tailnet,
  /// personne ne tape le schéma.
  static func homeserverURL(from raw: String) -> URL? {
    guard !raw.isEmpty else { return nil }
    let candidate = raw.contains("://") ? raw : "http://\(raw)"
    guard let url = URL(string: candidate), url.host != nil else { return nil }
    return url
  }

  static func readable(_ error: Error) -> String {
    // `MatrixError.transport` recopie le message d'URLSession, qui est en
    // anglais : le seul endroit de la pile où une erreur remonte non traduite.
    if case .transport = error as? MatrixError {
      return "Le Relais ne répond pas à cette adresse. Vérifie-la, et que Tailscale est connecté."
    }
    if let matrix = error as? MatrixError { return matrix.errorDescription ?? "\(matrix)" }
    let urlError = error as? URLError
    switch urlError?.code {
    case .some(.cannotFindHost), .some(.cannotConnectToHost):
      return "Le Relais ne répond pas à cette adresse. Tailscale est-il connecté ?"
    case .some(.notConnectedToInternet):
      return "Pas de réseau."
    case .some(.timedOut):
      return "Le Relais met trop de temps à répondre."
    default:
      return error.localizedDescription
    }
  }

  // MARK: - Boucle /sync

  private func startSyncLoop() {
    guard !isDemo, syncTask == nil else { return }
    syncTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard let self, self.session == .connected else { return }
        await self.syncOnce()
        if Task.isCancelled { return }
        // Le long-poll rend la main dès qu'il se passe quelque chose ; le
        // souffle évite de marteler le Relais quand il rend une erreur.
        if self.syncError != nil { try? await Task.sleep(for: .seconds(5)) }
      }
    }
  }

  private func syncOnce() async {
    isSyncing = true
    defer { isSyncing = false }
    do {
      let fresh = try await matrix.syncOnce()
      syncError = nil
      conversations = mergedRows(fresh)
      networkFlaggedRequestIDs = await matrix.networkFlaggedRequestIDs()
      await adoptRelayState()
      refreshPendingRequests()
      await flushRelayWrites()
      await refreshOpenThreads()
      await refreshTypingLabels()
    } catch MatrixError.http(let status, let code, _) where status == 401 || code == "M_UNKNOWN_TOKEN" {
      session = .disconnected
      connectionError = "Session expirée sur le Relais — reconnecte-toi."
      syncTask?.cancel()
      syncTask = nil
    } catch {
      syncError = Self.readable(error)
    }
  }

  /// Rafraîchit les fils ouverts après un `/sync` : c'est ce qui fait arriver
  /// un message pendant qu'on lit la conversation.
  private func refreshOpenThreads() async {
    for id in Set([selectedConversationID, focusConversationID].compactMap { $0 }) {
      await loadMessages(conversationID: id, backfill: false)
    }
  }

  /// Les lignes de fusion sont LUES : une personne reconnue sur deux réseaux
  /// n'a qu'une ligne. On ne fusionne pas depuis l'iPhone en v1 (décision 10) —
  /// la fusion se décide sur le Mac, et arrive ici par l'account data du Relais.
  private func mergedRows(_ list: [Conversation]) -> [Conversation] {
    guard !mergedContacts.isEmpty else { return list }
    return MergedContact.apply(to: list, merged: mergedContacts)
  }

  /// Les fils réunis sous une ligne de fusion — l'iPhone en a besoin pour leur
  /// état (une ligne fusionnée n'a pas de salon à elle).
  func memberConversations(of mergedID: String) -> [Conversation] {
    guard let contact = mergedContacts.first(where: { $0.id == mergedID }) else { return [] }
    return contact.memberIDs.compactMap { id in conversations.first { $0.id == id } }
  }

  /// Les identifiants qui portent réellement un salon pour ce fil : lui-même,
  /// ou ses membres s'il s'agit d'une ligne de fusion.
  func relayTargets(of conversationID: String) -> [String] {
    guard MergedContact.isMergedID(conversationID) else { return [conversationID] }
    let members = mergedContacts.first { $0.id == conversationID }?.memberIDs ?? []
    return members.isEmpty ? [] : members
  }

  // MARK: - Listes

  var visibleConversations: [Conversation] {
    InboxOrdering.list(
      conversations,
      scope: scope,
      network: networkFilter,
      filter: filter,
      state: viewState
    )
  }

  var focusQueue: [Conversation] {
    InboxOrdering.focusQueue(conversations, state: viewState)
  }

  /// L'état tel que l'écran doit le montrer : celui du Relais, corrigé par les
  /// brouillons qu'on est en train de taper.
  var viewState: InboxState {
    var merged = state
    for (id, text) in localDrafts { merged.drafts[id] = text }
    return merged
  }

  // MARK: - Demandes

  /// Ce fil attend-il d'être accepté ? Une demande reste hors de la file
  /// jusque-là — c'est le seul état qui la retienne.
  func isRequest(_ id: String) -> Bool { state.isRequest(id) }

  /// Les signaux que l'iPhone sait donner sur un fil. Écart assumé de la v1 :
  /// pas de carnet d'adresses ici (décision 2 — client Matrix pur), donc
  /// `isKnownCorrespondent` reste faux et seule la fusion, décidée sur le Mac,
  /// vaut reconnaissance.
  func requestSignals(_ conversation: Conversation) -> RequestSignals {
    // `nil` tant que le fil n'est pas chargé : on ne range personne sur un
    // soupçon. Un brouillon ou un dernier mot de moi suffisent, eux, à trancher.
    var ecrit: Bool?
    if conversation.lastMessageIsFromMe
      || !draftText(conversation.id).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      ecrit = true
    } else if let fil = messages[conversation.id], !fil.isEmpty {
      ecrit = fil.contains(where: \.isFromMe)
    }
    let connu = mergedContacts.contains { $0.memberIDs.contains(conversation.id) }
    return RequestSignals(
      hasWrittenBack: ecrit,
      isKnownCorrespondent: connu,
      isFlaggedByNetwork: networkFlaggedRequestIDs.contains(conversation.id)
    )
  }

  /// Les fils que le pont annonce lui-même comme des demandes. Relu à chaque
  /// `/sync` : c'est de l'état de salon, pas de l'état de conversation.
  private(set) var networkFlaggedRequestIDs: Set<String> = []

  /// Accepter, c'est faire entrer la conversation dans la file. Refuser, c'est
  /// la ranger : elle n'y entrera pas, et ne redemandera plus.
  func decideRequest(_ decision: ConversationRequest.Decision?, conversationID: String) {
    for id in Set(relayTargets(of: conversationID) + [conversationID]) {
      if let decision { state.requestDecisions[id] = decision }
      else { state.requestDecisions.removeValue(forKey: id) }
    }
    refreshPendingRequests()
    relayNoteRequest(decision, conversationIDs: relayTargets(of: conversationID))
    if decision == .declined { setArchived(true, conversationID: conversationID) }
  }

  /// Recalcule qui attend encore d'être accepté. À rejouer dès que la liste ou
  /// les décisions bougent : le tri, lui, ne fait que lire `pendingRequests`.
  func refreshPendingRequests() {
    let pending = Set(
      conversations
        .filter {
          RequestPolicy.isRequest($0, signals: requestSignals($0), decision: state.requestDecisions[$0.id])
        }
        .map(\.id)
    )
    if pending != state.pendingRequests { state.pendingRequests = pending }
  }

  /// Le rappel posé sur ce fil, s'il en porte un.
  func reminder(_ id: String) -> ConversationReminder? { state.reminder(id) }

  /// Met une conversation de côté jusqu'à une heure — ou la ramène tout de
  /// suite (`nil`). Le geste est immédiat ici, le Relais suit.
  func setReminder(_ wakeAt: Date?, conversationID: String) {
    let targets = relayTargets(of: conversationID)
    let reminder = wakeAt.map { ConversationReminder(wakeAt: $0) }
    for id in Set(targets + [conversationID]) {
      if let reminder { state.reminders[id] = reminder } else { state.reminders.removeValue(forKey: id) }
    }
    relayNoteReminder(reminder, conversationIDs: targets)
    // Le fil ouvert qui part de côté ne reste pas à l'écran.
    if wakeAt != nil {
      if selectedConversationID == conversationID { selectedConversationID = nil }
      if focusConversationID == conversationID { focusConversationID = focusQueue.first?.id }
    }
  }

  func isPinned(_ id: String) -> Bool { state.isPinned(id) }
  func isMuted(_ id: String) -> Bool { state.isMuted(id) }
  func isArchived(_ id: String) -> Bool { state.isArchived(id) }

  func conversation(_ id: String?) -> Conversation? {
    guard let id else { return nil }
    return conversations.first { $0.id == id }
  }

  var networksInUse: [MessageNetwork] {
    MessageNetwork.matrixBridged.filter { network in
      conversations.contains { $0.network == network }
    }
  }

  func unreadCount(for network: MessageNetwork?) -> Int {
    conversations.reduce(0) { total, conversation in
      guard !state.isArchived(conversation.id) else { return total }
      guard network == nil || conversation.network == network else { return total }
      return total + conversation.unreadCount
    }
  }

  // MARK: - Un fil

  /// Les messages visibles d'un fil : ce que le Relais a livré, moins ce qu'on
  /// a masqué. Une ligne de fusion réunit les fils de ses membres, à l'heure.
  /// Les résultats d'un onglet, tous fils du Relais confondus. Ils viennent de
  /// la base locale : on trouve la photo d'une conversation qu'on n'a pas
  /// ouverte depuis six mois, ce qui n'était pas le cas quand la recherche ne
  /// voyait que ce qui était chargé.
  func facetHits(facet: MessageFacet, query: String) -> [FacetedSearch.Hit] {
    guard !isDemo else {
      return FacetedSearch.hits(in: conversations, facet: facet, query: query) {
        visibleMessages($0.id)
      }
    }
    let hits = LocalStore.shared?.facetHits(in: conversations, facet: facet, query: query) ?? []
    return hits.filter { !hiddenMessageIDs.contains($0.message.id) }
  }

  /// L'index de recherche pour cette question : ce que la base trouve dans le
  /// corps des messages, pour que « resto » ramène le fil qui en parle.
  func searchIndex(query: String) -> [String: String] {
    guard !isDemo else {
      return Dictionary(
        uniqueKeysWithValues: conversations.map {
          ($0.id, ConversationSearch.blob(for: visibleMessages($0.id)))
        }
      )
    }
    return LocalStore.shared?.searchIndex(query: query) ?? [:]
  }

  func visibleMessages(_ conversationID: String) -> [ChatMessage] {
    let raw: [ChatMessage]
    if MergedContact.isMergedID(conversationID) {
      raw = relayTargets(of: conversationID)
        .flatMap { messages[$0] ?? [] }
        .sorted { $0.sentAt < $1.sentAt }
    } else {
      raw = messages[conversationID] ?? []
    }
    return HiddenMessageStore.visible(raw, hiddenIDs: hiddenMessageIDs)
  }

  func groups(_ conversationID: String) -> [MessageGroup] {
    let conversation = conversation(conversationID)
    return MessageGrouping.groups(
      for: visibleMessages(conversationID),
      showsSenderNames: conversation?.isGroup ?? false,
      showsNetworkOrigin: MergedContact.isMergedID(conversationID)
    )
  }

  /// Ouvre un fil : historique, pièces jointes, accusé de lecture — comme le Mac.
  func open(conversationID: String) async {
    guard !isDemo else { return }
    let first = !openedConversationIDs.contains(conversationID)
    openedConversationIDs.insert(conversationID)
    await loadMessages(conversationID: conversationID, backfill: first)
    for target in relayTargets(of: conversationID) {
      await matrix.markRead(conversationID: target)
    }
    markLocallyRead(conversationID)
  }

  private func loadMessages(conversationID: String, backfill: Bool) async {
    for target in relayTargets(of: conversationID) {
      var fresh = backfill
        ? await matrix.backfill(conversationID: target)
        : await matrix.messages(conversationID: target)
      fresh = await matrix.ensureLocalAttachments(fresh)
      messages[target] = fresh
    }
  }

  /// Le compteur de non-lus s'éteint à l'écran tout de suite ; le Relais suivra
  /// avec son accusé de lecture, au rythme du réseau.
  private func markLocallyRead(_ conversationID: String) {
    for target in relayTargets(of: conversationID) {
      guard let index = conversations.firstIndex(where: { $0.id == target }),
            conversations[index].unreadCount > 0
      else { continue }
      conversations[index].unreadCount = 0
    }
    if let index = conversations.firstIndex(where: { $0.id == conversationID }),
       conversations[index].unreadCount > 0
    {
      conversations[index].unreadCount = 0
    }
  }

  // MARK: - Composer

  func draftText(_ conversationID: String) -> String {
    localDrafts[conversationID] ?? state.drafts[conversationID] ?? ""
  }

  func setDraft(_ text: String, conversationID: String) {
    guard draftText(conversationID) != text else { return }
    localDrafts[conversationID] = text
    // Écrire, c'est le dire ; effacer tout, c'est dire qu'on a fini.
    noteTyping(conversationID, isTyping: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    scheduleRelayDraftPush(conversationID: conversationID, text: text)
  }

  func attachments(_ conversationID: String) -> [String] {
    pendingAttachments[conversationID] ?? []
  }

  func addAttachment(_ path: String, conversationID: String) {
    var list = attachments(conversationID)
    guard !list.contains(path) else { return }
    list.append(path)
    pendingAttachments[conversationID] = list
  }

  func removeAttachment(_ path: String, conversationID: String) {
    pendingAttachments[conversationID] = attachments(conversationID).filter { $0 != path }
  }

  func replyTarget(_ conversationID: String) -> ChatMessage? {
    guard let id = replyTargets[conversationID] else { return nil }
    return visibleMessages(conversationID).first { $0.id == id }
  }

  func setReplyTarget(_ messageID: String?, conversationID: String) {
    if let messageID { replyTargets[conversationID] = messageID }
    else { replyTargets.removeValue(forKey: conversationID) }
  }

  func isSending(_ conversationID: String) -> Bool {
    sendingConversationIDs.contains(conversationID)
  }

  func canSend(_ conversationID: String) -> Bool {
    !draftText(conversationID).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !attachments(conversationID).isEmpty
  }

  /// Le réseau où part le prochain message — celui du fil, celui du dernier
  /// message pour une ligne de fusion.
  func sendingNetwork(_ conversationID: String) -> MessageNetwork? {
    if MergedContact.isMergedID(conversationID) {
      return memberConversations(of: conversationID)
        .max { $0.lastMessageAt < $1.lastMessageAt }?.network
    }
    return conversation(conversationID)?.network
  }

  func send(conversationID: String) async {
    guard canSend(conversationID), !isSending(conversationID) else { return }
    let text = draftText(conversationID).trimmingCharacters(in: .whitespacesAndNewlines)
    let paths = attachments(conversationID)
    let replyID = replyTargets[conversationID]
    guard let target = sendingTarget(conversationID) else { return }

    sendingConversationIDs.insert(conversationID)
    defer { sendingConversationIDs.remove(conversationID) }

    // Le champ se vide tout de suite : on n'écrit pas contre le réseau.
    localDrafts[conversationID] = ""
    noteTyping(conversationID, isTyping: false)
    pendingAttachments[conversationID] = []
    replyTargets.removeValue(forKey: conversationID)
    scheduleRelayDraftPush(conversationID: conversationID, text: "")

    let localID = UUID().uuidString
    showOptimistically(text: text, paths: paths, in: target, localID: localID)

    guard !isDemo else { return }
    do {
      try await matrix.send(
        conversationID: target,
        text: text,
        attachmentPaths: paths,
        localID: localID,
        replyToMessageID: replyID
      )
      await loadMessages(conversationID: conversationID, backfill: false)
    } catch {
      syncError = Self.readable(error)
      // L'envoi a échoué : le texte revient dans le champ plutôt que de
      // disparaître avec la bulle optimiste.
      messages[target]?.removeAll { $0.id == localID }
      localDrafts[conversationID] = text
      pendingAttachments[conversationID] = paths
    }
  }

  // MARK: - Message vocal

  /// Le micro du composer. Un seul enregistreur pour l'app : on ne parle pas
  /// dans deux fils à la fois.
  let recorder = VoiceRecorder()

  /// Envoie ce qu'on vient d'enregistrer. La bulle apparaît tout de suite, le
  /// fichier part ensuite — la même discipline que le texte.
  func sendVoiceMessage(_ url: URL, voice: VoiceNote, conversationID: String) async {
    guard let target = sendingTarget(conversationID),
          let conversation = conversation(target)
    else { return }
    sendingConversationIDs.insert(conversationID)
    defer { sendingConversationIDs.remove(conversationID) }

    let localID = UUID().uuidString
    var piece = MessageAttachment(
      id: url.path,
      contentType: "audio/mp4",
      filename: url.lastPathComponent,
      localPath: url.path
    )
    piece.voice = voice
    messages[target, default: []].append(
      ChatMessage(
        id: localID,
        conversationID: target,
        network: conversation.network,
        text: "",
        sentAt: .now,
        isFromMe: true,
        isPending: true,
        attachments: [piece]
      )
    )

    guard !isDemo else { return }
    do {
      try await matrix.sendVoiceMessage(
        conversationID: target,
        fileURL: url,
        voice: voice,
        localID: localID
      )
      await loadMessages(conversationID: conversationID, backfill: false)
    } catch {
      syncError = Self.readable(error)
      messages[target]?.removeAll { $0.id == localID }
    }
  }

  /// Le fil qui portera l'envoi : lui-même, ou le membre actif d'une fusion.
  private func sendingTarget(_ conversationID: String) -> String? {
    guard MergedContact.isMergedID(conversationID) else { return conversationID }
    let contact = mergedContacts.first { $0.id == conversationID }
    if let last = contact?.lastUsedConversationID { return last }
    return contact?.defaultConversationID
  }

  private func showOptimistically(text: String, paths: [String], in target: String, localID: String) {
    guard let conversation = conversation(target) ?? conversations.first(where: { $0.id == target })
    else { return }
    let optimistic = ChatMessage(
      id: localID,
      conversationID: target,
      network: conversation.network,
      text: text,
      sentAt: .now,
      isFromMe: true,
      isPending: true,
      attachments: paths.map {
        MessageAttachment(id: $0, contentType: "", filename: URL(fileURLWithPath: $0).lastPathComponent, localPath: $0)
      }
    )
    messages[target, default: []].append(optimistic)
  }

  // MARK: - Gestes sur une bulle

  func react(conversationID: String, messageID: String, emoji: String) async {
    guard !isDemo, let target = messages.first(where: { $0.value.contains { $0.id == messageID } })?.key
    else { return }
    try? await matrix.toggleReaction(conversationID: target, messageID: messageID, emoji: emoji)
    await loadMessages(conversationID: conversationID, backfill: false)
  }

  /// Voter sur un sondage. Le geste bascule : retoucher sa réponse la retire.
  func votePoll(conversationID: String, messageID: String, answerID: String) async {
    guard !isDemo,
          let target = messages.first(where: { $0.value.contains { $0.id == messageID } })?.key
    else { return }
    do {
      try await matrix.votePoll(conversationID: target, pollMessageID: messageID, answerID: answerID)
    } catch {
      syncError = Self.readable(error)
    }
    await loadMessages(conversationID: conversationID, backfill: false)
  }

  /// Modifier un de mes messages, là où le réseau sait le faire.
  func editMessage(messageID: String, newText: String, conversationID: String) async {
    guard !isDemo,
          let target = messages.first(where: { $0.value.contains { $0.id == messageID } })?.key
    else { return }
    do {
      try await matrix.editMessage(conversationID: target, messageID: messageID, newText: newText)
      await loadMessages(conversationID: conversationID, backfill: false)
    } catch {
      syncError = Self.readable(error)
    }
  }

  /// Le geste « Modifier » est-il offert sur ce message ? Seulement les miens,
  /// et seulement là où le réseau sait le faire.
  func canEdit(_ message: ChatMessage) -> Bool {
    message.isFromMe && !message.isPending && !message.isRetracted && !message.isSystemEvent
      && !message.text.isEmpty && message.network.supportsEditing && !isDemo
  }

  func hide(messageID: String, conversationID: String) {
    hiddenMessageIDs.insert(messageID)
    HiddenMessageStore.save(hiddenMessageIDs)
    relayNoteHidden(messageID: messageID, conversationID: conversationID)
  }

  func deleteEverywhere(messageID: String, conversationID: String) async {
    guard !isDemo,
          let target = messages.first(where: { $0.value.contains { $0.id == messageID } })?.key
    else { return }
    try? await matrix.deleteMessage(conversationID: target, messageID: messageID)
    await loadMessages(conversationID: conversationID, backfill: false)
  }

  /// Les six réactions rapides — les mêmes que sur le Mac.
  static let quickReactions = ["👍", "❤️", "😂", "😮", "😢", "🙏"]

  // MARK: - Gestes sur une ligne

  func toggleArchived(_ conversationID: String) {
    setArchived(!isArchived(conversationID), conversationID: conversationID)
  }

  func setArchived(_ value: Bool, conversationID: String) {
    apply(.archived, value: value, conversationID: conversationID)
  }

  func togglePinned(_ conversationID: String) {
    apply(.pinned, value: !isPinned(conversationID), conversationID: conversationID)
  }

  func toggleMuted(_ conversationID: String) {
    apply(.muted, value: !isMuted(conversationID), conversationID: conversationID)
  }

  private func apply(_ flag: RelayFlag, value: Bool, conversationID: String) {
    // Local d'abord : le geste ne patiente jamais sur le réseau.
    switch flag {
    case .archived: setMembership(&state.archived, conversationID, value)
    case .pinned: setMembership(&state.pinned, conversationID, value)
    case .muted: setMembership(&state.muted, conversationID, value)
    }
    // Une ligne de fusion n'a pas de salon : ce sont ses membres qu'on marque.
    for member in relayTargets(of: conversationID) where member != conversationID {
      switch flag {
      case .archived: setMembership(&state.archived, member, value)
      case .pinned: setMembership(&state.pinned, member, value)
      case .muted: setMembership(&state.muted, member, value)
      }
    }
    relayNote(flag, value: value, conversationIDs: relayTargets(of: conversationID))
  }

  private func setMembership(_ set: inout Set<String>, _ id: String, _ member: Bool) {
    if member { set.insert(id) } else { set.remove(id) }
  }

  // MARK: - Ouvrir un fil vers quelqu'un

  /// Demande au pont d'ouvrir un fil. La commande part au bot du réseau ; le
  /// salon, lui, arrive par le `/sync` qui suit — c'est le pont qui décide
  /// quand, pas nous.
  func startBridgeChat(network: MessageNetwork, identifier: String) async throws {
    guard !isDemo else { return }
    try await matrix.startConversation(network: network, identifier: identifier)
  }

  // MARK: - Indicateurs de frappe

  /// « Alice écrit… » par fil, relu à chaque `/sync`. Vide = personne n'écrit.
  private(set) var typingLabels: [String: String] = [:]
  /// Depuis quand on a dit au Relais qu'on écrit — pour renouveler plutôt que
  /// de le lui redire à chaque touche.
  private var typingSentAt: [String: Date] = [:]

  func typingLabel(_ conversationID: String) -> String? { typingLabels[conversationID] }

  private func refreshTypingLabels() async {
    var labels: [String: String] = [:]
    for id in Set([selectedConversationID, focusConversationID].compactMap { $0 }) {
      for target in relayTargets(of: id) {
        if let label = await matrix.typingLabel(conversationID: target) { labels[id] = label }
      }
    }
    if labels != typingLabels { typingLabels = labels }
  }

  /// Dit au Relais qu'on écrit. Renouvelé au plus une fois par dizaine de
  /// secondes : le serveur tient l'information vingt, inutile de le marteler.
  private func noteTyping(_ conversationID: String, isTyping: Bool) {
    guard !isDemo, session == .connected, let target = sendingTarget(conversationID) else { return }
    if isTyping {
      let last = typingSentAt[target] ?? .distantPast
      guard Date().timeIntervalSince(last) > 10 else { return }
      typingSentAt[target] = Date()
    } else {
      guard typingSentAt.removeValue(forKey: target) != nil else { return }
    }
    Task { await matrix.setTyping(conversationID: target, isTyping: isTyping) }
  }

  // MARK: - Note à soi

  /// Ouvre la note à soi, en la créant au premier usage. Un salon du Relais
  /// dont on est le seul membre : ce qu'on s'y écrit se retrouve sur le Mac.
  func openSelfNote() async {
    guard !isDemo, session == .connected else { return }
    do {
      _ = try await matrix.ensureSelfNote()
      conversations = mergedRows(await matrix.conversations())
      guard let id = await matrix.selfNoteConversationID() else { return }
      selectedConversationID = id
      await open(conversationID: id)
    } catch {
      syncError = Self.readable(error)
    }
  }

  // MARK: - Focus

  /// La conversation que Focus doit montrer : celle qu'on suivait si elle est
  /// encore dans la file, la tête de file sinon.
  func focusConversation() -> Conversation? {
    let queue = focusQueue
    if let id = focusConversationID, let match = queue.first(where: { $0.id == id }) { return match }
    focusConversationID = queue.first?.id
    return queue.first
  }

  func focusNext() {
    guard let id = focusConversationID else { return }
    focusConversationID = InboxOrdering.following(id, in: focusQueue) ?? id
  }

  func focusPrevious() {
    guard let id = focusConversationID else { return }
    focusConversationID = InboxOrdering.previous(before: id, in: focusQueue) ?? id
  }

  /// Archiver en Focus : la file d'AVANT le geste dit qui vient ensuite.
  func focusArchiveAndAdvance() {
    guard let id = focusConversationID else { return }
    let queue = focusQueue
    let next = InboxOrdering.next(after: id, in: queue)
    setArchived(true, conversationID: id)
    focusConversationID = next
  }
}
