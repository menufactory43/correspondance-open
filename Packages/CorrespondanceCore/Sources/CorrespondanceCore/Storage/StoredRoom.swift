import Foundation

/// Une ligne de la table `rooms` : ce que l'inbox montre, plus l'état du salon
/// dont le parseur a besoin pour continuer là où il s'était arrêté.
///
/// L'ancien instantané JSON ne gardait que la conversation dérivée : au
/// relancement, un salon ne savait plus qui étaient ses membres, ni quel pont
/// l'avait créé — d'où le sync initial complet à chaque lancement. Ici l'état
/// est gardé tel quel, et le curseur peut reprendre.
public struct StoredRoom: Sendable, Equatable {
  public var roomID: String
  public var conversationID: String
  public var network: MessageNetwork?
  public var title: String
  public var preview: String
  public var lastMessageAt: Date
  public var unreadCount: Int
  public var transportKey: String
  public var isGroup: Bool
  public var avatarMXC: String?
  public var memberAvatarIDs: [String]
  public var state: State

  /// L'état du salon que `/sync` a construit et que le prochain lancement doit
  /// retrouver : sans lui, un curseur repris laisserait des salons anonymes.
  public struct State: Codable, Sendable, Equatable {
    public var explicitName: String?
    public var bridgeChannelName: String?
    public var bridgePhoneNumber: String?
    public var bridgeRoomType: String?
    public var bridgeChannelID: String?
    public var isNetworkFlaggedRequest: Bool = false
    public var members: [String: MatrixRoomModel.Member] = [:]
    public var heroes: [String] = []
    public var readMarkerByUser: [String: String] = [:]
    public var unresolvedQuoteMessageIDs: [String] = []
    public var pendingEdits: [String: MatrixRoomModel.PendingEdit] = [:]
    public var polls: [String: MatrixRoomModel.PollEvent] = [:]
    public var lastEventAt: Date = .distantPast

    public init() {}
  }

  public init(
    roomID: String,
    conversationID: String,
    network: MessageNetwork?,
    title: String,
    preview: String,
    lastMessageAt: Date,
    unreadCount: Int,
    transportKey: String,
    isGroup: Bool,
    avatarMXC: String?,
    memberAvatarIDs: [String],
    state: State
  ) {
    self.roomID = roomID
    self.conversationID = conversationID
    self.network = network
    self.title = title
    self.preview = preview
    self.lastMessageAt = lastMessageAt
    self.unreadCount = unreadCount
    self.transportKey = transportKey
    self.isGroup = isGroup
    self.avatarMXC = avatarMXC
    self.memberAvatarIDs = memberAvatarIDs
    self.state = state
  }
}

public extension StoredRoom {
  /// Ce qu'on écrit d'un salon : les colonnes que l'inbox lit, dérivées une
  /// fois ici plutôt qu'à chaque affichage, et l'état brut à côté.
  init(model: MatrixRoomModel, selfUserID: String) {
    var state = State()
    state.explicitName = model.explicitName
    state.bridgeChannelName = model.bridgeChannelName
    state.bridgePhoneNumber = model.bridgePhoneNumber
    state.bridgeRoomType = model.bridgeRoomType
    state.bridgeChannelID = model.bridgeChannelID
    state.isNetworkFlaggedRequest = model.isNetworkFlaggedRequest
    state.members = model.members
    state.heroes = model.heroes
    state.readMarkerByUser = model.readMarkerByUser
    state.unresolvedQuoteMessageIDs = model.unresolvedQuoteMessageIDs.sorted()
    state.pendingEdits = model.pendingEdits
    state.polls = model.pollsByEventID
    state.lastEventAt = model.lastEventAt

    // Un salon sans pont reconnu (gestion, note à soi) n'a pas de conversation :
    // on garde quand même de quoi le réafficher, réseau nul assumé.
    let derived = model.conversation(selfUserID: selfUserID)
    self.init(
      roomID: model.roomID,
      conversationID: model.conversationID,
      network: model.network,
      title: derived?.title ?? model.title(selfUserID: selfUserID),
      preview: derived?.preview ?? (model.sortedMessages.last?.sidebarPreviewText ?? ""),
      lastMessageAt: derived?.lastMessageAt ?? model.lastEventAt,
      unreadCount: model.unreadCount,
      transportKey: model.roomID,
      isGroup: derived?.isGroup ?? model.isGroup(selfUserID: selfUserID),
      avatarMXC: model.avatarMXC,
      memberAvatarIDs: derived?.memberAvatarIDs ?? [],
      state: state
    )
  }

  /// Le salon tel que le parseur le reprendra — **sans ses messages** : ils se
  /// chargent par pages, à l'ouverture du fil.
  func model() -> MatrixRoomModel {
    var model = MatrixRoomModel(roomID: roomID)
    model.network = network
    model.explicitName = state.explicitName
    model.bridgeChannelName = state.bridgeChannelName
    model.bridgePhoneNumber = state.bridgePhoneNumber
    model.bridgeRoomType = state.bridgeRoomType
    model.bridgeChannelID = state.bridgeChannelID
    model.avatarMXC = avatarMXC
    model.isNetworkFlaggedRequest = state.isNetworkFlaggedRequest
    model.members = state.members
    model.heroes = state.heroes
    model.unreadCount = unreadCount
    model.readMarkerByUser = state.readMarkerByUser
    model.unresolvedQuoteMessageIDs = Set(state.unresolvedQuoteMessageIDs)
    model.pendingEdits = state.pendingEdits
    model.pollsByEventID = state.polls
    model.lastEventAt = state.lastEventAt
    return model
  }
}
