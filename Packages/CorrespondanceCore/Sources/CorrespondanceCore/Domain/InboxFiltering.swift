import Foundation

/// Ce que le menu du titre choisit : la file, ou ce qui en est sorti.
///
/// Ce n'est pas un filtre de plus : l'archive est l'AUTRE liste, celle des
/// conversations traitées. Un filtre (`ConversationFilter`) s'applique ensuite
/// dans l'une comme dans l'autre.
public enum InboxScope: String, CaseIterable, Identifiable, Sendable {
  case inbox
  case archive
  /// Les conversations mises de côté, avec l'heure à laquelle elles reviennent.
  /// Une liste pour vérifier ce qu'on a rangé, pas un mode de travail.
  case reminders

  public var id: String { rawValue }

  public var labelFR: String {
    switch self {
    case .inbox: "Inbox"
    case .archive: "Archive"
    case .reminders: "Rappels"
    }
  }

  public var systemImage: String {
    switch self {
    case .inbox: "tray.full"
    case .archive: "archivebox"
    case .reminders: "clock.arrow.circlepath"
    }
  }
}

/// Le filtre de la barre du bas — « ce que je veux voir maintenant ».
///
/// Décision 10 de la révision iOS : non lus, brouillons, sans réponse, groupes.
/// Chacun se dit en une fonction pure sur une conversation et l'état connu ;
/// aucun n'a besoin du réseau, ce qui les rend testables ici.
public enum ConversationFilter: String, CaseIterable, Identifiable, Sendable {
  case all
  case unread
  case drafts
  case unanswered
  case groups

  public var id: String { rawValue }

  public var labelFR: String {
    switch self {
    case .all: "Tous"
    case .unread: "Non lus"
    case .drafts: "Brouillons"
    case .unanswered: "Sans réponse"
    case .groups: "Groupes"
    }
  }

  public var systemImage: String {
    switch self {
    case .all: "line.3.horizontal.decrease"
    case .unread: "circle.fill"
    case .drafts: "pencil.line"
    case .unanswered: "arrowshape.turn.up.left"
    case .groups: "person.3"
    }
  }

  /// Ce filtre laisse-t-il passer cette conversation ?
  ///
  /// - Parameter hasDraft: un brouillon attend dans ce fil (Relais ou local).
  public func accepts(_ conversation: Conversation, hasDraft: Bool) -> Bool {
    switch self {
    case .all:
      true
    case .unread:
      conversation.hasUnread
    case .drafts:
      hasDraft
    // « Sans réponse » : le dernier mot est le leur. Un fil de catalogue, qui
    // n'a encore aucun message, n'attend rien de personne.
    case .unanswered:
      conversation.hasLivePreview && !conversation.lastMessageIsFromMe
    case .groups:
      conversation.isGroup
    }
  }
}

/// L'état de conversation, projeté en identifiants de conversation.
///
/// `ConversationStateSnapshot` parle en salons (`!abc:serveur`) ; les listes,
/// elles, parlent en conversations (`whatsapp:!abc:serveur`). Ce type est la
/// traduction, et rien d'autre : les vues et les tris ne connaissent que lui.
public struct InboxState: Sendable, Equatable {
  public var pinned: Set<String>
  public var muted: Set<String>
  public var archived: Set<String>
  public var drafts: [String: String]
  /// Les rappels posés, par conversation. Une conversation en rappel dort :
  /// elle quitte la file jusqu'à l'heure dite (`InboxOrdering` s'en sert).
  public var reminders: [String: ConversationReminder]

  public init(
    pinned: Set<String> = [],
    muted: Set<String> = [],
    archived: Set<String> = [],
    drafts: [String: String] = [:],
    reminders: [String: ConversationReminder] = [:]
  ) {
    self.pinned = pinned
    self.muted = muted
    self.archived = archived
    self.drafts = drafts
    self.reminders = reminders
  }

  public func isPinned(_ id: String) -> Bool { pinned.contains(id) }
  public func isMuted(_ id: String) -> Bool { muted.contains(id) }
  public func isArchived(_ id: String) -> Bool { archived.contains(id) }

  public func reminder(_ id: String) -> ConversationReminder? { reminders[id] }

  /// Cette conversation est-elle encore de côté ? Non si l'heure est venue, non
  /// si l'autre a répondu depuis — c'est `ConversationReminder` qui tranche.
  public func isAsleep(_ conversation: Conversation, now: Date = Date()) -> Bool {
    guard let reminder = reminders[conversation.id] else { return false }
    return reminder.isAsleep(
      now: now,
      lastMessageAt: conversation.lastMessageAt,
      lastMessageIsFromMe: conversation.lastMessageIsFromMe
    )
  }

