import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import CorrespondanceCore

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
      if normalizeMergedContacts() { return }
      conversationsDidChange()
    }
  }
  /// Vue « Archivés » de la liste (⌘⇧E). Ne change rien au stockage.
  var isShowingArchived = false
  /// Champ `.searchable` de la liste. Vide = pas de filtrage.
  var searchQuery = ""
  /// Bulle visée par les actions du fil (réagir, citer). `nil` = le dernier message.
  var selectedMessageID: String? {
    get { primarySession?.selectedMessageID }
    set { primarySession?.selectedMessageID = newValue }
  }
  /// Message que le brouillon en cours cite (⌘R). `nil` = réponse simple.
  var replyingToMessageID: String? { primarySession?.replyingToMessageID }
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

  // Le fil, le brouillon, l'envoi : rien de tout cela n'appartient au magasin,
  // tout appartient à la SESSION du fil (cf. `ConversationSession`). Ce qui
  // suit n'est que le raccourci de l'inbox vers la sienne — une fenêtre
  // détachée passe, elle, par la sienne propre.
  var messages: [ChatMessage] {
    get { primarySession?.messages ?? [] }
    set { primarySession?.messages = newValue }
  }
  var draftText: String {
    get { primarySession?.draftText ?? "" }
    set { primarySession?.draftText = newValue }
  }
  /// Chemins locaux d’images à envoyer avec le prochain message.
  var pendingAttachmentPaths: [String] {
    get { primarySession?.pendingAttachmentPaths ?? [] }
    set { primarySession?.pendingAttachmentPaths = newValue }
  }
  /// True seulement pendant la frappe active (pas le simple focus).
  /// Le chrome Focus se tait le temps d’écrire, puis revient à la pause.
  var isComposerFocused = false
  /// Messages programmés (⌘⇧L), tous fils confondus, triés par échéance.
  private(set) var scheduledMessages: [ScheduledMessage] = []
  /// Réglage « plus tard » du composer : tant qu'il est posé, Entrée programme
  /// au lieu d'envoyer (et ⌘Entrée programme puis archive).
  var sendLaterConfig: SendLaterConfig?
  /// Sélecteur « Quand ? » ouvert — pour le brouillon ou pour reprogrammer.
  var sendLaterPicker: SendLaterPickerTarget?
  /// Vue « Programmés » de la liste (bouton du rail). Ne change rien au stockage.
  var isShowingScheduled = false
  @ObservationIgnored private var scheduleDispatchTask: Task<Void, Never>?
  /// Chrome fantôme du Focus : la barre d'outils s'efface au repos et ne
  /// revient que si la souris monte en haut de la fenêtre, ou si l'on remonte
  /// le fil. Faux hors Focus, où la barre reste franchement visible.
  var isFocusChromeRevealed = false
  @ObservationIgnored private var isHoveringWindowTop = false
  @ObservationIgnored private var focusChromeHideTask: Task<Void, Never>?
  var isLoading = false
  /// Sync receive en cours (poll live).
  var isLiveSyncing = false
  var isSending: Bool {
    get { primarySession?.isSending ?? false }
    set { primarySession?.isSending = newValue }
  }
  var lastErrorMessage: String?
  var iMessageStatusFR: String = "…"
  var matrixStatusFR: String = "…"
  var contactsStatusFR: String = "…"
  /// Affiche une bannière si Contacts n’est pas encore autorisé.
  var needsContactsPermission = false
  var messagesAutomationStatusFR = "…"
  /// Lot M2 — réglage « Automatisation Messages » (pilotage AX de Messages.app,
  /// app cachée). Éteint, l'app se comporte exactement comme avant.
  var isMessagesAutomationEnabled = UserDefaults.standard.bool(forKey: Keys.messagesAutomation) {
    didSet {
      UserDefaults.standard.set(isMessagesAutomationEnabled, forKey: Keys.messagesAutomation)
      refreshMessagesAutomation()
    }
  }
  /// Option « fenêtre Messages hors écran » : repli pour les actions qui exigent
  /// une fenêtre réellement dessinée.
  var messagesAutomationOffscreenWindow = UserDefaults.standard.bool(forKey: Keys.messagesAutomationOffscreen) {
    didSet {
      UserDefaults.standard.set(messagesAutomationOffscreenWindow, forKey: Keys.messagesAutomationOffscreen)
      refreshMessagesAutomation()
    }
  }
  /// État de santé de la sonde AX, tel qu'affiché dans Réglages.
  private(set) var messagesAutomationHealth: IMessageAutomationHealth = .unknown
  var notificationStatusFR: String = "…"
  var isPresentingNewConversation = false
  /// Matrix joignable et session valide — conditionne les réseaux bridgés dans l'UI.
  var isMatrixConnected = false
  /// Réseau dont la feuille de connexion est ouverte — `nil` = aucune feuille.
  /// Un seul état pour les deux ponts : c'est le réseau qui choisit ce qui s'affiche.
  var bridgeLoginNetwork: MessageNetwork?
  var bridgeLoginQRData: Data?
  var bridgeLoginPairingCode: String?
  var bridgeLoginStatusFR = "…"
  var usingDemoData = false
  /// true tant que le premier plein chargement n’a pas fini (après hydrate cache).
  var isInitialSync = true
  /// Vrai une fois le premier `/sync` intégré (ou quand il n'y aura pas de sync :
  /// pas de session Matrix). Avant ça, ce qui arrive dans le fil n'est pas un
  /// message qui « vient d'arriver » mais le rattrapage de ce qui s'est passé
  /// app fermée — il se pose sans geste, comme le reste du fil.
  var didSettleInitialMatrixSync = false

  /// Préférences locales (pin / mute / timer) — aucun réseau ne les porte pour nous.
  private(set) var pinnedIDs: Set<String> = []
  private(set) var mutedIDs: Set<String> = []
  /// Fils archivés — persistés, donc réappliqués à chaque fusion (le catalogue
  /// d'un réseau ne connaît pas notre archivage et renvoie toujours `isArchived: false`).
  private(set) var archivedIDs: Set<String> = []
  /// Les conversations mises de côté, et l'heure à laquelle elles reviennent.
  /// L'état vit dans le Relais (`fr.correspondance.reminder`) — `UserDefaults`
  /// n'est que le cache qui permet d'afficher la file avant le premier `/sync`.
  private(set) var remindersByID: [String: ConversationReminder] = [:]
  /// Ce que j'ai décidé des demandes — acceptée, refusée. L'état vit dans le
  /// Relais (`fr.correspondance.request`), `UserDefaults` n'est que le cache.
  private(set) var requestDecisions: [String: ConversationRequest.Decision] = [:]
  /// Les numéros du carnet d'adresses rencontrés : ce qui distingue un inconnu.
  /// Rempli au fil des `/sync`, jamais demandé à Contacts pour l'occasion.
  private var knownCorrespondentIDs: Set<String> = []
  private(set) var disappearingSecondsByID: [String: Int] = [:]
  /// Messages supprimés « ici » (`HiddenMessageStore`) : le réseau les garde,
  /// le fil ne les montre plus. `private(set)` — la suppression passe par
  /// `InboxStore+Deletion`.
  private(set) var hiddenMessageIDs: Set<String> = HiddenMessageStore.load()
  /// Fusions de contacts — plusieurs réseaux, une seule ligne. Réappliquées
  /// après chaque fusion de catalogue, exactement comme l'archivage.
  private(set) var mergedContacts: [MergedContact] = []
  /// Propositions de fusion déjà refusées, pour qu'elles ne reviennent plus.
  private(set) var dismissedMergePairs: Set<String> = []
  /// Les fils membres, retirés de `conversations` mais gardés sous la main :
  /// c'est eux qu'on interroge pour charger le fil et pour envoyer. Sans ce
  /// cache, un rafraîchissement qui ne ramène qu'un seul membre casserait la
  /// ligne fusionnée en deux.
  @ObservationIgnored private var mergedMemberCache: [String: Conversation] = [:]

  private let iMessageDB = IMessageDatabase()
  private let iMessageSender = IMessageSender()
  let matrix = MatrixBridgeService()
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  /// Boucle `/sync` : un long-poll qui ne s'arrête jamais, sans intervalle à régler.
  @ObservationIgnored private var matrixSyncTask: Task<Void, Never>?
  @ObservationIgnored private var bridgeLoginTask: Task<Void, Never>?
  /// La commande `login` est-elle partie ? Le bot n'attend une session qu'après elle.
  @ObservationIgnored private var bridgeLoginCommandSent = false
  /// Session récoltée par la fenêtre avant que `login` ne parte — cas rare (réseau lent,
  /// session déjà ouverte), mais l'envoyer trop tôt la perdrait.
  @ObservationIgnored private var pendingWebSessionPayload: String?
  /// Temps réel iMessage : `chat.db-wal` surveillé plutôt qu'interrogé.
  @ObservationIgnored private let iMessageWatcher = IMessageWatcher()
  /// Un rafraîchissement iMessage copie `chat.db` en entier : jamais deux à la fois.
  @ObservationIgnored private var isRefreshingIMessage = false
  @ObservationIgnored private var lastIMessageRefreshAt: Date = .distantPast
  /// Dernier `lastMessageAt` déjà notifié, par conversation — évite de re-sonner
  /// pour un fil qu'un simple refresh a fait remonter sans nouveau message.
  @ObservationIgnored private var lastNotifiedAt: [String: Date] = [:]
  /// État de référence pour la comparaison : `oldValue` du `didSet` ne convient pas,
  /// la normalisation de l'archivage produit une passe intermédiaire.
  @ObservationIgnored private var notificationBaseline: [String: Conversation] = [:]
  /// L'utilisateur a-t-il *choisi* le fil sélectionné ? Au lancement, l'app en
  /// désigne un d'office — le plus récent, donc précisément celui qui vient de
  /// recevoir. Le traiter comme lu effacerait le non-lu qu'on cherche à rendre.
  /// Seul un vrai clic vaut lecture.
  @ObservationIgnored private(set) var selectionIsUserMade = false
  /// Fils qu'on a marqués « non lu » à la main. Un réseau bridgé fait autorité sur
  /// ses compteurs : sans cette liste, le `/sync` suivant écraserait le geste en
  /// moins de trente secondes, et le bouton ne servirait à rien.
  @ObservationIgnored private var manuallyUnreadIDs: Set<String> = []
  /// Corps replié des messages, par conversation — l'index de recherche, en mémoire.
  /// Alimenté par les trois caches disque puis par chaque fil ouvert.
  @ObservationIgnored private var searchIndex: [String: String] = [:]
  /// L'onglet de recherche actif — Images, Vidéos, Liens, Fichiers, Brouillons.
  /// `nil` = on cherche des conversations, pas des choses.
  var searchFacet: MessageFacet?
  /// Les messages qu'on a sous la main pour la recherche par médias, fil par
  /// fil. Rempli à la demande, jamais au lancement : c'est une passe sur les
  /// caches (les salons en mémoire, la base iMessage), pas une requête réseau.
  private(set) var facetMessages: [String: [ChatMessage]] = [:]
  private var isRefreshingFacetIndex = false
  /// Brouillons par conversation, restaurés au retour sur un fil.
  @ObservationIgnored private var drafts: [String: DraftStore.Draft] = [:]
  /// Écriture disque différée — on n'écrit pas un fichier à chaque frappe.
  @ObservationIgnored private var draftPersistTask: Task<Void, Never>?
  /// Le premier plein chargement ne notifie rien : sinon toute l'inbox sonne au lancement.
  @ObservationIgnored private var isNotificationPrimed = false

  // MARK: - Relais (ADR 0001)

  /// Écritures d'état qui n'ont pas encore atteint le Relais. Observé : Réglages
  /// en affiche le compte. Voir `InboxStore+Relay`.
  var relayQueue = RelayWriteQueue()
  /// Un envoi de file à la fois — deux passes concurrentes rejoueraient la même écriture.
  @ObservationIgnored var isFlushingRelay = false
  /// Brouillons en attente d'être poussés, une tâche par fil (≈ 1 s après la frappe).
  @ObservationIgnored var relayDraftTasks: [String: Task<Void, Never>] = [:]

  var selectedConversation: Conversation? {
    guard let selectedConversationID else { return nil }
    return conversations.first { $0.id == selectedConversationID }
  }

  // MARK: - Sessions

  /// Une session par fil ouvert, et une seule : l'inbox et la fenêtre détachée
  /// d'un même fil tiennent le même objet.
  @ObservationIgnored private var sessions: [String: ConversationSession] = [:]

  /// Les fils qui ont une fenêtre à eux. Observé : le menu Fenêtre en tire le
  /// libellé « Détacher » / « Ramener dans l'inbox ».
  private(set) var detachedConversationIDs: Set<String> = []

  /// La fenêtre détachée au premier plan, s'il y en a une.
  private(set) var frontDetachedConversationID: String?

  /// Le fil que le panneau de réponse rapide a sous les yeux, s'il est ouvert.
  private(set) var quickReplyConversationID: String?

  /// Les fils dont la fenêtre flotte au-dessus des autres apps (⌘⌥P).
  /// Relu du disque à l'ouverture de chaque fenêtre — voir `DetachedWindowState`.
  var pinnedDetachedIDs: Set<String> = []

  /// Les fenêtres détachées vivantes, pour aller en chercher une au premier plan
  /// (clic sur une notification). Voir `InboxStore+Detached`.
  @ObservationIgnored var detachedWindows: [String: NSWindow] = [:]

  /// Détachements demandés par un geste et pas encore honorés. La scène ne
  /// s'ouvre QUE sur geste : une fenêtre que la restauration système ressuscite
  /// au lancement ne trouve pas son jeton et se referme aussitôt.
  @ObservationIgnored var pendingDetachRequests: Set<String> = []

  /// La session d'un fil — créée à la demande, avec son brouillon déjà en place.
  func session(for conversationID: String) -> ConversationSession {
    if let existing = sessions[conversationID] { return existing }
    let session = ConversationSession(conversationID: conversationID, store: self)
    session.installDraft(drafts[conversationID] ?? DraftStore.Draft())
    sessions[conversationID] = session
    return session
  }

  /// La session de l'inbox : celle du fil sélectionné.
  var primarySession: ConversationSession? {
    guard let selectedConversationID else { return nil }
    return session(for: selectedConversationID)
  }

  /// Les sessions qu'on tient réellement à jour : celle de l'inbox et celles
  /// des fenêtres détachées. C'est chez elles que les messages entrants vont.
  var liveSessions: [ConversationSession] {
    var ids: [String] = []
    if let selectedConversationID { ids.append(selectedConversationID) }
    for id in detachedConversationIDs where !ids.contains(id) { ids.append(id) }
    if let quickReplyConversationID, !ids.contains(quickReplyConversationID) {
      ids.append(quickReplyConversationID)
    }
    return ids.map { session(for: $0) }
  }

  /// Un brouillon change dans une session : le magasin le range et l'écrit.
  func captureDraft(from session: ConversationSession) {
    let draft = session.draft
    if draft.isEmpty {
      drafts.removeValue(forKey: session.conversationID)
    } else {
      drafts[session.conversationID] = draft
    }
    scheduleDraftPersist()
    // Le Relais ne reçoit que le texte, et pas à chaque frappe (cf. InboxStore+Relay).
    scheduleRelayDraftPush(conversationID: session.conversationID, text: draft.text)
  }

  /// Une fenêtre détachée s'ouvre.
  func noteDetached(_ conversationID: String) {
    detachedConversationIDs.insert(conversationID)
    _ = session(for: conversationID)
  }

  /// Une fenêtre détachée se ferme : sa session ne survit que si l'inbox la lit.
  func noteReattached(_ conversationID: String) {
    detachedConversationIDs.remove(conversationID)
    if frontDetachedConversationID == conversationID { frontDetachedConversationID = nil }
    pruneSessions()
  }

  func noteDetachedWindowFront(_ conversationID: String?) {
    frontDetachedConversationID = conversationID
  }

  /// `pruneSessions` est privé : la fermeture du panneau passe par ici.
  func pruneSessionsAfterQuickReply() {
    pruneSessions()
  }

  /// Une session sans fenêtre n'a plus de raison d'occuper la mémoire.
  private func pruneSessions() {
    let kept = Set(liveSessions.map(\.conversationID))
    sessions = sessions.filter { kept.contains($0.key) }
  }

  var activeQueue: [Conversation] {
    conversations
      .filter { !$0.isArchived && !isAsleep($0) && !isRequest($0) && matchesNetworkFilter($0) }
      .sorted(by: { sortForInbox($0, $1) })
  }

  /// File complète, rail ignoré — pour les compteurs et le repli de sélection.
  var unfilteredQueue: [Conversation] {
    conversations
      .filter { !$0.isArchived && !isAsleep($0) && !isRequest($0) }
      .sorted(by: { sortForInbox($0, $1) })
  }

  /// Les conversations mises de côté, dans l'ordre où leurs rappels sonnent.
  var remindersQueue: [Conversation] {
    conversations
      .filter { isAsleep($0) && !isRequest($0) && matchesNetworkFilter($0) }
      .sorted { lhs, rhs in
        let l = remindersByID[lhs.id]?.wakeAt ?? .distantFuture
        let r = remindersByID[rhs.id]?.wakeAt ?? .distantFuture
        if l != r { return l < r }
        return lhs.id < rhs.id
      }
  }

  /// Cette conversation dort-elle encore ? Le rappel décide, pas nous.
  func isAsleep(_ conversation: Conversation, now: Date = Date()) -> Bool {
    guard let reminder = remindersByID[conversation.id] else { return false }
    return reminder.isAsleep(
      now: now,
      lastMessageAt: conversation.lastMessageAt,
      lastMessageIsFromMe: conversation.lastMessageIsFromMe
    )
  }

  func reminder(_ id: String) -> ConversationReminder? { remindersByID[id] }

  // MARK: - Recherche par médias

  /// Les résultats de l'onglet actif, tous fils confondus, du plus récent au
  /// plus ancien. Vide tant qu'aucun onglet n'est choisi.
  var facetHits: [FacetedSearch.Hit] {
    guard let facet = searchFacet, !facet.isConversationFacet else { return [] }
    return FacetedSearch.hits(in: conversations, facet: facet, query: searchQuery) {
      facetMessages[$0.id] ?? []
    }
  }

  /// Les fils qui portent un brouillon — l'onglet « Brouillons ».
  var facetDrafts: [Conversation] {
    FacetedSearch.conversationsWithDrafts(
      conversations,
      drafts: drafts.mapValues(\.text),
      query: searchQuery
    )
  }

  /// Choisit un onglet et remplit ce qu'il faut pour y répondre.
  func setSearchFacet(_ facet: MessageFacet?) {
    searchFacet = facet
    guard let facet, !facet.isConversationFacet else { return }
    Task { await refreshFacetIndex() }
  }

  /// Rassemble les messages déjà chargés : les salons du pont (déjà en
  /// mémoire), les fils ouverts, puis la base iMessage — celle-là hors du fil
  /// principal, c'est la seule qui coûte quelque chose.
  func refreshFacetIndex() async {
    guard !isRefreshingFacetIndex else { return }
    isRefreshingFacetIndex = true
    defer { isRefreshingFacetIndex = false }

    var index = facetMessages
    for conversation in conversations where conversation.network.livesOnRelay {
      let list = await matrix.messages(conversationID: conversation.id)
      if !list.isEmpty { index[conversation.id] = list }
    }
    for session in liveSessions where !session.messages.isEmpty {
      index[session.conversationID] = session.messages
    }
    let iMessageKeys = conversations
      .filter { $0.network == .iMessage }
      .map { (id: $0.id, chatGUID: $0.transportKey) }
    if !iMessageKeys.isEmpty {
      let db = iMessageDB
      let fetched = await Task.detached(priority: .utility) { () -> [String: [ChatMessage]] in
        var result: [String: [ChatMessage]] = [:]
        for key in iMessageKeys {
          if let list = try? db.fetchMessages(chatGUID: key.chatGUID), !list.isEmpty {
            result[key.id] = list
          }
        }
        return result
      }.value
      index.merge(fetched) { _, fresh in fresh }
    }
    facetMessages = index
  }

  // MARK: - Demandes

  /// Les conversations d'inconnus qui attendent une décision. Elles ne sont
  /// dans aucune file — c'est tout ce qu'une demande a de particulier.
  var requestsQueue: [Conversation] {
    conversations
      .filter { isRequest($0) && matchesNetworkFilter($0) }
      .sorted { $0.lastMessageAt > $1.lastMessageAt }
  }

  func isRequest(_ conversation: Conversation) -> Bool {
    RequestPolicy.isRequest(
      conversation,
      signals: requestSignals(conversation),
      decision: requestDecisions[conversation.id]
    )
  }

  func isRequest(_ id: String) -> Bool {
    guard let conversation = conversations.first(where: { $0.id == id }) else { return false }
    return isRequest(conversation)
  }

  /// Ce que le Mac sait dire d'un fil : ai-je écrit, et est-ce quelqu'un que
  /// je connais (carnet d'adresses, ou contact fusionné) ?
  private func requestSignals(_ conversation: Conversation) -> RequestSignals {
    // `nil` tant qu'on n'a pas le fil sous les yeux : on ne range jamais une
    // conversation sur un soupçon. Un dernier mot de moi, ou un brouillon,
    // suffisent en revanche à trancher sans rien charger.
    var wrote: Bool?
    if conversation.lastMessageIsFromMe
      || !(drafts[conversation.id]?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      wrote = true
    } else if selectedConversationID == conversation.id, !messages.isEmpty {
      wrote = messages.contains(where: \.isFromMe)
    }
    let known = knownCorrespondentIDs.contains(conversation.id)
      || mergedContacts.contains { $0.memberIDs.contains(conversation.id) }
    return RequestSignals(
      hasWrittenBack: wrote,
      isKnownCorrespondent: known,
      isFlaggedByNetwork: networkFlaggedRequestIDs.contains(conversation.id)
    )
  }

  /// Les fils que le pont annonce lui-même comme des demandes. Relu à chaque
  /// `/sync` : c'est de l'état de salon, pas de l'état de conversation.
  private(set) var networkFlaggedRequestIDs: Set<String> = []

  /// Note qui, dans cette liste, est déjà au carnet d'adresses. Appelé au même
  /// endroit que l'enrichissement des titres : le carnet est alors chaud.
  func noteKnownCorrespondents(in list: [Conversation]) async {
    for conversation in list where !conversation.isGroup && conversation.address.hasPrefix("+") {
      if await ContactDirectory.shared.isKnown(handle: conversation.address) {
        knownCorrespondentIDs.insert(conversation.id)
      }
    }
  }

  /// Accepter fait entrer la conversation dans la file ; refuser la range.
  func decideRequest(_ decision: ConversationRequest.Decision?, conversationID: String) async {
    let ids = expandedIDs(for: conversationID)
    for id in ids {
      if let decision { requestDecisions[id] = decision }
      else { requestDecisions.removeValue(forKey: id) }
    }
    persistFlags()
    relayNoteRequest(decision, conversationIDs: ids)
    if decision == .declined { await setArchived(true, conversationID: conversationID) }
  }

  /// Met une conversation de côté jusqu'à une heure — ou la ramène (`nil`).
  /// Le geste est immédiat ; l'écriture vers le Relais suit.
  func setReminder(_ wakeAt: Date?, conversationID: String) {
    let ids = expandedIDs(for: conversationID)
    let reminder = wakeAt.map { ConversationReminder(wakeAt: $0) }
    for id in ids {
      if let reminder { remindersByID[id] = reminder } else { remindersByID.removeValue(forKey: id) }
    }
    persistFlags()
    relayNoteReminder(reminder, conversationIDs: ids)
    // Ranger le fil ouvert enchaîne sur le suivant — c'est le geste de la file.
    if wakeAt != nil, selectedConversationID == conversationID {
      Task { await select(activeQueue.first?.id) }
    }
  }

  private func matchesNetworkFilter(_ conversation: Conversation) -> Bool {
    guard let networkFilter else { return true }
    if conversation.network == networkFilter { return true }
    // Une ligne fusionnée porte le réseau de son dernier message : elle doit
    // quand même apparaître sous le rail de l'autre réseau qu'elle réunit.
    guard isMerged(conversation.id) else { return false }
    return memberConversations(of: conversation.id).contains { $0.network == networkFilter }
  }

  /// Non-lus du rail. `nil` = « Tous ».
  func unreadCount(for network: MessageNetwork?) -> Int {
    conversations.reduce(0) { total, conversation in
      guard !conversation.isArchived else { return total }
      guard let network else { return total + conversation.unreadCount }
      if conversation.network == network { return total + conversation.unreadCount }
      // Une ligne réunie ne porte que le réseau de son dernier message : ses
      // non-lus se comptent sous chacun des réseaux qu'elle rassemble.
      guard isMerged(conversation.id) else { return total }
      return total + memberConversations(of: conversation.id)
        .filter { $0.network == network }
        .reduce(0) { $0 + $1.unreadCount }
    }
  }

  /// Les vraies conversations d'un réseau — sans les lignes virtuelles de
  /// fusion, qui n'ont ni entrée dans `chat.db` ni fiche au carnet d'adresses.
  /// Les confondre, c'est écrire un identifiant `merged:` dans le cache disque
  /// iMessage, puis voir cette ligne fantôme survivre à une séparation.
  private func realConversations(on network: MessageNetwork) -> [Conversation] {
    conversations.filter { $0.network == network && !MergedContact.isMergedID($0.id) }
  }

  /// Le rail n'affiche un réseau que s'il est réellement branché ou déjà peuplé.
  func hasConversations(on network: MessageNetwork) -> Bool {
    conversations.contains { conversation in
      guard !conversation.isArchived else { return false }
      if conversation.network == network { return true }
      // Sans ça, fusionner l'unique fil d'un réseau ferait disparaître son rail.
      guard isMerged(conversation.id) else { return false }
      return memberConversations(of: conversation.id).contains { $0.network == network }
    }
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

  /// Recherche indépendante de celle de la liste — le mini-sélecteur (⌘K) du
  /// panneau de réponse rapide cherche sans déranger le champ de l'inbox.
  func quickSearch(_ query: String) -> [Conversation] {
    ConversationSearch.filter(activeQueue, query: query, index: searchIndex)
  }

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
    // Les photos de portail passent par le service : le store d'avatars ne le connaît
    // pas, on lui prête juste de quoi télécharger — **dès maintenant**. Les lignes de
    // l'inbox se dessinent depuis le cache avant la première passe `/sync` ; si le
    // chargeur n'était posé qu'à ce moment-là, un `mxc` déjà connu ne relancerait
    // jamais sa tâche et le fil garderait ses initiales jusqu'à un changement de photo.
    let bridge = matrix
    Task {
      await ConversationAvatarStore.shared.setMatrixAvatarLoader { mxc in
        await bridge.avatarData(mxcURI: mxc)
      }
      // Même prêt pour les visages des bulles : le fil d'un groupe demande la
      // photo d'un membre, pas celle du portail.
      await SenderAvatarStore.shared.setMatrixMemberAvatarLoader { conversationID, userID in
        await bridge.memberAvatarData(conversationID: conversationID, userID: userID)
      }
    }
    archivedIDs = Set(UserDefaults.standard.stringArray(forKey: Keys.archivedIDs) ?? [])
    if let data = UserDefaults.standard.data(forKey: Keys.reminders),
       let stored = try? JSONDecoder().decode([String: ConversationReminder].self, from: data)
    {
      remindersByID = stored
    }
    if let data = UserDefaults.standard.data(forKey: Keys.requests),
       let stored = try? JSONDecoder().decode([String: ConversationRequest.Decision].self, from: data)
    {
      requestDecisions = stored
    }
    manuallyUnreadIDs = Set(UserDefaults.standard.stringArray(forKey: Keys.manuallyUnread) ?? [])
    drafts = DraftStore.load()
    relayQueue = RelayWriteQueue.load(from: .standard, key: Keys.relayQueue)
    let mergeStore = MergedContactStore.load()
    mergedContacts = mergeStore.merged
    dismissedMergePairs = mergeStore.dismissedPairs
    scheduledMessages = ScheduledMessageStore.load()
    startScheduleDispatcher()
    if let data = UserDefaults.standard.data(forKey: Keys.disappearing),
       let decoded = try? JSONDecoder().decode([String: Int].self, from: data)
    {
      disappearingSecondsByID = decoded
    }
    migrateAwayFromSignalCLI()
    hydrateFromDiskCache()
    adoptMergedAvatars()
  }

  /// Bascule de `signal-cli` vers mautrix-signal, jouée une seule fois.
  ///
  /// Les fils Signal changent d'identité : `signal:+336…` et `signal-group:<base64>`
  /// laissent la place aux salons Matrix. Tout ce qui indexait les anciens
  /// identifiants — épingles, sourdines, archives, timers, fusions de contacts —
  /// désignerait donc des fils qui n'existent plus. On purge plutôt que de laisser
  /// traîner des orphelins que rien ne viendra jamais nettoyer.
  ///
  /// Le cache disque de signal-cli, lui, n'est PAS supprimé : c'est la seule copie
  /// de l'historique d'avant la liaison, que le pont ne rejouera jamais. Il ne sert
  /// plus à rien dans l'app, mais l'effacer serait irréversible.
  private func migrateAwayFromSignalCLI() {
    guard !UserDefaults.standard.bool(forKey: Keys.signalCLIMigration) else { return }

    let isLegacySignalID: (String) -> Bool = {
      $0.hasPrefix("signal:") || $0.hasPrefix("signal-group:")
    }

    pinnedIDs = pinnedIDs.filter { !isLegacySignalID($0) }
    mutedIDs = mutedIDs.filter { !isLegacySignalID($0) }
    archivedIDs = archivedIDs.filter { !isLegacySignalID($0) }
    remindersByID = remindersByID.filter { !isLegacySignalID($0.key) }
    requestDecisions = requestDecisions.filter { !isLegacySignalID($0.key) }
    disappearingSecondsByID = disappearingSecondsByID.filter { !isLegacySignalID($0.key) }
    persistFlags()

    // Une fusion privée d'un de ses membres se réduit ; à moins de deux fils, elle
    // n'a plus d'objet et se dissout. Le repérage de doublons la reproposera de
    // lui-même quand le salon Signal correspondant sera arrivé.
    for index in mergedContacts.indices.reversed() {
      mergedContacts[index].memberIDs.removeAll(where: isLegacySignalID)
      if let last = mergedContacts[index].lastUsedConversationID, isLegacySignalID(last) {
        mergedContacts[index].lastUsedConversationID = nil
      }
      if mergedContacts[index].memberIDs.count < 2 {
        mergedContacts.remove(at: index)
      }
    }
    persistMergedContacts()

    // Un message programmé vers un fil qui n'existe plus échouerait à l'échéance
    // sur « Conversation introuvable », et resterait en erreur pour toujours ; un
    // brouillon legacy, lui, deviendrait un orphelin qu'aucune vue n'affiche.
    scheduledMessages.removeAll { isLegacySignalID($0.conversationID) }
    ScheduledMessageStore.save(scheduledMessages)
    drafts = drafts.filter { !isLegacySignalID($0.key) }
    DraftStore.save(drafts)

    // Le marqueur de non-lus de signal-cli n'a plus de fils à désigner : les
    // compteurs viennent désormais du `/sync`, comme pour les autres ponts.
    UserDefaults.standard.removeObject(forKey: "correspondance.signalLastSeenAt")

    UserDefaults.standard.set(true, forKey: Keys.signalCLIMigration)
  }

  /// Affiche tout de suite les caches iMessage + Matrix (démarrage type Messages).
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

    // Le cache Matrix est un simple fichier : lisible sans passer par l'actor.
    let (_, matrixConversations, matrixMessages) = MatrixConversationCache.load()
    seedSearchIndex(signal: [:], matrix: matrixMessages)
    if !matrixConversations.isEmpty {
      list.append(contentsOf: matrixConversations)
      matrixStatusFR = "Cache · \(MatrixBridgeService.bridgedCountFR(matrixConversations)) — sync…"
    } else {
      matrixStatusFR = "Matrix : non connecté."
    }

    guard !list.isEmpty else { return }

    conversations = list.sorted(by: { sortForInbox($0, $1) })
    selectedConversationID = inboxRecents.first?.id
      ?? inboxGroups.first?.id
      ?? activeQueue.first?.id
    selectionIsUserMade = false
    if let id = selectedConversationID {
      if let cached = matrixMessages[id], !cached.isEmpty {
        messages = cached
      }
    }
  }

  /// Point d’entrée app : hydrate (déjà fait) + plein load + boucle receive.
  func start() async {
    // Demande Contacts tout de suite (sinon l’app n’apparaît pas dans Confidentialité).
    await requestContactsPermission()
    requestMessagesAutomation()
    // Lot M2 : sonde l'arbre AX de Messages au lancement (résultat dans Réglages).
    refreshMessagesAutomation()
    NotificationService.shared.onOpenConversation = { [weak self] id in
      guard let self else { return }
      Task { @MainActor in
        // Une notification peut viser un fil désormais replié : on ouvre la
        // ligne fusionnée, pas un membre qui n'est plus dans la liste.
        let rowID = self.displayRowID(for: id)
        // Ce fil a déjà sa fenêtre : c'est elle qu'on ramène devant, pas l'inbox.
        if self.raiseDetachedWindow(for: rowID) { return }
        if DetachedWindowState.notificationsOpenDetached() {
          self.detach(conversationID: rowID)
          return
        }
        WindowOpener.shared.openInbox()
        self.mode = .inbox
        await self.select(rowID)
      }
    }
    NotificationService.shared.onQuickReply = { [weak self] id, text in
      guard let self else { return }
      Task { @MainActor in
        await self.sendFromNotification(conversationID: id, text: text)
      }
    }
    NotificationService.shared.onOpenQuickReply = { [weak self] id in
      guard let self else { return }
      Task { @MainActor in
        QuickReplyPanelController.shared.present(conversationID: self.displayRowID(for: id))
      }
    }
    await NotificationService.shared.requestAuthorization()
    await load()
    // Ce qui est déjà là au démarrage n'est pas « nouveau » : on prend l'état pour
    // référence, puis seuls les messages suivants déclenchent une notification.
    primeNotifications()
    startMatrixSync()
    startIMessageWatch()
  }

  // MARK: - Temps réel iMessage

  /// Intervalle plancher entre deux relectures de chat.db. Le debounce du watcher
  /// (500 ms) absorbe une rafale ; celui-ci protège d'une écriture continue.
  static let minimumIMessageRefreshInterval: TimeInterval = 3

  /// Messages écrit dans le journal WAL de chat.db à chaque message : on y réagit
  /// plutôt que d'attendre un ⌘⇧R. Sans accès disque, le statut le dit.
  func startIMessageWatch() {
    let armed = iMessageWatcher.start { [weak self] in
      await self?.refreshIMessageIncrementally()
    }
    if !armed, !usingDemoData {
      iMessageStatusFR += " (temps réel indisponible — vérifie l’accès disque)"
    }
  }

  func stopIMessageWatch() {
    iMessageWatcher.stop()
  }

  /// Relecture ciblée de chat.db : les conversations iMessage et, si c'en est une,
  /// le fil ouvert. Ne touche ni à Signal ni à Matrix, qui ont leurs propres boucles.
  private func refreshIMessageIncrementally() async {
    guard !isLoading, !usingDemoData else { return }
    // Chaque passe copie `chat.db` (liste, puis fil ouvert). Messages écrit dans le WAL
    // en rafale : sans ces deux garde-fous, on empile des copies de la base entière.
    guard !isRefreshingIMessage else { return }
    guard Date().timeIntervalSince(lastIMessageRefreshAt) >= Self.minimumIMessageRefreshInterval else {
      return
    }
    isRefreshingIMessage = true
    defer {
      isRefreshingIMessage = false
      lastIMessageRefreshAt = Date()
    }
    guard case .success(let fresh) = await loadIMessageOffMain() else { return }

    var byID = Dictionary(conversations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    var enriched = fresh
    ContactDirectoryDisk.enrichIMessageTitles(&enriched)

    for incoming in enriched {
      if var existing = byID[incoming.id] {
        // Le titre déjà résolu par Contacts vaut mieux qu'un handle brut.
        existing.preview = incoming.preview
        existing.lastMessageAt = max(existing.lastMessageAt, incoming.lastMessageAt)
        existing.lastDelivery = incoming.lastDelivery
        existing.lastMessageIsFromMe = incoming.lastMessageIsFromMe
        // chat.db fait foi sur la nature du fil : un cache d'avant la
        // détection par `style` tenait certains groupes pour des tête-à-tête.
        existing.isGroup = incoming.isGroup
        existing.transportKey = incoming.transportKey
        existing.preferTitle(incoming.title)
        byID[incoming.id] = existing
      } else {
        byID[incoming.id] = incoming
      }
    }

    conversations = Array(byID.values).sorted(by: { sortForInbox($0, $1) })
    IMessageConversationCache.save(realConversations(on: .iMessage))

    for session in liveSessions {
      let id = session.conversationID
      guard conversations.first(where: { $0.id == id })?.network == .iMessage else { continue }
      await loadMessages(into: session)
      indexMessages(session.messages, conversationID: id)
      if session === primarySession { refreshThreadSearchMatches() }
      if isAttended(id) { clearUnread(for: id) }
    }
  }

  // MARK: - Brouillons

  /// Un fil porte un brouillon non envoyé — la liste peut le signaler.
  func hasDraft(_ conversationID: String) -> Bool {
    drafts[conversationID]?.isEmpty == false
  }

  /// Écriture différée : une frappe ne doit pas déclencher une écriture disque.
  private func scheduleDraftPersist() {
    draftPersistTask?.cancel()
    let snapshot = drafts
    draftPersistTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(600))
      guard !Task.isCancelled else { return }
      DraftStore.save(snapshot)
    }
  }

  private func persistDraftsNow() {
    draftPersistTask?.cancel()
    DraftStore.save(drafts)
  }

  // MARK: - Réponses citées

  /// La citation affichée au-dessus du composer, s'il y en a une.
  var replyingToMessage: ChatMessage? { primarySession?.replyingToMessage }

  /// ⌘R : cite la bulle visée. Rappuyer sur la même annule la citation.
  func replyToSelectedMessage() {
    replyToSelectedMessage(in: primarySession)
  }

  func replyToSelectedMessage(in session: ConversationSession?) {
    guard let session, let message = session.actionableMessage else { return }
    session.replyingToMessageID = session.replyingToMessageID == message.id ? nil : message.id
  }

  func cancelReply() {
    primarySession?.replyingToMessageID = nil
  }

  // MARK: - Réactions

  /// Palette courte : de quoi accuser réception sans ouvrir un catalogue d'emoji.
  static let quickReactions = ["👍", "❤️", "😂", "😮", "😢", "🙏"]

  /// Message visé par une action du fil : la bulle sélectionnée, sinon la dernière.
  var actionableMessage: ChatMessage? { primarySession?.actionableMessage }

  func selectMessage(_ id: String?) {
    selectedMessageID = id
  }

  /// ⌘⇧R : pose (ou retire) 👍 sur la bulle visée.
  func quickReactToSelectedMessage() async {
    guard let message = actionableMessage else { return }
    await react(messageID: message.id, emoji: Self.quickReactions[0])
  }

  /// Pose, remplace ou retire ma réaction. Reposer le même emoji le retire :
  /// les trois réseaux n'en acceptent qu'un par personne et par message.
  /// Voter sur un sondage. Le geste bascule ; seuls les fils bridgés en ont —
  /// iMessage ne connaît pas les sondages.
  func votePoll(messageID: String, answerID: String) async {
    guard let message = messages.first(where: { $0.id == messageID }),
          let conversation = conversation(ofMessage: message),
          conversation.network.livesOnRelay, isMatrixConnected
    else { return }
    do {
      try await matrix.votePoll(
        conversationID: conversation.id,
        pollMessageID: messageID,
        answerID: answerID
      )
      await loadMessagesForSelection()
    } catch {
      lastErrorMessage = error.localizedDescription
    }
  }

  /// Ouvre la note à soi, en la créant au premier usage. Un salon du Relais
  /// dont on est le seul membre : ce qu'on s'y écrit se retrouve sur l'iPhone.
  func openSelfNote() async {
    guard isMatrixConnected else {
      lastErrorMessage = "Matrix n’est pas connecté — vérifie Réglages → Matrix."
      return
    }
    do {
      _ = try await matrix.ensureSelfNote()
      var fresh = await matrix.conversations()
      await ContactDirectory.shared.enrichBridgedTitles(&fresh)
      mergeMatrixConversations(fresh)
      guard let id = await matrix.selfNoteConversationID() else { return }
      isShowingArchived = false
      await select(id)
    } catch {
      lastErrorMessage = error.localizedDescription
    }
  }

  func react(messageID: String, emoji: String) async {
    guard let message = messages.first(where: { $0.id == messageID }),
          // Sur un fil fusionné, la réaction part sur le réseau de la bulle
          // visée — pas sur celui où l'on écrit en ce moment.
          let conversation = conversation(ofMessage: message)
    else { return }

    switch conversation.network {
    case .iMessage:
      // AppleScript n'a pas de commande de tapback : c'est l'automatisation
      // Accessibilité (Lot M2) qui pose le geste, Messages restant cachée.
      await sendTapbackViaAutomation(conversation: conversation, message: message, emoji: emoji)

    case .signal, .whatsapp, .instagram, .selfNote:
      guard isMatrixConnected else {
        lastErrorMessage = "Matrix n’est pas connecté — vérifie Réglages → Matrix."
        return
      }
      do {
        try await matrix.toggleReaction(
          conversationID: conversation.id,
          messageID: messageID,
          emoji: emoji
        )
        // Recharge par le fil, pas par le réseau : une fusion en a deux.
        await loadMessagesForSelection()
      } catch {
        lastErrorMessage = error.localizedDescription
      }
    }
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

  func refreshThreadSearchMatches() {
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

  // MARK: - Fusion de contacts

  /// Replie les membres fusionnés en une seule ligne. Comme l'archivage, aucun
  /// réseau ne connaît nos fusions : la passe se rejoue après chaque catalogue.
  /// Renvoie `true` si la liste a été ré-assignée (le `didSet` va repasser).
  @discardableResult
  private func normalizeMergedContacts() -> Bool {
    guard !mergedContacts.isEmpty else { return false }
    cacheMergedMembers()
    // Les membres absents de la liste (un rafraîchissement partiel les a effacés)
    // reviennent du cache : sans eux, la ligne se rouvrirait en deux.
    let present = Set(conversations.map(\.id))
    let pool = conversations + mergedMemberCache.values
      .filter { !present.contains($0.id) }
      .sorted { $0.id < $1.id }

    let next = MergedContact.apply(to: pool, merged: mergedContacts)
    guard next != conversations else { return false }
    conversations = next
    return true
  }

  /// Mémorise les fils membres encore visibles, avant qu'ils ne quittent la liste.
  private func cacheMergedMembers() {
    let wanted = Set(mergedContacts.flatMap(\.memberIDs))
    guard !wanted.isEmpty else { return }
    for conversation in conversations where wanted.contains(conversation.id) {
      mergedMemberCache[conversation.id] = conversation
    }
  }

  func isMerged(_ id: String) -> Bool {
    MergedContact.isMergedID(id) && mergedContacts.contains { $0.id == id }
  }

  func mergedContact(for id: String) -> MergedContact? {
    mergedContacts.first { $0.id == id }
  }

  /// Les fils réunis sous une ligne fusionnée, du plus récent au plus ancien.
  func memberConversations(of id: String) -> [Conversation] {
    guard let contact = mergedContact(for: id) else { return [] }
    let byID = Dictionary(conversations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    return contact.memberIDs
      .compactMap { byID[$0] ?? mergedMemberCache[$0] }
      .sorted { $0.lastMessageAt > $1.lastMessageAt }
  }

  /// Le fil où l'on écrit : le dernier réseau utilisé, sinon le chat par défaut.
  func activeMember(of id: String) -> Conversation? {
    guard let contact = mergedContact(for: id) else { return nil }
    let members = memberConversations(of: id)
    guard let activeID = contact.activeMemberID(among: Set(members.map(\.id))) else {
      return members.first
    }
    return members.first { $0.id == activeID } ?? members.first
  }

  /// La ligne de la liste qui porte cet identifiant.
  func conversationRow(_ id: String) -> Conversation? {
    conversations.first { $0.id == id }
  }

  /// La conversation que vise réellement un envoi : le membre actif d'une ligne
  /// fusionnée, la conversation elle-même sinon.
  var sendingConversation: Conversation? {
    guard let selected = selectedConversation else { return nil }
    return sendingConversation(for: selected)
  }

  func sendingConversation(for row: Conversation) -> Conversation? {
    guard isMerged(row.id) else { return row }
    return activeMember(of: row.id)
  }

  /// La conversation d'où vient une bulle — pour réagir, citer ou accuser
  /// réception sur le bon réseau quand le fil est fusionné.
  func conversation(ofMessage message: ChatMessage) -> Conversation? {
    guard let selected = selectedConversation else {
      return conversations.first { $0.id == message.conversationID }
    }
    return conversation(ofMessage: message, in: selected)
  }

  func conversation(ofMessage message: ChatMessage, in row: Conversation) -> Conversation? {
    if row.id == message.conversationID { return row }
    if isMerged(row.id) {
      if let member = memberConversations(of: row.id).first(where: { $0.id == message.conversationID }) {
        return member
      }
      return activeMember(of: row.id)
    }
    return conversations.first { $0.id == message.conversationID } ?? row
  }

  /// Ce fil est-il sous les yeux de quelqu'un ? C'est-à-dire : sélectionné *et*
  /// sélectionné par un geste. Un fil que l'app a désigné d'office au lancement
  /// est affiché sans être lu — lui effacer ses non-lus, c'est faire disparaître
  /// sans trace les messages arrivés pendant la nuit.
  private func isReadOnScreen(_ conversationID: String) -> Bool {
    selectionIsUserMade && displayRowID(for: conversationID) == selectedConversationID
  }

  /// L'utilisateur agit dans le fil affiché (il clique dedans, écrit, envoie) :
  /// il le lit, quand bien même il ne l'a jamais choisi dans la liste. Sans ce
  /// rattrapage, la ligne auto-sélectionnée au lancement garderait son badge
  /// pour toujours — `List(selection:)` ne renotifie pas un clic sur la ligne
  /// déjà sélectionnée, donc `select()` n'est jamais appelé pour elle.
  func confirmSelectionAsRead() {
    guard let id = selectedConversationID, !selectionIsUserMade else { return }
    selectionIsUserMade = true
    clearUnread(for: id)
  }

  /// La ligne visible pour un identifiant : la fusionnée si le fil y est replié.
  func displayRowID(for conversationID: String) -> String {
    if let contact = mergedContacts.first(where: { $0.memberIDs.contains(conversationID) }) {
      return contact.id
    }
    return conversationID
  }

  /// Un geste posé sur une ligne fusionnée (archiver, épingler, taire, marquer
  /// lu) vaut pour tous ses fils : c'est une seule personne.
  private func expandedIDs(for conversationID: String) -> [String] {
    guard let contact = mergedContact(for: conversationID) else { return [conversationID] }
    return [contact.id] + contact.memberIDs
  }

  /// Fusions possibles pour le fil ouvert : même numéro, réseaux différents.
  func mergeCandidates(for conversation: Conversation) -> [Conversation]? {
    guard !isMerged(conversation.id), !conversation.isGroup else { return nil }
    let groups = MergeCandidates.detect(in: conversations, dismissedPairs: dismissedMergePairs)
    return groups.first { group in group.contains { $0.id == conversation.id } }
  }

  /// Réunit des fils sous un seul contact, et ouvre la ligne qui en résulte.
  func merge(
    _ toMerge: [Conversation],
    title: String,
    avatarConversationID: String?,
    defaultConversationID: String
  ) async {
    let members = toMerge.filter { !$0.isGroup && !MergedContact.isMergedID($0.id) }
    guard members.count >= 2 else { return }
    let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let contact = MergedContact(
      title: cleanTitle.isEmpty ? (members.first?.title ?? "Contact") : cleanTitle,
      memberIDs: members.map(\.id),
      avatarConversationID: avatarConversationID,
      defaultConversationID: members.contains { $0.id == defaultConversationID }
        ? defaultConversationID
        : members[0].id
    )
    for member in members { mergedMemberCache[member.id] = member }
    mergedContacts.append(contact)
    persistMergedContacts()
    // Le visage avant la ligne : sinon elle s'affiche une fois avec ses
    // initiales, et l'avatar choisi n'arrive qu'au rafraîchissement suivant.
    await adoptMergedAvatar(contact)
    normalizeMergedContacts()
    await select(contact.id)
  }

  /// Sépare : les fils repartent chacun de leur côté, et la paire ne se
  /// repropose pas d'elle-même dans la foulée.
  func unmerge(_ mergedID: String) async {
    guard let contact = mergedContact(for: mergedID) else { return }
    mergedContacts.removeAll { $0.id == mergedID }
    dismissedMergePairs.insert(MergeCandidates.pairKey(contact.memberIDs))
    persistMergedContacts()
    // La ligne virtuelle disparaît, ses membres reviennent du cache.
    let restored = contact.memberIDs.compactMap { mergedMemberCache[$0] }
    var list = conversations.filter { $0.id != mergedID }
    let present = Set(list.map(\.id))
    list.append(contentsOf: restored.filter { !present.contains($0.id) })
    for id in contact.memberIDs { mergedMemberCache.removeValue(forKey: id) }
    archivedIDs.remove(mergedID)
    pinnedIDs.remove(mergedID)
    mutedIDs.remove(mergedID)
    persistFlags()
    await ConversationAvatarStore.shared.invalidate(conversationID: mergedID)
    // Ce qui visait la ligne réunie doit suivre un fil réel, sinon le brouillon
    // se perd et l'échéance échoue sur « Conversation introuvable ».
    let heir = contact.activeMemberID(among: Set(restored.map(\.id)))
      ?? contact.memberIDs.first
    if let heir {
      if let draft = drafts.removeValue(forKey: mergedID), drafts[heir] == nil {
        drafts[heir] = draft
      }
      var rescheduled = false
      for (index, scheduled) in scheduledMessages.enumerated()
      where scheduled.conversationID == mergedID {
        scheduledMessages[index] = ScheduledMessage(
          id: scheduled.id,
          conversationID: heir,
          text: scheduled.text,
          attachmentPaths: scheduled.attachmentPaths,
          replyToMessageID: scheduled.replyToMessageID,
          sendAt: scheduled.sendAt,
          onlyIfNoReply: scheduled.onlyIfNoReply,
          createdAt: scheduled.createdAt,
          lastError: scheduled.lastError
        )
        rescheduled = true
      }
      if rescheduled { scheduledDidChange() }
    } else {
      drafts.removeValue(forKey: mergedID)
    }
    persistDraftsNow()
    // La ligne fusionnée n'existe plus : sa session non plus, sinon elle
    // garderait un brouillon rendu à l'un de ses membres.
    sessions.removeValue(forKey: mergedID)
    detachedConversationIDs.remove(mergedID)
    disappearingSecondsByID.removeValue(forKey: mergedID)
    conversations = list
    if selectedConversationID == mergedID {
      await select(restored.first?.id ?? activeQueue.first?.id)
    }
  }

  /// Range sous l'identifiant virtuel l'avatar du membre choisi à la fusion.
  private func adoptMergedAvatar(_ contact: MergedContact) async {
    let members: [Conversation] = contact.memberIDs.compactMap { memberID in
      conversations.first { $0.id == memberID } ?? mergedMemberCache[memberID]
    }
    guard let source = members.first(where: { $0.id == contact.avatarConversationID })
      ?? members.first(where: { $0.id == contact.defaultConversationID })
      ?? members.first
    else { return }
    await ConversationAvatarStore.shared.adopt(mergedID: contact.id, from: source)
  }

  /// Au lancement : les fusions relues du disque reprennent le visage choisi.
  private func adoptMergedAvatars() {
    let contacts = mergedContacts
    guard !contacts.isEmpty else { return }
    Task { @MainActor in
      for contact in contacts { await self.adoptMergedAvatar(contact) }
    }
  }

  /// « ✕ » sur la proposition : cette paire ne se repropose plus.
  func dismissMergeCandidate(_ conversations: [Conversation]) {
    guard conversations.count >= 2 else { return }
    dismissedMergePairs.insert(MergeCandidates.pairKey(conversations.map(\.id)))
    persistMergedContacts()
  }

  /// « Changer de chat » : le réseau choisi devient celui où part le prochain
  /// message, et il le reste (c'est le `lastUsedConversationID`).
  func setActiveMember(mergedID: String, conversationID: String) {
    guard let index = mergedContacts.firstIndex(where: { $0.id == mergedID }),
          mergedContacts[index].memberIDs.contains(conversationID)
    else { return }
    mergedContacts[index].lastUsedConversationID = conversationID
    persistMergedContacts()
  }

  private func persistMergedContacts() {
    let stored = MergedContactStore.Stored(merged: mergedContacts, dismissedPairs: dismissedMergePairs)
    MergedContactStore.save(stored)
    relayNoteMergedContacts(stored)
  }

  private func shouldNotify(_ conversation: Conversation, previous: Conversation?) -> Bool {
    NotificationPolicy.shouldNotify(
      current: conversation,
      previous: previous,
      isMuted: mutedIDs.contains(conversation.id),
      isSelected: isReadOnScreen(conversation.id),
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

  // MARK: - Matrix / réseaux bridgés

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
    stopBridgeLoginPolling()
    await matrix.disconnect()
    isMatrixConnected = false
    conversations.removeAll { $0.network.livesOnRelay }
    if let id = selectedConversationID, !conversations.contains(where: { $0.id == id }) {
      await select(activeQueue.first?.id)
    }
    matrixStatusFR = "Matrix : déconnecté."
  }

  func refreshMatrixStatus() async {
    matrixStatusFR = await matrix.statusMessageFR()
    isMatrixConnected = await matrix.isConnected
  }

  /// Ouvre la feuille de connexion d'un pont et lance la commande `login` auprès de son bot.
  /// Le flux dépend du pont : QR à scanner pour WhatsApp, fenêtre de connexion intégrée
  /// pour Instagram (dont la session part ensuite au bot).
  func presentBridgeLogin(network: MessageNetwork, phoneNumber: String? = nil) {
    guard let bridge = network.bridge else { return }
    bridgeLoginQRData = nil
    bridgeLoginPairingCode = nil
    bridgeLoginNetwork = network
    bridgeLoginCommandSent = false
    pendingWebSessionPayload = nil
    let input: MatrixBridgeService.BridgeLoginInput
    switch bridge.loginFlow {
    case .qrCode:
      // Un numéro ne vaut repli que si le pont sait s'appairer par code : le
      // bot Signal, lui, ne connaît pas `login phone` et répondrait par une erreur.
      if let phoneNumber, bridge.supportsPhonePairing {
        input = .phonePairing(phoneNumber: phoneNumber)
      } else {
        input = .qrCode
      }
      bridgeLoginStatusFR = "Demande du QR au bot \(network.labelFR)…"
    case .webSession:
      input = .webSession
      bridgeLoginStatusFR = "Demande de connexion au bot \(network.labelFR)…"
    }
    bridgeLoginTask?.cancel()
    bridgeLoginTask = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        try await self.matrix.startLogin(network: network, input: input)
      } catch is CancellationError {
        // « Relancer » annule la tentative précédente : c'est elle qui remonte ici,
        // et son annulation n'a rien à dire à l'utilisateur.
        return
      } catch {
        self.bridgeLoginStatusFR = error.localizedDescription
        return
      }
      self.bridgeLoginCommandSent = true
      // La fenêtre a pu livrer la session pendant l'aller-retour : elle part maintenant.
      if let pending = self.pendingWebSessionPayload {
        self.pendingWebSessionPayload = nil
        self.submitBridgeLoginCookies(pending)
        return
      }
      await self.pollBridgeLogin(network: network)
    }
  }

  /// Session livrée par la fenêtre de connexion intégrée : on la met en JSON pour le bot.
  ///
  /// L'utilisateur ne voit ni cookie ni JSON, et rien n'est journalisé — la charge utile
  /// ne fait que passer. Si `login` n'est pas encore parti, on attend : le bot n'accepte
  /// une entrée qu'une fois la commande reçue.
  func handleInstagramSessionCookies(_ cookies: [String: String]) {
    guard let session = InstagramSessionCookies(rawCookies: cookies) else { return }
    let payload = session.jsonPayload
    guard bridgeLoginCommandSent else {
      pendingWebSessionPayload = payload
      bridgeLoginStatusFR = "Session récupérée, envoi au pont…"
      return
    }
    bridgeLoginStatusFR = "Session récupérée, envoi au pont…"
    submitBridgeLoginCookies(payload)
  }

  /// Envoie au bot la session (JSON de la fenêtre, ou collage manuel du repli),
  /// puis reprend la lecture de ses réponses.
  func submitBridgeLoginCookies(_ raw: String) {
    guard let network = bridgeLoginNetwork else { return }
    bridgeLoginStatusFR = "Session récupérée, envoi au pont…"
    bridgeLoginTask?.cancel()
    bridgeLoginTask = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        try await self.matrix.submitLoginCookies(raw, network: network)
      } catch is CancellationError {
        return
      } catch {
        self.bridgeLoginStatusFR = error.localizedDescription
        return
      }
      await self.pollBridgeLogin(network: network)
    }
  }

  /// Lecture des réponses du bot jusqu'au succès, à l'échec, ou au silence.
  /// Le bot répond en quelques secondes ; un QR WhatsApp tourne toutes les ~20 s.
  /// Sans la moindre réponse en 90 s, on arrête : pas de boucle silencieuse.
  private func pollBridgeLogin(network: MessageNetwork) async {
    var silentRounds = 0
    while !Task.isCancelled {
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled else { return }
      do {
        let step = try await matrix.loginStep(network: network)
        if case .waiting = step {
          silentRounds += 1
          if silentRounds >= 30 {
            bridgeLoginStatusFR = MatrixError.bridgeBotSilent(network).localizedDescription
            return
          }
        } else {
          silentRounds = 0
        }
        switch step {
        case .qrCode(let data):
          bridgeLoginQRData = data
          bridgeLoginPairingCode = nil
          bridgeLoginStatusFR = "Scanne ce QR : \(network.labelFR) → Réglages → Appareils liés."
        case .pairingCode(let code):
          bridgeLoginPairingCode = code
          bridgeLoginStatusFR = "Saisis ce code dans \(network.labelFR) → Appareils liés."
        case .awaitingCookies:
          bridgeLoginStatusFR = "Connecte-toi à \(network.labelFR) dans la fenêtre."
        case .success(let detail):
          bridgeLoginStatusFR = "\(network.labelFR) connecté. \(detail)"
          startMatrixSync()
          return
        case .failure(let detail):
          bridgeLoginStatusFR = "Échec : \(detail)"
          return
        case .waiting:
          break
        }
      } catch is CancellationError {
        return
      } catch {
        bridgeLoginStatusFR = error.localizedDescription
        return
      }
    }
  }

  func stopBridgeLoginPolling() {
    bridgeLoginTask?.cancel()
    bridgeLoginTask = nil
  }

  /// Nouveau fil bridgé : commande bot `pm <identifiant>`, le salon arrive par /sync.
  func startBridgeConversation(network: MessageNetwork, identifier: String) async {
    do {
      try await matrix.startConversation(network: network, identifier: identifier)
      matrixStatusFR = "\(network.labelFR) : ouverture du fil vers \(identifier)…"
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

    // Un réseau bridgé n'a pas de brouillon local : c'est le pont qui crée le salon.
    if network.isMatrixBridged {
      await startBridgeConversation(network: network, identifier: trimmed)
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
    // La boîte système veut l'app au premier plan. Au lancement elle y est
    // déjà : ré-activer une app active la fait clignoter et redessiner pour rien.
    if !NSApp.isActive {
      NSApp.activate(ignoringOtherApps: true)
      try? await Task.sleep(for: .milliseconds(250))
    }

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

  /// Boucle `/sync` Matrix : long-poll côté serveur, donc pas de sleep entre deux passes.
  func startMatrixSync() {
    matrixSyncTask?.cancel()
    matrixSyncTask = Task { @MainActor [weak self] in
      guard let self else { return }
      guard await self.matrix.restoreCursorAndCheckSession() else {
        self.isMatrixConnected = false
        self.matrixStatusFR = "Matrix : non connecté."
        self.didSettleInitialMatrixSync = true
        return
      }
      self.isMatrixConnected = true
      // L'état de conversation ne revient pas dans un `/sync` incrémental : on le
      // relit une fois au démarrage, curseur intact. C'est ce qui le fait revenir
      // après un `defaults delete`, et ce qui le donnera à un appareil neuf.
      await self.reloadRelayState()
      var backoffSeconds = 2
      while !Task.isCancelled {
        do {
          var updated = try await self.matrix.syncOnce()
          guard !Task.isCancelled else { return }
          backoffSeconds = 2
          // Le long-poll a rendu quelque chose : on est en train d'intégrer.
          self.isLiveSyncing = true
          defer { self.isLiveSyncing = false }
          await ContactDirectory.shared.enrichBridgedTitles(&updated)
          await self.noteKnownCorrespondents(in: updated)
          self.networkFlaggedRequestIDs = await self.matrix.networkFlaggedRequestIDs()
          self.mergeMatrixConversations(updated)
          self.matrixStatusFR = "Matrix live · \(MatrixBridgeService.bridgedCountFR(updated))"
          await self.refreshLiveMatrixMessages()
          // Le Relais a raison : son état remplace le nôtre pour les fils bridgés,
          // sauf ce qui attend encore de partir. Et ce qui attend part maintenant.
          await self.flushRelayWrites()
          // La migration lit l'état local : elle passe AVANT que celui du Relais
          // ne le remplace. Après le premier `/sync` seulement — avant, aucun
          // salon n'est connu et il n'y aurait rien à migrer.
          await self.migrateStateToRelayIfNeeded()
          await self.adoptRelayState()
          self.didSettleInitialMatrixSync = true
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

  /// Ouvrir un fil. La convention : passer par ici signifie « ce fil est sous
  /// l'attention de l'utilisateur » — un clic dans la liste, une notification
  /// cliquée, ou le fil qui s'affiche dans la foulée d'un geste (archiver,
  /// quitter un groupe, défusionner). Ce n'est PAS le cas de la sélection que
  /// l'app pose d'office au lancement, qui laisse `selectionIsUserMade` à faux.
  func select(_ id: String?) async {
    // Le brouillon appartient au fil, pas au curseur : il reste dans SA session
    // et n'a rien à suivre. On l'écrit tout de même avant de changer de page.
    persistDraftsNow()
    selectedConversationID = id
    selectionIsUserMade = id != nil
    primarySession?.selectedMessageID = nil
    primarySession?.replyingToMessageID = nil
    sendLaterConfig = nil
    sendLaterPicker = nil
    pruneSessions()
    if let id { clearUnread(for: id) }
    await loadMessagesForSelection()
    if let id { indexMessages(messages, conversationID: id) }
    refreshThreadSearchMatches()
    await markConversationRead()
  }

  /// Ouvrir un fil, c'est le lire : on le dit au réseau quand il sait l'entendre.
  /// En tâche détachée — l'ouverture ne doit jamais attendre le réseau.
  private func markConversationRead() async {
    guard let id = selectedConversationID else { return }
    await sendReadReceipt(conversationID: id)
  }

  /// Le même geste pour n'importe quel fil : c'est par là que passe une fenêtre
  /// détachée quand elle arrive au premier plan.
  func sendReadReceipt(conversationID: String) async {
    guard let conversation = conversations.first(where: { $0.id == conversationID }) else { return }
    // Ouvrir une ligne fusionnée, c'est lire les deux fils.
    if isMerged(conversation.id) {
      for member in memberConversations(of: conversation.id) {
        await markRead(member)
      }
      return
    }
    await markRead(conversation)
  }

  /// Le panneau de réponse rapide dit ce qu'il montre : `InboxStore+Detached`
  /// s'en sert pour tenir le fil à jour et l'accuser lu.
  func setQuickReplyConversationID(_ id: String?) {
    quickReplyConversationID = id
  }

  /// `clearUnread` est privé : `InboxStore+Detached` passe par ici.
  func clearUnreadForDetached(_ conversationID: String) {
    clearUnread(for: conversationID)
  }

  private func markRead(_ conversation: Conversation) async {
    switch conversation.network {
    case .iMessage:
      // chat.db est en lecture seule pour nous : c'est Messages qui pose `is_read`.
      // L'automatisation se contente de lui faire sélectionner le fil, cachée.
      markReadViaAutomation(conversation: conversation)
    case .signal, .whatsapp, .instagram, .selfNote:
      guard isMatrixConnected else { return }
      let bridge = matrix
      let id = conversation.id
      Task.detached { await bridge.markRead(conversationID: id) }
    }
  }

  /// Point d'entrée interne : `InboxStore+IMessageAutomation.swift` recharge le
  /// fil après une action AX confirmée.
  func reloadMessagesAfterAutomation() async {
    await loadMessagesForSelection()
  }

  /// `hiddenMessageIDs` est `private(set)` : `InboxStore+Deletion` passe par ici.
  func setHiddenMessageIDs(_ ids: Set<String>, hiddenIn conversationID: String? = nil) {
    let newlyHidden = ids.subtracting(hiddenMessageIDs).first
    hiddenMessageIDs = ids
    HiddenMessageStore.save(ids)
    if let conversationID, let last = newlyHidden { relayNoteHidden(messageID: last, conversationID: conversationID) }
  }

  /// `messagesAutomationHealth` est `private(set)` : l'extension passe par ici.
  func setMessagesAutomationHealth(_ health: IMessageAutomationHealth) {
    messagesAutomationHealth = health
  }

  func setMode(_ newMode: InboxMode) {
    mode = newMode
    // Sortir du Focus (⌘⇧F, Échap) rend son chrome à la fenêtre, tout de suite.
    resetFocusChrome()
  }

  // MARK: - Chrome fantôme du Focus

  /// La souris entre ou sort de la lisière haute : la barre suit, et reste
  /// tant qu'on la survole.
  func setFocusChromeHovered(_ hovering: Bool) {
    isHoveringWindowTop = hovering
    focusChromeHideTask?.cancel()
    if hovering {
      isFocusChromeRevealed = true
    } else {
      scheduleFocusChromeHide(after: 0.4)
    }
  }

  /// On remonte le fil : la barre se montre le temps qu'on la voie, puis
  /// s'efface d'elle-même.
  func flashFocusChrome() {
    isFocusChromeRevealed = true
    scheduleFocusChromeHide(after: 1.8)
  }

  func resetFocusChrome() {
    focusChromeHideTask?.cancel()
    focusChromeHideTask = nil
    isHoveringWindowTop = false
    isFocusChromeRevealed = false
  }

  private func scheduleFocusChromeHide(after delay: Double) {
    focusChromeHideTask?.cancel()
    focusChromeHideTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard let self, !Task.isCancelled, !self.isHoveringWindowTop else { return }
      self.isFocusChromeRevealed = false
    }
  }

  func markUnread(conversationID: String) {
    guard let idx = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
    for id in expandedIDs(for: conversationID) { manuallyUnreadIDs.insert(id) }
    persistFlags()
    var updated = conversations[idx]
    updated.unreadCount = max(1, updated.unreadCount)
    // Sur une ligne fusionnée, le geste vaut pour chaque fil réuni : c'est le
    // membre iMessage, pas la ligne virtuelle, que Messages sait rouvrir.
    let targets = isMerged(conversationID) ? memberConversations(of: conversationID) : [updated]
    // Le compteur d'une ligne fusionnée est *recalculé* depuis ses fils : le
    // poser sur la seule ligne virtuelle, c'est le voir effacé par la passe de
    // fusion dans la foulée. On le pose donc sur le fil qui a parlé en dernier.
    if isMerged(conversationID), let newest = targets.first,
       var cached = mergedMemberCache[newest.id]
    {
      cached.unreadCount = max(1, cached.unreadCount)
      mergedMemberCache[newest.id] = cached
    }
    conversations[idx] = updated
    for target in targets where target.network == .iMessage {
      // iMessage : le « non lu » n'existe que dans Messages — on le lui demande.
      markUnreadViaAutomation(conversation: target)
    }
  }

  func togglePinned(conversationID: String) {
    let ids = expandedIDs(for: conversationID)
    let pinned = !pinnedIDs.contains(conversationID)
    for id in ids {
      if pinned { pinnedIDs.insert(id) } else { pinnedIDs.remove(id) }
    }
    persistFlags()
    relayNote(.pinned, value: pinned, conversationIDs: ids)
    conversations.sort(by: { sortForInbox($0, $1) })
  }

  func toggleMuted(conversationID: String) {
    let ids = expandedIDs(for: conversationID)
    let muted = !mutedIDs.contains(conversationID)
    for id in ids {
      if muted { mutedIDs.insert(id) } else { mutedIDs.remove(id) }
    }
    persistFlags()
    // Le muet vit aussi côté Relais : un salon muet n'émet aucun push (iPhone compris).
    relayNote(.muted, value: muted, conversationIDs: ids)
    updateDockBadge()
  }

  func leaveGroup(conversationID: String) async {
    guard let conversation = conversations.first(where: { $0.id == conversationID }),
          conversation.network.bridge?.relaysGroupLeave == true,
          conversation.isGroup
    else { return }

    do {
      // Quitter le portail, c'est quitter le groupe côté réseau : le pont
      // relaie le départ. Le salon disparaîtra du prochain `/sync`.
      try await matrix.leaveRoom(conversationID: conversationID)
      conversations.removeAll { $0.id == conversationID }
      pinnedIDs.remove(conversationID)
      mutedIDs.remove(conversationID)
      archivedIDs.remove(conversationID)
      remindersByID.removeValue(forKey: conversationID)
      requestDecisions.removeValue(forKey: conversationID)
      disappearingSecondsByID.removeValue(forKey: conversationID)
      persistFlags()
      relayForget(conversationID: conversationID)
      if selectedConversationID == conversationID {
        await select(activeQueue.first?.id)
      }
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
    // Ranger une ligne fusionnée range les deux fils : sinon celui qu'on aurait
    // oublié la ferait remonter au prochain rafraîchissement.
    let ids = expandedIDs(for: conversationID)
    for id in ids {
      if archived { archivedIDs.insert(id) } else { archivedIDs.remove(id) }
      mergedMemberCache[id]?.isArchived = archived
    }
    persistFlags()
    relayNote(.archived, value: archived, conversationIDs: ids)
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
    if showing { isShowingScheduled = false }
  }

  func setShowingScheduled(_ showing: Bool) {
    isShowingScheduled = showing
    if showing { isShowingArchived = false }
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
    guard let session = primarySession else { return }
    pickAttachments(into: session)
  }

  /// Choisir des fichiers pour UNE session — l'inbox ou une fenêtre détachée.
  func pickAttachments(into session: ConversationSession) {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    // Les trois réseaux acceptent n'importe quel fichier (iMessage passe par
    // `send POSIX file`) : ne pas restreindre aux images.
    panel.message = "Choisir un ou plusieurs fichiers"
    guard panel.runModal() == .OK else { return }
    let paths = panel.urls.map(\.path)
    session.pendingAttachmentPaths.append(contentsOf: paths)
  }

  /// Envoyer le brouillon de l'inbox.
  func sendDraft() async {
    guard let session = primarySession else { return }
    await send(session: session)
  }

  /// Envoyer le brouillon d'UNE session — l'inbox ou une fenêtre détachée. Rien
  /// ici ne regarde la sélection : une fenêtre posée à côté d'un document envoie
  /// dans son fil, même si l'inbox en lit un autre.
  func send(session: ConversationSession) async {
    let text = session.draftText.trimmingCharacters(in: .whitespacesAndNewlines)
    let attachments = session.pendingAttachmentPaths
    // Le brouillon appartient à la ligne ouverte ; l'envoi, lui, part sur le
    // réseau du membre actif quand cette ligne est une fusion.
    guard let row = conversationRow(session.conversationID) else { return }
    // Citer, c'est répondre là où la bulle a été dite : sur un fil fusionné, la
    // citation impose son réseau, sinon la réponse partirait sur l'autre chat
    // en désignant un message qu'il ne connaît pas.
    let quoted = session.replyingToMessage
    let routed = quoted.flatMap { self.conversation(ofMessage: $0, in: row) } ?? sendingConversation(for: row)
    guard let conversation = routed else { return }
    guard !text.isEmpty || !attachments.isEmpty else { return }

    if let blocker = sendBlocker(for: conversation, attachments: attachments, interactive: true) {
      lastErrorMessage = blocker
      return
    }

    // « Plus tard » posé sur le composer : le message se range au lieu de partir.
    if let config = sendLaterConfig, session === primarySession {
      scheduleDraft(config, text: text, attachments: attachments, conversation: row)
      return
    }

    if conversation.network == .iMessage, let quotedID = replyingToMessageID {
      // AppleScript ne sait envoyer qu'un message nu. Avec l'automatisation
      // Messages, la citation passe par l'AX ; sans elle, on prévient et on
      // envoie nu — exactement comme avant le Lot M2.
      if canAutomateMessages {
        if await sendQuotedReplyViaAutomation(conversation: conversation, quotedID: quotedID, text: text) {
          session.clearDraft()
          session.replyingToMessageID = nil
          drafts.removeValue(forKey: row.id)
          persistDraftsNow()
          await loadMessages(into: session)
        }
        return
      }
      lastErrorMessage = "Répondre en citant n’existe pas sur iMessage depuis "
        + "l’automatisation AppleScript : le message part sans citation. "
        + "Active « Automatisation Messages » dans Réglages pour citer."
      session.replyingToMessageID = nil
    }

    session.isSending = true
    defer { session.isSending = false }

    let optimistic = Self.optimisticMessage(
      text: text, attachments: attachments, conversation: conversation, quoted: quoted
    )
    session.messages.append(optimistic)
    session.clearDraft()
    session.replyingToMessageID = nil
    drafts.removeValue(forKey: row.id)
    persistDraftsNow()

    do {
      try await deliver(
        text: text, attachments: attachments, conversation: conversation,
        quoted: quoted, localID: optimistic.id
      )
      if let idx = session.messages.firstIndex(where: { $0.id == optimistic.id }) {
        session.messages[idx].isPending = false
      }
      applySidebarPreview(conversationID: conversation.id, from: session.messages)
    } catch {
      session.messages.removeAll { $0.id == optimistic.id }
      session.installDraft(DraftStore.Draft(text: text, attachmentPaths: attachments))
      session.replyingToMessageID = quoted?.id
      lastErrorMessage = error.localizedDescription
    }
  }

  /// Ce qui empêche d'envoyer sur ce fil, ou `nil`. Commun à l'envoi immédiat
  /// et à l'échéance d'un message programmé ; `interactive` autorise à demander
  /// l'automatisation Messages (jamais depuis la boucle d'échéance).
  private func sendBlocker(for conversation: Conversation, attachments: [String], interactive: Bool) -> String? {
    if usingDemoData && conversation.network == .iMessage {
      return "Données démo — accorde l’accès disque pour envoyer via Messages."
    }
    if conversation.network == .iMessage, !iMessageSender.automationAuthorized() {
      guard interactive, requestMessagesAutomation() else {
        if interactive { openAutomationPrivacySettings() }
        return IMessageSendError.automationDenied.localizedDescription
      }
    }
    if conversation.network == .iMessage, !attachments.isEmpty {
      return "Envoi d’images iMessage pas encore branché — Signal seulement pour l’instant."
    }
    if conversation.network.livesOnRelay, !isMatrixConnected {
      return "Matrix n’est pas connecté — vérifie Réglages → Matrix."
    }
    return nil
  }

  private static func optimisticMessage(
    text: String, attachments: [String], conversation: Conversation, quoted: ChatMessage?
  ) -> ChatMessage {
    let outgoingAttachments: [MessageAttachment] = attachments.map { path in
      let url = URL(fileURLWithPath: path)
      return MessageAttachment(
        id: url.lastPathComponent,
        contentType: Self.contentType(forFileAt: url),
        filename: url.lastPathComponent,
        localPath: path
      )
    }
    return ChatMessage(
      id: "local-\(UUID().uuidString)",
      conversationID: conversation.id,
      network: conversation.network,
      text: text.isEmpty && !attachments.isEmpty ? "📷 Photo" : text,
      sentAt: Date(),
      isFromMe: true,
      isPending: true,
      attachments: outgoingAttachments,
      replyTo: quoted.map {
        QuotedMessage(
          messageID: $0.id,
          // Le NOM, jamais l'identifiant technique : un « @signal_…:local »
          // n'est pas quelqu'un. À défaut, le titre du fil dit à qui l'on parle.
          senderName: $0.isFromMe ? "Moi" : ($0.displayedSenderName ?? conversation.title),
          text: $0.sidebarPreviewText
        )
      }
    )
  }

  /// Le transport, et rien d'autre : le fil, le brouillon et l'erreur sont
  /// affaire de l'appelant.
  private func deliver(
    text: String, attachments: [String], conversation: Conversation,
    quoted: ChatMessage?, localID: String
  ) async throws {
    switch conversation.network {
    case .iMessage:
      if !text.isEmpty {
        try await iMessageSender.send(text: text, toAddress: conversation.address)
      }
      // Une pièce jointe part en `send POSIX file` : vers le fil pour un groupe
      // (seule cible que Messages sait viser), vers le correspondant sinon.
      for path in attachments {
        let url = URL(fileURLWithPath: path)
        if conversation.isGroup,
           let guid = IMessageDatabase.guid(fromConversationID: conversation.id)
        {
          try await iMessageSender.send(fileURL: url, toChat: guid)
        } else {
          try await iMessageSender.send(fileURL: url, toAddress: conversation.address)
        }
      }
    case .signal, .whatsapp, .instagram, .selfNote:
      try await matrix.send(
        conversationID: conversation.id,
        text: text,
        attachmentPaths: attachments,
        // Le txnId dérive de l'id optimiste : un renvoi ne duplique pas le message.
        localID: localID,
        replyToMessageID: quoted?.id
      )
    }
  }

  // MARK: - Envoyer plus tard

  /// Messages programmés du fil ouvert, dans l'ordre où ils partiront.
  var scheduledForSelection: [ScheduledMessage] {
    guard let id = selectedConversationID else { return [] }
    return scheduledMessages.filter { $0.conversationID == id }
  }

  /// Fils qui ont au moins un message programmé, le plus proche d'abord —
  /// la vue « Programmés » de la liste.
  var scheduledQueue: [Conversation] {
    var seen: Set<String> = []
    return scheduledMessages.compactMap { message in
      guard seen.insert(message.conversationID).inserted else { return nil }
      return conversations.first { $0.id == message.conversationID }
    }
  }

  func scheduledMessages(for conversationID: String) -> [ScheduledMessage] {
    scheduledMessages.filter { $0.conversationID == conversationID }
  }

  /// ⌘⇧L : ouvre (ou ferme) le sélecteur « Quand ? » pour le brouillon.
  func toggleSendLaterPicker() {
    guard selectedConversation != nil else { return }
    sendLaterPicker = sendLaterPicker == .compose ? nil : .compose
  }

  func presentReschedule(_ id: String) {
    guard scheduledMessages.contains(where: { $0.id == id }) else { return }
    sendLaterPicker = .reschedule(id)
  }

  /// Le sélecteur a choisi une heure : selon sa cible, on la pose sur le
  /// composer ou on déplace un message déjà programmé.
  func applySendLater(_ config: SendLaterConfig) {
    defer { sendLaterPicker = nil }
    switch sendLaterPicker {
    case .compose, nil:
      sendLaterConfig = config
    case .reschedule(let id):
      guard let idx = scheduledMessages.firstIndex(where: { $0.id == id }) else { return }
      scheduledMessages[idx].sendAt = config.sendAt
      scheduledMessages[idx].onlyIfNoReply = config.onlyIfNoReply
      scheduledMessages[idx].lastError = nil
      scheduledDidChange()
    }
  }

  /// La croix de la bannière : le composer redevient un composer.
  func cancelSendLater() {
    sendLaterConfig = nil
    sendLaterPicker = nil
  }

  private func scheduleDraft(
    _ config: SendLaterConfig, text: String, attachments: [String], conversation: Conversation
  ) {
    let message = ScheduledMessage(
      conversationID: conversation.id,
      text: text,
      attachmentPaths: attachments,
      replyToMessageID: replyingToMessageID,
      sendAt: config.sendAt,
      onlyIfNoReply: config.onlyIfNoReply
    )
    scheduledMessages.append(message)
    primarySession?.clearDraft()
    primarySession?.replyingToMessageID = nil
    sendLaterConfig = nil
    drafts.removeValue(forKey: conversation.id)
    persistDraftsNow()
    scheduledDidChange()
  }

  /// « Envoyer maintenant » : l'échéance devient tout de suite.
  func sendScheduledNow(_ id: String) async {
    guard let idx = scheduledMessages.firstIndex(where: { $0.id == id }) else { return }
    scheduledMessages[idx].sendAt = Date()
    scheduledMessages[idx].lastError = nil
    scheduledMessages[idx].onlyIfNoReply = false
    await fire(scheduledMessages[idx])
  }

  /// « Supprimer sans envoyer ».
  func unschedule(_ id: String) {
    scheduledMessages.removeAll { $0.id == id }
    scheduledDidChange()
  }

  private func scheduledDidChange() {
    scheduledMessages.sort { $0.sendAt < $1.sendAt }
    ScheduledMessageStore.save(scheduledMessages)
    if scheduledMessages.isEmpty { isShowingScheduled = false }
    startScheduleDispatcher()
  }

  /// La boucle d'échéance : dort jusqu'au prochain départ (30 s au plus, pour
  /// survivre à une mise en veille sans rater l'heure), envoie ce qui est dû.
  private func startScheduleDispatcher() {
    scheduleDispatchTask?.cancel()
    guard scheduledMessages.contains(where: { $0.lastError == nil }) else { return }
    scheduleDispatchTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        await self.fireDueScheduledMessages()
        guard let next = self.scheduledMessages.first(where: { $0.lastError == nil })?.sendAt else { return }
        let wait = min(max(next.timeIntervalSinceNow, 0.5), 30)
        try? await Task.sleep(for: .seconds(wait))
      }
    }
  }

  private func fireDueScheduledMessages() async {
    let now = Date()
    for message in scheduledMessages where message.isDue(at: now) && message.lastError == nil {
      await fire(message)
    }
  }

  private func fire(_ message: ScheduledMessage) async {
    guard scheduledMessages.contains(where: { $0.id == message.id }) else { return }
    guard let conversation = conversations.first(where: { $0.id == message.conversationID }) else {
      markScheduledFailed(message.id, "Conversation introuvable.")
      return
    }
    // Relance conditionnelle : l'autre a parlé depuis → le message n'a plus lieu d'être.
    if message.onlyIfNoReply, !conversation.lastMessageIsFromMe, conversation.lastMessageAt > message.createdAt {
      scheduledMessages.removeAll { $0.id == message.id }
      scheduledDidChange()
      lastErrorMessage = "Relance pour \(conversation.title) annulée : une réponse est arrivée entre-temps."
      return
    }
    // Une ligne fusionnée n'est pas un transport : l'échéance part sur le
    // réseau du membre actif, comme si on avait appuyé sur Entrée.
    let target = isMerged(conversation.id) ? (activeMember(of: conversation.id) ?? conversation) : conversation
    if let blocker = sendBlocker(for: target, attachments: message.attachmentPaths, interactive: false) {
      markScheduledFailed(message.id, blocker)
      return
    }

    let isOpen = selectedConversationID == conversation.id
    let quoted = isOpen ? message.replyToMessageID.flatMap { id in messages.first { $0.id == id } } : nil
    let optimistic = Self.optimisticMessage(
      text: message.text, attachments: message.attachmentPaths, conversation: target, quoted: quoted
    )
    if isOpen { messages.append(optimistic) }
    // Retiré avant l'envoi : un échec le remet, une réussite ne l'a jamais réenvoyé.
    scheduledMessages.removeAll { $0.id == message.id }

    do {
      try await deliver(
        text: message.text, attachments: message.attachmentPaths, conversation: target,
        quoted: quoted, localID: optimistic.id
      )
      if isOpen {
        if let idx = messages.firstIndex(where: { $0.id == optimistic.id }) {
          messages[idx].isPending = false
        }
        applySidebarPreview(conversationID: conversation.id, from: messages)
      } else {
        var sent = optimistic
        sent.isPending = false
        applySidebarPreview(conversationID: conversation.id, from: [sent])
      }
      scheduledDidChange()
    } catch {
      if isOpen { messages.removeAll { $0.id == optimistic.id } }
      var failed = message
      failed.lastError = error.localizedDescription
      scheduledMessages.append(failed)
      scheduledDidChange()
      lastErrorMessage = "Message programmé pour \(conversation.title) non envoyé : \(error.localizedDescription)"
    }
  }

  private func markScheduledFailed(_ id: String, _ reason: String) {
    guard let idx = scheduledMessages.firstIndex(where: { $0.id == id }) else { return }
    scheduledMessages[idx].lastError = reason
    scheduledDidChange()
  }

  /// Type MIME d'un fichier joint, pour que la bulle optimiste sache déjà
  /// l'afficher comme image, son ou document.
  static func contentType(forFileAt url: URL) -> String {
    if let type = UTType(filenameExtension: url.pathExtension.lowercased()),
       let mime = type.preferredMIMEType
    {
      return mime
    }
    return "application/octet-stream"
  }

  // MARK: - Private

  /// Fusion des fils bridgés — même logique que Signal, sans jamais toucher aux autres réseaux.
  private func mergeMatrixConversations(_ incomingList: [Conversation]) {
    guard !incomingList.isEmpty else { return }
    var byID = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })
    // Photos de portail changées : l'avatar déjà en mémoire ne vaut plus rien.
    var staleAvatarIDs: [String] = []

    for incoming in incomingList {
      // Le fil ouvert est lu : ne pas y réinstaller un badge. Un membre replié
      // se lit sous sa ligne fusionnée — c'est elle que la sélection désigne.
      let isOpen = displayRowID(for: incoming.id) == selectedConversationID
      // Le serveur dit « lu » ; l'utilisateur a dit « non lu ». C'est lui qui gagne,
      // jusqu'à ce qu'il ouvre le fil.
      let heldUnread = manuallyUnreadIDs.contains(incoming.id) && !isOpen
      if var existing = byID[incoming.id] {
        if incoming.hasLivePreview {
          existing.preview = incoming.preview
          existing.lastMessageAt = max(existing.lastMessageAt, incoming.lastMessageAt)
        }
        existing.preferTitle(incoming.title)
        existing.isGroup = incoming.isGroup
        // Les accusés viennent du `/sync` : ils font autorité sur l'état local.
        existing.lastDelivery = incoming.lastDelivery
        existing.lastMessageIsFromMe = incoming.lastMessageIsFromMe
        existing.unreadCount = isOpen ? 0 : max(incoming.unreadCount, heldUnread ? 1 : 0)
        if existing.remoteAvatarID != incoming.remoteAvatarID {
          existing.remoteAvatarID = incoming.remoteAvatarID
          staleAvatarIDs.append(incoming.id)
        }
        // Même règle pour la mosaïque d'un groupe sans photo : un visage de plus
        // ou de moins, et la vignette déjà composée ne vaut plus rien.
        if existing.memberAvatarIDs != incoming.memberAvatarIDs {
          existing.memberAvatarIDs = incoming.memberAvatarIDs
          staleAvatarIDs.append(incoming.id)
        }
        byID[incoming.id] = existing
      } else {
        var fresh = incoming
        if isOpen { fresh.unreadCount = 0 }
        if heldUnread { fresh.unreadCount = max(1, fresh.unreadCount) }
        byID[incoming.id] = fresh
      }
    }

    // Un salon quitté côté réseau distant disparaît de l'inbox.
    let live = Set(incomingList.map(\.id))
    for (id, conversation) in byID
    where conversation.network.livesOnRelay && !live.contains(id)
      && !MergedContact.isMergedID(id)
    {
      byID.removeValue(forKey: id)
    }

    if !staleAvatarIDs.isEmpty {
      let ids = staleAvatarIDs
      Task { for id in ids { await ConversationAvatarStore.shared.invalidate(conversationID: id) } }
    }
    conversations = Array(byID.values).sorted(by: { sortForInbox($0, $1) })
  }

  /// Le `/sync` a rendu quelque chose : chaque fil sous les yeux de quelqu'un
  /// se recoud — celui de l'inbox comme ceux des fenêtres détachées.
  private func refreshLiveMatrixMessages() async {
    for session in liveSessions {
      await refreshMatrixMessages(into: session)
    }
  }

  private func refreshMatrixMessages(into session: ConversationSession) async {
    let id = session.conversationID
    guard let conversation = conversations.first(where: { $0.id == id }) else { return }
    // Un fil réuni n'est pas un salon : c'est son membre bridgé qu'on recharge,
    // et on le recoud au reste. Repasser par le chargement complet du fil
    // recopierait `chat.db` à chaque `/sync` — la boucle live s'en garde.
    if isMerged(id) {
      let bridged = memberConversations(of: id).filter { $0.network.livesOnRelay }
      guard !bridged.isEmpty else { return }
      let bridgedIDs = Set(bridged.map(\.id))
      var refreshed: [ChatMessage] = []
      for member in bridged {
        let fetched = await matrix.messages(conversationID: member.id)
        guard !fetched.isEmpty else { continue }
        refreshed.append(contentsOf: await matrix.ensureLocalAttachments(fetched))
      }
      guard !refreshed.isEmpty else { return }
      let others = session.messages.filter { !bridgedIDs.contains($0.conversationID) }
      session.messages = (others + refreshed).sorted { $0.sentAt < $1.sentAt }
      applySidebarPreview(conversationID: bridged[0].id, from: refreshed)
      if isAttended(id) { clearUnread(for: id) }
      return
    }
    guard conversation.network.livesOnRelay else { return }
    let fetched = await matrix.messages(conversationID: id)
    guard !fetched.isEmpty else { return }
    session.messages = await matrix.ensureLocalAttachments(fetched)
    applySidebarPreview(conversationID: id, from: session.messages)
    if isAttended(id) { clearUnread(for: id) }
  }

  /// Ce fil est-il réellement lu par quelqu'un en ce moment ? L'inbox le lit si
  /// l'utilisateur l'a choisi ; une fenêtre détachée le lit si elle est devant.
  private func isAttended(_ conversationID: String) -> Bool {
    selectedConversationID == conversationID
      || frontDetachedConversationID == conversationID
      || quickReplyConversationID == conversationID
  }

  private func clearUnread(for id: String) {
    // Ouvrir le fil lève le « non lu » posé à la main : c'est le seul geste qui
    // puisse le contredire.
    if !manuallyUnreadIDs.isEmpty {
      let before = manuallyUnreadIDs.count
      for memberID in expandedIDs(for: id) { manuallyUnreadIDs.remove(memberID) }
      if manuallyUnreadIDs.count != before { persistFlags() }
    }
    // Une ligne fusionnée additionne les non-lus de ses fils : les remettre à
    // zéro veut dire les remettre à zéro partout, cache compris.
    for memberID in expandedIDs(for: id) where memberID != id {
      mergedMemberCache[memberID]?.unreadCount = 0
    }
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

    // iMessage est le seul réseau que `load()` va encore chercher : les fils
    // bridgés arrivent par la boucle `/sync`, qui ne s'arrête jamais.
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
      let cached = realConversations(on: .iMessage)
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

    // Cette passe ne rafraîchit qu'iMessage, mais elle réassigne `conversations`
    // en entier : sans ça, les fils bridgés disparaîtraient de la liste jusqu'au
    // `/sync` suivant, et la sélection sauterait sur un fil iMessage entre-temps.
    merged.append(contentsOf: conversations.filter {
      $0.network.livesOnRelay && !MergedContact.isMergedID($0.id)
    })

    preserveComposing(into: &merged)

    let keepSelection = selectedConversationID
    conversations = merged.sorted(by: { sortForInbox($0, $1) })
    if keepSelection == nil
      || !conversations.contains(where: { $0.id == keepSelection })
    {
      selectedConversationID = inboxRecents.first?.id
        ?? inboxGroups.first?.id
        ?? activeQueue.first?.id
      // Sélection volée à l'utilisateur (son fil a disparu le temps de la passe) :
      // le fil de tête qui hérite du curseur n'est pas un fil qu'il a ouvert.
      selectionIsUserMade = false
    } else {
      selectedConversationID = keepSelection
    }
    await loadMessagesForSelection()

    if shouldEnrichIMessage {
      Task { await self.enrichIMessageContactsInBackground() }
      Task { await self.refreshIMessageSearchIndex() }
    }
  }

  /// Noms (+ index photos) Contacts — ne bloque jamais le chargement inbox.
  private func enrichIMessageContactsInBackground() async {
    var list = realConversations(on: .iMessage)
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
      IMessageConversationCache.save(realConversations(on: .iMessage))
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
    // Un message supprimé « ici » ne doit pas revenir résumer sa ligne : le
    // catalogue l'ignore, et c'est le message d'avant qui fait l'aperçu.
    let hidden = hiddenMessageIDs
    let work = Task.detached(priority: .userInitiated) { () -> IMessageLoad in
      do {
        let list = try db.fetchConversations(hiddenMessageGUIDs: hidden)
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

  func loadMessagesForSelection() async {
    guard let session = primarySession else { return }
    await loadMessages(into: session)
  }

  /// Charge le fil d'UNE session. La sélection de l'inbox n'entre pas en jeu :
  /// une fenêtre détachée recharge le sien sans rien déranger.
  func loadMessages(into session: ConversationSession) async {
    guard let conversation = conversationRow(session.conversationID) else {
      session.messages = []
      return
    }

    // Fil fusionné : on va chercher chaque réseau, et le temps remet tout en ordre.
    if isMerged(conversation.id) {
      var merged: [ChatMessage] = []
      for member in memberConversations(of: conversation.id) {
        merged.append(contentsOf: await fetchMessages(for: member))
      }
      // Les repères « Synchronisation… » d'un réseau vide n'ont pas de place
      // dans un fil qui, lui, a des messages ailleurs.
      let real = merged.filter { !Self.isPlaceholderMessageID($0.id) }
      session.messages = (real.isEmpty ? merged : real).sorted { $0.sentAt < $1.sentAt }
      applySidebarPreview(conversationID: conversation.id, from: session.messages)
      return
    }

    session.messages = await fetchMessages(for: conversation)
  }

  /// Un message-repère (« Synchronisation… », « Pas encore de messages ») plutôt
  /// qu'une vraie prise de parole.
  private static func isPlaceholderMessageID(_ id: String) -> Bool {
    id.hasPrefix("signal-empty-") || id.hasPrefix("signal-sync-") || id.hasPrefix("matrix-empty-")
  }

  /// Le fil d'UNE conversation, réseau par réseau. Le fil fusionné les empile.
  private func fetchMessages(for conversation: Conversation) async -> [ChatMessage] {
    switch conversation.network {
    case .iMessage:
      if usingDemoData {
        return Self.demoMessages(for: conversation.id)
      }
      guard let guid = IMessageDatabase.guid(fromConversationID: conversation.id) else {
        return []
      }
      let db = iMessageDB
      do {
        var fetched = try await Task.detached(priority: .userInitiated) {
          try db.fetchMessages(chatGUID: guid)
        }.value
        ContactDirectoryDisk.enrichSenderNames(&fetched)
        return HiddenMessageStore.visible(fetched, hiddenIDs: hiddenMessageIDs)
      } catch {
        lastErrorMessage = error.localizedDescription
        return []
      }
    case .signal, .whatsapp, .instagram, .selfNote:
      var cached = await matrix.messages(conversationID: conversation.id)
      if cached.count < Self.matrixBackfillThreshold {
        // Fil jamais ouvert, ou connu seulement par la fenêtre du sync initial :
        // on va chercher l'historique que le bridge a backfillé.
        cached = await matrix.backfill(conversationID: conversation.id)
      }
      if cached.isEmpty {
        // Au lancement la session n'est pas encore vérifiée, mais des identifiants
        // existent : ce n'est pas « pas connecté », c'est « pas encore synchronisé ».
        var hasSession = isMatrixConnected
        if !hasSession { hasSession = await matrix.isConnected }
        return [
          ChatMessage(
            id: "matrix-empty-\(conversation.id)",
            conversationID: conversation.id,
            network: conversation.network,
            text: hasSession
              ? "Pas encore de messages ici. Écris ci-dessous."
              : "Matrix n’est pas connecté — ouvre Réglages → Matrix.",
            sentAt: Date(),
            isFromMe: false
          )
        ]
      }
      let resolved = HiddenMessageStore.visible(
        await matrix.ensureLocalAttachments(cached),
        hiddenIDs: hiddenMessageIDs
      )
      applySidebarPreview(conversationID: conversation.id, from: resolved)
      return resolved
    }
  }

  /// Sous ce nombre de messages, l'ouverture d'un fil bridgé demande une page
  /// d'historique : le sync initial n'en livre qu'une dizaine par salon.
  private static let matrixBackfillThreshold = 30

  func applySidebarPreview(conversationID: String, from messages: [ChatMessage]) {
    // Un fil replié n'a plus de ligne à lui : c'est la fusionnée qu'on résume.
    let rowID = displayRowID(for: conversationID)
    guard let last = messages.last,
          let idx = conversations.firstIndex(where: { $0.id == rowID })
    else { return }
    if Self.isPlaceholderMessageID(last.id) { return }
    // Sur une fusionnée, le réseau qu'on vient de charger n'est pas forcément
    // celui qui a parlé en dernier : ne jamais faire reculer l'aperçu.
    if rowID != conversationID, last.sentAt < conversations[idx].lastMessageAt { return }
    indexMessages(messages, conversationID: rowID)
    var updated = conversations[idx]
    updated.preview = last.listPreview(isGroup: updated.isGroup)
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

  /// Les brouillons, en lecture — `drafts` est privé au fichier.
  var draftSnapshot: [String: DraftStore.Draft] { drafts }

  /// Les fils membres d'une ligne fusionnée : ils portent un état, sans figurer
  /// dans `conversations`. `mergedMemberCache` est privé au fichier.
  var mergedMemberConversationIDs: [String] { Array(mergedMemberCache.keys) }

  /// L'état revenu du Relais s'installe. `pinnedIDs` & co sont `private(set)` :
  /// l'extension `InboxStore+Relay` passe par ici. On ne touche QUE ce que le
  /// Relais connaît — un fil iMessage, ou un salon pas encore chargé, garde le sien.
  func installRelayState(
    pinned: Set<String>,
    muted: Set<String>,
    archived: Set<String>,
    known: Set<String>,
    drafts newDrafts: [String: String],
    reminders newReminders: [String: ConversationReminder],
    requests newRequests: [String: ConversationRequest.Decision],
    hidden: Set<String>,
    merged: MergedContactStore.Stored?
  ) {
    var changedFlags = false
    for id in known {
      let wasPinned = pinnedIDs.contains(id)
      if pinned.contains(id) { pinnedIDs.insert(id) } else { pinnedIDs.remove(id) }
      let wasMuted = mutedIDs.contains(id)
      if muted.contains(id) { mutedIDs.insert(id) } else { mutedIDs.remove(id) }
      let wasArchived = archivedIDs.contains(id)
      if archived.contains(id) { archivedIDs.insert(id) } else { archivedIDs.remove(id) }
      mergedMemberCache[id]?.isArchived = archived.contains(id)
      let wasAsleep = remindersByID[id]
      remindersByID[id] = newReminders[id]
      requestDecisions[id] = newRequests[id]
      if wasPinned != pinned.contains(id) || wasMuted != muted.contains(id)
        || wasArchived != archived.contains(id) || wasAsleep != newReminders[id] { changedFlags = true }
    }
    if changedFlags {
      persistFlags()
      _ = normalizeArchiveState()
      conversations.sort(by: { sortForInbox($0, $1) })
      updateDockBadge()
    }

    // Un fil ouvert est en train d'être écrit : son brouillon lui appartient.
    let live = Set(liveSessions.map(\.conversationID))
    var draftsChanged = false
    for id in known where !live.contains(id) {
      let text = newDrafts[id] ?? ""
      var draft = drafts[id] ?? DraftStore.Draft()
      guard draft.text != text else { continue }
      draft.text = text
      if draft.isEmpty { drafts.removeValue(forKey: id) } else { drafts[id] = draft }
      draftsChanged = true
    }
    if draftsChanged { DraftStore.save(drafts) }

    if hiddenMessageIDs != hidden {
      hiddenMessageIDs = hidden
      HiddenMessageStore.save(hidden)
    }

    if let merged, merged != MergedContactStore.Stored(merged: mergedContacts, dismissedPairs: dismissedMergePairs) {
      mergedContacts = merged.merged
      dismissedMergePairs = merged.dismissedPairs
      MergedContactStore.save(merged)
      _ = normalizeMergedContacts()
    }
  }

  func persistFlags() {
    UserDefaults.standard.set(Array(pinnedIDs), forKey: Keys.pinnedIDs)
    UserDefaults.standard.set(Array(mutedIDs), forKey: Keys.mutedIDs)
    UserDefaults.standard.set(Array(archivedIDs), forKey: Keys.archivedIDs)
    if let data = try? JSONEncoder().encode(remindersByID) {
      UserDefaults.standard.set(data, forKey: Keys.reminders)
    }
    if let data = try? JSONEncoder().encode(requestDecisions) {
      UserDefaults.standard.set(data, forKey: Keys.requests)
    }
    UserDefaults.standard.set(Array(manuallyUnreadIDs), forKey: Keys.manuallyUnread)
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
    static let reminders = "correspondance.conversationReminders"
    static let requests = "correspondance.conversationRequests"
    static let disappearing = "correspondance.disappearingSeconds"
    static let signalCLIMigration = "correspondance.signalCLIMigrationDone"
    static let manuallyUnread = "correspondance.manuallyUnreadConversationIDs"
    static let messagesAutomation = "correspondance.messagesAutomation.enabled"
    static let messagesAutomationOffscreen = "correspondance.messagesAutomation.offscreenWindow"
    /// Cf. `InboxStore+Relay` : la file d'écritures et le drapeau de migration.
    static let relayQueue = "correspondance.relayWriteQueue"
    static let stateMigrated = "correspondance.stateMigratedToRelay.v1"
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
