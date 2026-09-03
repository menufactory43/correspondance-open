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
  /// Comment « cc » répond dans les conversations où d'autres humains lisent.
  /// Le réglage vit dans l'account data globale, que l'agent relit sur le
  /// Relais ; ceci n'en est que la copie affichée.
  private(set) var agentDefaultMode: AgentSettings.Mode = AgentSettings.fallback.defaultMode
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
  /// Le message qu'un résultat de recherche vise : le fil s'y rend dès qu'il
  /// l'a sous la main, et l'efface en arrivant.
  var pendingJumpMessageID: String?
  /// Une page d'historique est en route : le fil montre son attente en tête.
  private(set) var isLoadingOlder = false
  /// Les fils dont le Relais n'a plus rien à donner : inutile de le relancer
  /// à chaque fois qu'on effleure le haut.
  private var exhaustedThreadIDs: Set<String> = []

  // MARK: - Composer

  /// Brouillons en cours de frappe. Priment sur `state.drafts` : ce qu'on tape
  /// maintenant est plus vrai que ce que le Relais a renvoyé il y a dix secondes.
  private(set) var localDrafts: [String: String] = [:]
  /// Un vidage de la boîte du partage est en cours (RelayStore+Partage) : le
  /// retour au premier plan et la connexion peuvent tomber ensemble.
  var partageVidageEnCours = false
  private(set) var pendingAttachments: [String: [String]] = [:]
  private(set) var replyTargets: [String: String] = [:]
  private(set) var sendingConversationIDs: Set<String> = []
  /// La bulle que le composer CORRIGE, par fil. Le champ porte alors sa
  /// version actuelle, et le bouton d'envoi envoie la correction.
  private(set) var editingTargets: [String: String] = [:]
  /// Le brouillon mis de côté le temps d'une correction : y renoncer le rend.
  private var stashedDrafts: [String: String] = [:]

  // MARK: - Écriture vers le Relais (phase B)

  var relayQueue = RelayWriteQueue.load(from: .standard, key: RelayStore.relayQueueKey)
  var relayDraftTasks: [String: Task<Void, Never>] = [:]
  var isFlushingRelay = false
  static let relayQueueKey = "correspondance.ios.relayWriteQueue"

  // MARK: - Notifications locales (cf. `RelayStore+Notifications`)

  /// L'état des fils au dernier passage : c'est la comparaison qui dit ce qui
  /// vient d'arriver.
  var notificationBaseline: [String: Conversation] = [:]
  var lastNotifiedAt: [String: Date] = [:]
  var notificationBursts: [String: NotificationBurst] = [:]
  var notificationSequence = 0
  /// Faux tant que la ligne de flottaison n'est pas posée : un rattrapage de
  /// trente messages au lancement n'est pas trente arrivées.
  var isNotificationPrimed = false

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
      typingLabels = catalogue.typingLabels
      state = catalogue.state
    }
  }

  /// Reprend la session du Trousseau, s'il y en a une, et lance la boucle.
  ///
  /// La base locale d'abord, le Relais ensuite : dehors, Tailscale met parfois
  /// des secondes à monter le tunnel — l'inbox du disque s'affiche tout de
  /// suite, la vérification de session court en fond. Et « injoignable »
  /// n'éjecte pas vers l'écran de connexion : la session est probablement
  /// bonne, c'est le réseau qui manque — la boucle `/sync` réessaiera.
  func start() async {
    guard !isDemo, session == .unknown else { return }
    guard MatrixCredentialStore.load() != nil else {
      session = .disconnected
      return
    }
    if await matrix.restoreFromDisk() {
      conversations = mergedRows(await matrix.conversations())
      session = .connected
    }
    switch await matrix.checkSession() {
    case .invalid:
      session = .disconnected
      connectionError = "La session enregistrée n'est plus valable — reconnecte-toi."
      return
    case .unreachable:
      session = .connected
      syncError = "Relais injoignable pour l'instant — nouvel essai en cours."
    case .valid:
      session = .connected
      conversations = mergedRows(await matrix.conversations())
      await reloadRelayState()
      refreshPendingRequests()
    }
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
      // Après l'adoption : l'état du Relais dit ce qui est muet, et un fil
      // muet ne doit pas sonner le temps d'un aller-retour.
      postLocalNotificationsForNewMessages()
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
      state: viewState,
      scheduled: Set(scheduled.map(\.conversationID))
    )
  }

  /// La même liste, pour une portée donnée : l'iPhone tient Inbox et Archive
  /// dans deux onglets vivants en même temps, chacun avec la sienne.
  func conversations(in scope: InboxScope) -> [Conversation] {
    InboxOrdering.list(
      conversations,
      scope: scope,
      network: networkFilter,
      filter: filter,
      state: viewState,
      scheduled: Set(scheduled.map(\.conversationID))
    )
  }

  var focusQueue: [Conversation] {
    InboxOrdering.focusQueue(conversations, state: viewState)
  }

  /// Ce que Focus doit savoir d'un envoi : lequel, et dans quel fil. La ligne
  /// s'en sert pour faire sortir la page dont on vient de répondre.
  struct SentMark: Equatable {
    let conversationID: String
    let localID: String
    let serial: Int
  }
  private(set) var lastSent: SentMark?

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
    groups(conversationID, messages: visibleMessages(conversationID))
  }

  /// Le regroupement d'une partie du fil seulement — ce que Focus montre quand
  /// il replie l'historique à ce qui attend une réponse.
  func groups(_ conversationID: String, messages: [ChatMessage]) -> [MessageGroup] {
    let conversation = conversation(conversationID)
    return MessageGrouping.groups(
      for: messages,
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
    // En incognito, ouvrir n'est pas lire : le compteur reste, le Relais ne sait rien.
    guard !isIncognito else { return }
    await markRead(conversationID: conversationID)
  }

  /// Le geste explicite : ce fil est lu, ici et sur le Relais, incognito ou pas.
  func markRead(conversationID: String) async {
    guard !isDemo else { return }
    for target in relayTargets(of: conversationID) {
      await matrix.markRead(conversationID: target)
    }
    markLocallyRead(conversationID)
  }

  // MARK: - Incognito

  static let incognitoKey = "correspondance.ios.incognito"

  /// Le mode incognito de Beeper : on lit, et personne ne le sait. Aucun
  /// accusé de lecture ne part, le compteur de non-lus reste — pour répondre
  /// à son rythme. Répondre, ou « Marquer comme lu », lève le voile.
  var isIncognito: Bool = UserDefaults.standard.bool(forKey: RelayStore.incognitoKey) {
    didSet {
      guard isIncognito != oldValue else { return }
      UserDefaults.standard.set(isIncognito, forKey: RelayStore.incognitoKey)
      // Sortir de l'incognito avec un fil ouvert : ce fil est lu.
      if !isIncognito, let id = selectedConversationID {
        Task { @MainActor in await self.markRead(conversationID: id) }
      }
    }
  }

  /// Remonter d'une page : ce que le défilement demande en approchant du haut.
  /// Le Relais rend le fil entier tel qu'il le connaît — on ne garde donc que
  /// s'il a vraiment grandi, et on cesse de demander quand il ne bouge plus.
  func loadOlder(conversationID: String) async {
    guard !isDemo, !isLoadingOlder, !exhaustedThreadIDs.contains(conversationID) else { return }
    isLoadingOlder = true
    defer { isLoadingOlder = false }
    var grew = false
    for target in relayTargets(of: conversationID) {
      let before = messages[target]?.count ?? 0
      let fresh = await matrix.backfill(conversationID: target)
      guard fresh.count > before else { continue }
      messages[target] = await matrix.ensureLocalAttachments(fresh)
      grew = true
    }
    if !grew { exhaustedThreadIDs.insert(conversationID) }
  }

  /// En dessous, un fil passe pour court : le Relais est alors interrogé une
  /// fois par session pour compléter l'historique.
  private static let shortThreadCount = 20

  private func loadMessages(conversationID: String, backfill: Bool) async {
    for target in relayTargets(of: conversationID) {
      // La page du magasin d'abord : le fil s'affiche sans attendre le réseau.
      // Avant, tout — backfill réseau, pièces jointes une à une — se faisait
      // écran vide ; un groupe plein de photos mettait des secondes à paraître.
      let local = await matrix.messages(conversationID: target)
      showLoaded(local, in: target)
      // Le Relais ne complète que les fils encore courts : un fil déjà garni
      // par le magasin n'a rien à redemander à l'ouverture.
      var fresh = local
      if backfill, local.count < Self.shortThreadCount {
        fresh = await matrix.backfill(conversationID: target)
        showLoaded(fresh, in: target)
      }
      // Les pièces jointes raffinent l'affichage après coup, sans le retenir.
      showLoaded(await matrix.ensureLocalAttachments(fresh), in: target)
    }
  }

  /// Pose la page du magasin dans le fil SANS effacer les bulles en vol.
  /// Un `/sync` peut rendre la main pendant l'envoi — l'agent se met à
  /// « écrire » dès qu'on lui parle — et le rafraîchissement remplaçait alors
  /// la liste : la bulle optimiste, pas encore au magasin, s'évanouissait
  /// jusqu'à la confirmation du Relais.
  private func showLoaded(_ list: [ChatMessage], in target: String) {
    let known = Set(list.map(\.id))
    let flying = inFlightBubbles.values
      .filter { $0.conversationID == target && !known.contains($0.id) }
      .sorted { $0.sentAt < $1.sentAt }
    messages[target] = list + flying
  }

  /// Les bulles optimistes dont l'envoi n'est pas encore confirmé, par
  /// identifiant local. Elles quittent la table quand le Relais a répondu —
  /// dans un sens ou dans l'autre — ou quand on annule l'envoi.
  private var inFlightBubbles: [String: ChatMessage] = [:]

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

  /// La bulle en cours de correction dans ce fil.
  func editingMessage(_ conversationID: String) -> ChatMessage? {
    guard let id = editingTargets[conversationID] else { return nil }
    return visibleMessages(conversationID).first { $0.id == id }
  }

  /// Le composer passe en mode correction : le texte descend dedans, le
  /// brouillon attend son tour.
  func beginEditing(_ message: ChatMessage, conversationID: String) {
    guard canEdit(message) else { return }
    if editingTargets[conversationID] == nil {
      stashedDrafts[conversationID] = draftText(conversationID)
    }
    editingTargets[conversationID] = message.id
    replyTargets.removeValue(forKey: conversationID)
    setDraft(message.text, conversationID: conversationID)
  }

  /// Sort du mode correction — correction partie ou abandonnée : le composer
  /// redevient ce qu'il était.
  func endEditing(_ conversationID: String) {
    guard editingTargets.removeValue(forKey: conversationID) != nil else { return }
    setDraft(stashedDrafts.removeValue(forKey: conversationID) ?? "", conversationID: conversationID)
  }

  /// Envoie la correction en cours.
  private func commitEdit(_ conversationID: String) async {
    guard let message = editingMessage(conversationID) else { return }
    let corrected = draftText(conversationID).trimmingCharacters(in: .whitespacesAndNewlines)
    endEditing(conversationID)
    guard !corrected.isEmpty, corrected != message.text else { return }
    // La fenêtre a pu se fermer pendant qu'on écrivait : le pont refuserait en
    // silence, et la correction ne vivrait que sur cet appareil.
    guard message.network.acceptsEdit(sentAt: message.sentAt) else {
      syncError = "Trop tard pour corriger : passé \(message.network.editWindowLabelFR ?? "le délai"), "
        + "\(message.network.labelFR) n’accepte plus de modification."
      return
    }
    await editMessage(messageID: message.id, newText: corrected, conversationID: conversationID)
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
    // Le composer corrige une bulle : le bouton envoie la correction, pas un
    // message de plus.
    if editingTargets[conversationID] != nil {
      await commitEdit(conversationID)
      return
    }
    guard canSend(conversationID), !isSending(conversationID) else { return }
    let text = draftText(conversationID).trimmingCharacters(in: .whitespacesAndNewlines)
    let paths = attachments(conversationID)
    let replyID = replyTargets[conversationID]
    guard let target = sendingTarget(conversationID) else { return }

    sendingConversationIDs.insert(conversationID)
    defer { sendingConversationIDs.remove(conversationID) }

    // Répondre, c'est avouer qu'on a lu : l'incognito s'efface pour ce fil.
    if isIncognito { await markRead(conversationID: conversationID) }

    // Le champ se vide tout de suite : on n'écrit pas contre le réseau.
    localDrafts[conversationID] = ""
    noteTyping(conversationID, isTyping: false)
    pendingAttachments[conversationID] = []
    replyTargets.removeValue(forKey: conversationID)
    scheduleRelayDraftPush(conversationID: conversationID, text: "")

    let localID = UUID().uuidString
    // Ce fil devient une suggestion de partage : c'est l'envoi qui compte
    // le plus pour la rangée des visages de la feuille.
    if let conversation = conversations.first(where: { $0.id == conversationID }) {
      donnerSuggestionDePartage(conversation)
    }
    showOptimistically(text: text, paths: paths, in: target, localID: localID)
    lastSent = SentMark(conversationID: conversationID, localID: localID, serial: (lastSent?.serial ?? 0) + 1)

    guard !isDemo else { return }

    // Délai de grâce : la bulle est là, le réseau attend. Rien ne quitte
    // l'appareil avant l'échéance — d'ici là, « Annuler » rend tout.
    if undoSendDelay.isOn {
      armUndoSend(
        conversationID: conversationID, target: target, text: text,
        paths: paths, replyID: replyID, localID: localID
      )
      return
    }

    await deliverOrRestore(
      conversationID: conversationID, target: target, text: text,
      paths: paths, replyID: replyID, localID: localID
    )
  }

  /// Le transport et ses suites : la bulle se pose, ou le brouillon revient.
  private func deliverOrRestore(
    conversationID: String, target: String, text: String,
    paths: [String], replyID: String?, localID: String
  ) async {
    do {
      try await matrix.send(
        conversationID: target,
        text: text,
        attachmentPaths: paths,
        localID: localID,
        replyToMessageID: replyID
      )
      inFlightBubbles.removeValue(forKey: localID)
      await loadMessages(conversationID: conversationID, backfill: false)
    } catch {
      syncError = Self.readable(error)
      // L'envoi a échoué : le texte revient dans le champ plutôt que de
      // disparaître avec la bulle optimiste.
      inFlightBubbles.removeValue(forKey: localID)
      messages[target]?.removeAll { $0.id == localID }
      localDrafts[conversationID] = text
      pendingAttachments[conversationID] = paths
    }
  }

  // MARK: - Annuler l'envoi

  /// Un envoi en sursis : de quoi le faire partir à l'échéance, ou le défaire.
  private struct PendingSend {
    let conversationID: String
    let target: String
    let text: String
    let paths: [String]
    let replyID: String?
    var task: Task<Void, Never>?
    /// Le geste Focus a archivé le fil dans la foulée : annuler le rend à la file.
    var archivedConversationID: String?
  }

  private var pendingSends: [String: PendingSend] = [:]

  /// Les bulles encore rattrapables — ce qui met le « Annuler » sous la bulle.
  private(set) var undoableSendIDs: Set<String> = []

  static let undoSendDelayKey = "correspondance.ios.undoSendDelay"

  /// Le délai de grâce choisi dans Réglages.
  var undoSendDelay: UndoSendDelay = UndoSendDelay.fromStored(
    UserDefaults.standard.object(forKey: RelayStore.undoSendDelayKey) as? Int
  ) {
    didSet {
      guard undoSendDelay != oldValue else { return }
      UserDefaults.standard.set(undoSendDelay.rawValue, forKey: RelayStore.undoSendDelayKey)
    }
  }

  func canUndoSend(_ messageID: String) -> Bool { undoableSendIDs.contains(messageID) }

  private func armUndoSend(
    conversationID: String, target: String, text: String,
    paths: [String], replyID: String?, localID: String
  ) {
    var pending = PendingSend(
      conversationID: conversationID, target: target, text: text,
      paths: paths, replyID: replyID
    )
    pending.task = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(self?.undoSendDelay.seconds ?? 0))
      guard !Task.isCancelled, let self else { return }
      await self.releasePendingSend(localID)
    }
    pendingSends[localID] = pending
    undoableSendIDs.insert(localID)
  }

  private func releasePendingSend(_ localID: String) async {
    guard let pending = pendingSends.removeValue(forKey: localID) else { return }
    undoableSendIDs.remove(localID)
    await deliverOrRestore(
      conversationID: pending.conversationID, target: pending.target, text: pending.text,
      paths: pending.paths, replyID: pending.replyID, localID: localID
    )
  }

  /// « Annuler » sous la bulle : rien n'est parti, le texte revient au composer.
  /// Si le geste Focus avait archivé le fil, il revient dans la file — la
  /// décision d'archiver était celle d'un message envoyé, et il ne l'est plus.
  func undoSend(_ localID: String) {
    guard let pending = pendingSends.removeValue(forKey: localID) else { return }
    pending.task?.cancel()
    undoableSendIDs.remove(localID)
    inFlightBubbles.removeValue(forKey: localID)
    messages[pending.target]?.removeAll { $0.id == localID }
    setDraft(pending.text, conversationID: pending.conversationID)
    pendingAttachments[pending.conversationID] = pending.paths
    if let replyID = pending.replyID { replyTargets[pending.conversationID] = replyID }
    if let archived = pending.archivedConversationID {
      setArchived(false, conversationID: archived)
    }
  }

  /// Marque l'envoi en sursis de ce fil comme « archivé par le geste Focus ».
  func noteArchivedPendingSend(conversationID: String) {
    guard let key = pendingSends.first(where: { $0.value.conversationID == conversationID })?.key
    else { return }
    pendingSends[key]?.archivedConversationID = conversationID
  }

  // MARK: - Message vocal

  /// Le micro du composer. Un seul enregistreur pour l'app : on ne parle pas
  /// dans deux fils à la fois.
  let recorder = VoiceRecorder()

  /// Le doigt tient le micro (ou vient de le verrouiller). Le fil s'en sert
  /// pour retirer la pilule ↓ : elle occupe exactement la place où le guide du
  /// verrou monte, et deux pastilles superposées ne se lisent pas.
  var isHoldingMic = false

  /// Envoie ce qu'on vient d'enregistrer. La bulle apparaît tout de suite, le
  /// fichier part ensuite — la même discipline que le texte.
  func sendVoiceMessage(_ url: URL, voice: VoiceNote, conversationID: String) async {
    guard let target = sendingTarget(conversationID),
          let conversation = conversation(target)
    else { return }
    sendingConversationIDs.insert(conversationID)
    defer { sendingConversationIDs.remove(conversationID) }

    // Comme sur le Mac : les ponts refusent l'AAC d'entrée, le vocal part en
    // Ogg/Opus et la bulle relit le même fichier.
    let envoi = (try? await OggOpusEncoder.encodeVoiceNote(from: url)) ?? url
    let localID = UUID().uuidString
    var piece = MessageAttachment(
      id: envoi.path,
      contentType: OggOpusEncoder.contentType,
      filename: envoi.lastPathComponent,
      localPath: envoi.path
    )
    piece.voice = voice
    let optimistic = ChatMessage(
      id: localID,
      conversationID: target,
      network: conversation.network,
      text: "",
      sentAt: .now,
      isFromMe: true,
      isPending: true,
      attachments: [piece]
    )
    inFlightBubbles[localID] = optimistic
    messages[target, default: []].append(optimistic)

    guard !isDemo else { return }
    do {
      try await matrix.sendVoiceMessage(
        conversationID: target,
        fileURL: envoi,
        voice: voice,
        localID: localID
      )
      inFlightBubbles.removeValue(forKey: localID)
      await loadMessages(conversationID: conversationID, backfill: false)
    } catch {
      syncError = Self.readable(error)
      inFlightBubbles.removeValue(forKey: localID)
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
    inFlightBubbles[localID] = optimistic
    messages[target, default: []].append(optimistic)
  }

  // MARK: - Transférer

  /// La bulle que le sélecteur de fil s'apprête à renvoyer ailleurs.
  var forwardingMessage: ChatMessage?

  func beginForwarding(_ message: ChatMessage) {
    guard canForward(message) else { return }
    forwardingMessage = message
  }

  func cancelForwarding() { forwardingMessage = nil }

  /// Transférer, c'est réécrire : il faut du texte, ou un fichier qu'on a
  /// encore sur l'appareil.
  func canForward(_ message: ChatMessage) -> Bool {
    guard !message.isSystemEvent, !message.isRetracted, !message.isAgentProposal,
          message.poll == nil
    else { return false }
    return !message.text.isEmpty || !forwardablePaths(of: message).isEmpty
  }

  /// Les fils où déposer un transfert, la recherche du sélecteur appliquée.
  func forwardTargets(_ query: String) -> [Conversation] {
    let list = ConversationSearch.filter(
      mergedRows(conversations), query: query, index: searchIndex(query: query)
    )
    return Array(list.prefix(40))
  }

  /// Renvoie le message dans un autre fil, par le chemin d'envoi de CE fil-là.
  /// Comme Beeper, rien n'annonce que c'est un transfert.
  func forward(_ message: ChatMessage, to conversationID: String) async {
    defer { forwardingMessage = nil }
    guard !isDemo, let target = sendingTarget(conversationID) else { return }
    let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let paths = forwardablePaths(of: message)
    guard !text.isEmpty || !paths.isEmpty else { return }

    let localID = UUID().uuidString
    showOptimistically(text: text, paths: paths, in: target, localID: localID)
    lastSent = SentMark(conversationID: conversationID, localID: localID, serial: (lastSent?.serial ?? 0) + 1)
    do {
      try await matrix.send(
        conversationID: target, text: text, attachmentPaths: paths,
        localID: localID, replyToMessageID: nil
      )
      await loadMessages(conversationID: conversationID, backfill: false)
    } catch {
      syncError = Self.readable(error)
      messages[target]?.removeAll { $0.id == localID }
    }
  }

  /// Les fichiers d'un message qu'on peut vraiment renvoyer : ceux qu'on a
  /// encore sur l'appareil.
  private func forwardablePaths(of message: ChatMessage) -> [String] {
    message.attachments.map(MessageBubble.repaired).compactMap { $0.resolvedFileURL?.path }
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
  /// seulement là où le réseau sait le faire, et seulement dans la fenêtre
  /// qu'il laisse — quinze minutes chez Meta. Au-delà, le pont jette la
  /// correction sans le dire et elle n'existerait que sur cet iPhone.
  func canEdit(_ message: ChatMessage) -> Bool {
    message.isFromMe && !message.isPending && !message.isRetracted && !message.isSystemEvent
      && !message.text.isEmpty && message.network.acceptsEdit(sentAt: message.sentAt) && !isDemo
  }

  // MARK: - Propositions de l'agent

  /// Le réglage « répondre à voix haute par défaut ». Il part vers le Relais,
  /// où l'agent le relira à son prochain `/sync`.
  func setAgentDefaultMode(_ mode: AgentSettings.Mode) {
    guard mode != agentDefaultMode else { return }
    agentDefaultMode = mode
    relayNoteAgentSettings(AgentSettings(defaultMode: mode))
  }

  /// Adopté depuis le Relais : le Mac a pu trancher entre-temps.
  func installAgentSettings(_ settings: AgentSettings?) {
    let mode = settings?.defaultMode ?? AgentSettings.fallback.defaultMode
    if mode != agentDefaultMode { agentDefaultMode = mode }
  }

  /// « Envoyer » : le texte que « cc » propose part comme MON message, par le
  /// chemin d'envoi ordinaire. La proposition quitte ensuite le fil.
  ///
  /// Le brouillon en cours est mis de côté et rendu si l'envoi échoue : on ne
  /// perd pas ce qu'on écrivait, et la carte reste là pour réessayer.
  func sendAgentProposal(_ message: ChatMessage, conversationID: String) async {
    guard let proposal = message.agentProposal, !proposal.isEmpty else { return }
    let pending = draftText(conversationID)
    setDraft(proposal.text, conversationID: conversationID)
    await send(conversationID: conversationID)
    guard draftText(conversationID).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      setDraft(pending, conversationID: conversationID)
      return
    }
    setDraft(pending, conversationID: conversationID)
    hide(messageID: message.id, conversationID: conversationID)
  }

  /// « Modifier » : le texte descend dans le composer et la carte disparaît.
  /// Ce qu'on avait déjà écrit n'est pas écrasé — la proposition se pose à la suite.
  func editAgentProposal(_ message: ChatMessage, conversationID: String) {
    guard let proposal = message.agentProposal, !proposal.isEmpty else { return }
    let pending = draftText(conversationID).trimmingCharacters(in: .whitespacesAndNewlines)
    setDraft(pending.isEmpty ? proposal.text : pending + "\n" + proposal.text, conversationID: conversationID)
    hide(messageID: message.id, conversationID: conversationID)
  }

  /// « Ignorer » : la carte s'en va, rien n'est envoyé. Le masquage rejoint le
  /// Relais (`fr.correspondance.hidden`) : le Mac ne la remontrera pas non plus.
  func ignoreAgentProposal(_ message: ChatMessage, conversationID: String) {
    hide(messageID: message.id, conversationID: conversationID)
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

  /// « Supprimer pour tout le monde » est-il encore possible ?
  ///
  /// Les miens seulement, et dans la fenêtre du réseau : Signal ferme à 24 h,
  /// WhatsApp à 48 h, Meta ne ferme pas. Au-delà, la redaction part, le pont la
  /// jette, et la bulle ne disparaîtrait que de cet iPhone.
  func canDeleteEverywhere(_ message: ChatMessage) -> Bool {
    message.isFromMe && !message.isPending && !message.isSystemEvent && !isDemo
      && message.network != .iMessage
      && message.network.acceptsDeleteForEveryone(sentAt: message.sentAt)
  }

  /// Les six réactions rapides — les mêmes que sur le Mac.
  static let quickReactions = ["👍", "❤️", "😂", "😮", "😢", "🙏"]

  // MARK: - Gestes sur une ligne

  /// Ce qu'un « archiver tout ce qui est lu » emporterait — épingles et non
  /// lus épargnés (cf. `ArchiveSweep`).
  var readArchivableConversations: [Conversation] {
    ArchiveSweep.targets(
      conversations,
      pinned: viewState.pinned,
      archived: viewState.archived,
      asleep: Set(conversations.filter { viewState.isAsleep($0) }.map(\.id)),
      requests: viewState.pendingRequests
    )
  }

  /// Le geste de fin de journée : range d'un coup tout ce qui n'attend plus rien.
  func archiveAllRead() {
    for conversation in readArchivableConversations {
      setArchived(true, conversationID: conversation.id)
    }
  }

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

  // MARK: - La fiche d'un fil

  struct ThreadMember: Identifiable, Hashable {
    let userID: String
    let displayName: String?
    var id: String { userID }
    var name: String { displayName ?? MatrixIdentity.localpart(userID) }
  }

  /// « Inviter cc » a-t-il un sens ici : un fil dont cc n'est pas déjà membre.
  func agentInvitable(_ conversationID: String) async -> Bool {
    guard !isDemo, let target = relayTargets(of: conversationID).first else { return false }
    return await !matrix.hasAgent(conversationID: target)
  }

  /// Invite l'agent dans le fil ; « cc a rejoint la conversation » suivra.
  func inviteAgent(_ conversationID: String) async throws {
    guard let target = relayTargets(of: conversationID).first else { return }
    try await matrix.inviteAgent(conversationID: target)
  }

  /// Les correspondants d'un fil. En démonstration, il n'y a pas de salon :
  /// on relit les auteurs des messages, un par nom.
  func members(_ conversationID: String) async -> [ThreadMember] {
    guard isDemo else {
      return await matrix.members(conversationID: conversationID)
        .map { ThreadMember(userID: $0.userID, displayName: $0.displayName) }
    }
    var seen: Set<String> = []
    var result: [ThreadMember] = []
    for message in visibleMessages(conversationID) where !message.isFromMe {
      guard let name = message.displayedSenderName, seen.insert(name).inserted else { continue }
      result.append(ThreadMember(userID: message.senderID ?? name, displayName: name))
    }
    return result
  }

  /// Ajoute quelqu'un au groupe, par son numéro ou son pseudo selon le réseau.
  func inviteMember(_ identifier: String, conversationID: String) async throws {
    guard !isDemo else { return }
    try await matrix.inviteMember(conversationID: conversationID, identifier: identifier)
  }

  /// Renomme le groupe. Le nouveau nom part sur le réseau là où le pont le
  /// relaie — c'est `NetworkCapabilities` qui décide si le geste est offert.
  func renameGroup(_ name: String, conversationID: String) async throws {
    guard !isDemo else { return }
    try await matrix.renameGroup(conversationID: conversationID, name: name)
    await reloadFromRelay()
  }

  /// Retire quelqu'un du groupe. Le pont relaie le `kick` comme un retrait.
  func removeMember(_ userID: String, conversationID: String) async throws {
    guard !isDemo else { return }
    try await matrix.removeMember(conversationID: conversationID, userID: userID)
  }

  /// Les trois gestes de groupe, chacun masqué là où le pont ne le porte pas.
  func canRenameGroup(_ conversationID: String) -> Bool {
    groupCapability(conversationID) { $0.renamesGroup }
  }

  func canRemoveMember(_ conversationID: String) -> Bool {
    groupCapability(conversationID) { $0.removesMember }
  }

  func canInviteMember(_ conversationID: String) -> Bool {
    isDemo || groupCapability(conversationID) { $0.addsMember }
  }

  private func groupCapability(
    _ conversationID: String,
    _ keyPath: (NetworkCapabilities) -> Bool
  ) -> Bool {
    guard let conversation = conversation(conversationID), conversation.isGroup else { return false }
    return keyPath(conversation.network.capabilities)
  }

  /// Les photos et vidéos du fil, la plus récente d'abord — celles qu'on a
  /// déjà sur l'appareil, ou qu'on sait retrouver dans le cache.
  func media(_ conversationID: String) -> [MessageAttachment] {
    visibleMessages(conversationID).reversed().flatMap { message in
      message.attachments.map(MessageBubble.repaired).filter {
        ($0.isImage || $0.isVideo) && $0.resolvedFileURL != nil
      }
    }
  }

  // MARK: - Indicateurs de frappe

  /// « Alice écrit… » par fil, relu à chaque `/sync`. Vide = personne n'écrit.
  private(set) var typingLabels: [String: String] = [:]
  /// « Vu par Alice et Bruno » par fil de groupe, relu au même rythme.
  private(set) var seenByLabels: [String: String] = [:]
  /// Depuis quand on a dit au Relais qu'on écrit — pour renouveler plutôt que
  /// de le lui redire à chaque touche.
  private var typingSentAt: [String: Date] = [:]

  func typingLabel(_ conversationID: String) -> String? { typingLabels[conversationID] }
  func seenByLabel(_ conversationID: String) -> String? { seenByLabels[conversationID] }

  private func refreshTypingLabels() async {
    var labels: [String: String] = [:]
    var seen: [String: String] = [:]
    for id in Set([selectedConversationID, focusConversationID].compactMap { $0 }) {
      for target in relayTargets(of: id) {
        if let label = await matrix.typingLabel(conversationID: target) { labels[id] = label }
        if let label = await matrix.seenByLabel(conversationID: target) { seen[id] = label }
      }
    }
    if labels != typingLabels { typingLabels = labels }
    if seen != seenByLabels { seenByLabels = seen }
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
    // Le message vient peut-être d'être armé et pas encore parti : l'annuler
    // devra rendre le fil à la file, pas seulement le texte au composer.
    noteArchivedPendingSend(conversationID: id)
    focusConversationID = next
  }
}