  public func hasDraft(_ id: String) -> Bool {
    !(drafts[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// Traduit un instantané du Relais en identifiants de conversation, pour les
  /// salons qu'on sait nommer. Un salon inconnu de cette session ne change rien :
  /// on ne peut ni le montrer, ni le perdre — même discipline que le Mac.
  public static func projected(
    _ snapshot: ConversationStateSnapshot,
    roomToConversation: [String: String]
  ) -> InboxState {
    var state = InboxState()
    for roomID in snapshot.pinned { if let id = roomToConversation[roomID] { state.pinned.insert(id) } }
    for roomID in snapshot.muted { if let id = roomToConversation[roomID] { state.muted.insert(id) } }
    for roomID in snapshot.archived { if let id = roomToConversation[roomID] { state.archived.insert(id) } }
    for (roomID, text) in snapshot.drafts {
      if let id = roomToConversation[roomID] { state.drafts[id] = text }
    }
    for (roomID, reminder) in snapshot.reminders {
      if let id = roomToConversation[roomID] { state.reminders[id] = reminder }
    }
    return state
  }
}

/// Le tri et le découpage de la file — fonctions pures, sans SwiftUI ni store.
///
/// Même règle que sur le Mac (`InboxStore.sortForInbox`) : les épinglées
/// d'abord, puis ce qui a un vrai message, puis les groupes du catalogue, puis
/// le reste par ordre alphabétique. Une seule différence à l'écran : l'iPhone
/// montre les épinglées en SECTION, pas seulement en tête de liste.
public enum InboxOrdering {
  public static func sorted(_ conversations: [Conversation], pinned: Set<String>) -> [Conversation] {
    conversations.sorted { lhs, rhs in
      let lp = pinned.contains(lhs.id), rp = pinned.contains(rhs.id)
      if lp != rp { return lp }
      return byRecency(lhs, rhs)
    }
  }

  /// Le tri sans les épingles — celui de la file Focus, où l'épinglé n'a pas
  /// à passer devant : on traite dans l'ordre où c'est arrivé.
  public static func byRecency(_ a: Conversation, _ b: Conversation) -> Bool {
    let rank: (Conversation) -> Int = { c in
      if c.hasLivePreview { return 0 }
      if c.isGroup { return 1 }
      return 2
    }
    let ra = rank(a), rb = rank(b)
    if ra != rb { return ra < rb }
    if a.hasLivePreview || b.hasLivePreview {
      if a.lastMessageAt != b.lastMessageAt { return a.lastMessageAt > b.lastMessageAt }
      return a.id < b.id
    }
    let byTitle = a.title.localizedCaseInsensitiveCompare(b.title)
    if byTitle != .orderedSame { return byTitle == .orderedAscending }
    return a.id < b.id
  }

  /// La liste telle que l'écran la montre : portée, réseau, filtre, tri.
  public static func list(
    _ conversations: [Conversation],
    scope: InboxScope,
    network: MessageNetwork?,
    filter: ConversationFilter,
    state: InboxState,
    now: Date = Date()
  ) -> [Conversation] {
    let kept = conversations.filter { conversation in
      let asleep = state.isAsleep(conversation, now: now)
      // Une conversation de côté ne se montre que dans « Rappels » — c'est tout
      // l'intérêt de l'avoir rangée. Elle revient dans la file d'elle-même,
      // à l'heure dite ou dès qu'on lui répond.
      guard asleep == (scope == .reminders) else { return false }
      if scope != .reminders {
        let archived = state.isArchived(conversation.id)
        guard archived == (scope == .archive) else { return false }
      }
      if let network, conversation.network != network { return false }
      return filter.accepts(conversation, hasDraft: state.hasDraft(conversation.id))
    }
    guard scope != .reminders else { return kept.sorted(by: byWakeTime(state)) }
    return sorted(kept, pinned: state.pinned)
  }

  /// Les rappels se lisent dans l'ordre où ils vont sonner.
  private static func byWakeTime(_ state: InboxState) -> (Conversation, Conversation) -> Bool {
    { lhs, rhs in
      let l = state.reminders[lhs.id]?.wakeAt ?? .distantFuture
      let r = state.reminders[rhs.id]?.wakeAt ?? .distantFuture
      if l != r { return l < r }
      return lhs.id < rhs.id
    }
  }

  /// La liste coupée en deux sections : épinglées en tête, le reste ensuite.
  public static func sections(
    _ list: [Conversation],
    state: InboxState
  ) -> (pinned: [Conversation], others: [Conversation]) {
    (
      pinned: list.filter { state.isPinned($0.id) },
      others: list.filter { !state.isPinned($0.id) }
    )
  }

  /// La file Focus : ce qui reste à traiter, dans l'ordre où c'est arrivé.
  ///
  /// Ni archive ni filtre — Focus montre LA file, pas une vue de la file. Les
  /// conversations de catalogue (aucun message reçu) n'y entrent pas : il n'y a
  /// rien à y traiter.
  public static func focusQueue(
    _ conversations: [Conversation],
    state: InboxState,
    network: MessageNetwork? = nil,
    now: Date = Date()
  ) -> [Conversation] {
    conversations
      .filter { !state.isArchived($0.id) && $0.hasLivePreview && !state.isAsleep($0, now: now) }
      .filter { network == nil || $0.network == network }
      .sorted(by: byRecency)
  }

  /// Ce qu'on montre après avoir archivé la conversation courante : la suivante
  /// dans la file d'AVANT le geste, ou celle qui l'y remplace en fin de file.
  /// Renvoie `nil` quand il ne reste rien — « Vous êtes à jour ».
  public static func next(after id: String, in queue: [Conversation]) -> String? {
    guard let index = queue.firstIndex(where: { $0.id == id }) else { return queue.first?.id }
    let remaining = queue.enumerated().filter { $0.offset != index }.map(\.element)
    guard !remaining.isEmpty else { return nil }
    return remaining[min(index, remaining.count - 1)].id
  }

  /// La précédente, pour le bouton du même nom. `nil` en tête de file.
  public static func previous(before id: String, in queue: [Conversation]) -> String? {
    guard let index = queue.firstIndex(where: { $0.id == id }), index > 0 else { return nil }
    return queue[index - 1].id
  }

  /// La suivante sans rien archiver — le bouton « suivante ». `nil` en fin de file.
  public static func following(_ id: String, in queue: [Conversation]) -> String? {
    guard let index = queue.firstIndex(where: { $0.id == id }), index + 1 < queue.count else { return nil }
    return queue[index + 1].id
  }
}
