import Foundation

/// Sous-ensemble de `GET /_matrix/client/v3/sync` réellement exploité par l'inbox.
public struct MatrixSyncResponse: Decodable, Sendable {
  public var nextBatch: String
  public var rooms: Rooms?
  /// Account data global du compte : `m.push_rules` (d'où vient la sourdine)
  /// et nos propres clés (`fr.correspondance.merged_contacts`).
  public var accountData: AccountData?

  public enum CodingKeys: String, CodingKey {
    case nextBatch = "next_batch"
    case rooms
    case accountData = "account_data"
  }

  public struct AccountData: Decodable, Sendable {
    public var events: [MatrixEvent]?

    public init(events: [MatrixEvent]? = nil) {
      self.events = events
    }
  }

  public struct Rooms: Decodable, Sendable {
    public var join: [String: JoinedRoom]?
    public var leave: [String: MatrixJSON]?
    public var invite: [String: MatrixJSON]?

    public init(join: [String: JoinedRoom]? = nil, leave: [String: MatrixJSON]? = nil, invite: [String: MatrixJSON]? = nil) {
      self.join = join
      self.leave = leave
      self.invite = invite
    }
  }

  public struct JoinedRoom: Decodable, Sendable {
    public var timeline: Timeline?
    public var state: State?
    public var summary: Summary?
    public var unreadNotifications: UnreadNotifications?
    /// EDU du salon : `m.receipt` (accusés de lecture) et `m.typing`.
    public var ephemeral: Ephemeral?
    /// Account data du salon : `m.tag` (épinglé, archivé) et nos clés de salon
    /// (`fr.correspondance.draft`, `fr.correspondance.hidden`).
    public var accountData: MatrixSyncResponse.AccountData?

    public enum CodingKeys: String, CodingKey {
      case timeline, state, summary, ephemeral
      case unreadNotifications = "unread_notifications"
      case accountData = "account_data"
    }

    public init(
      timeline: Timeline? = nil, state: State? = nil, summary: Summary? = nil,
      unreadNotifications: UnreadNotifications? = nil, ephemeral: Ephemeral? = nil,
      accountData: MatrixSyncResponse.AccountData? = nil
    ) {
      self.timeline = timeline
      self.state = state
      self.summary = summary
      self.unreadNotifications = unreadNotifications
      self.ephemeral = ephemeral
      self.accountData = accountData
    }
  }

  public struct Ephemeral: Decodable, Sendable {
    public var events: [MatrixEvent]?

    public init(events: [MatrixEvent]? = nil) { self.events = events }
  }

  public struct Timeline: Decodable, Sendable {
    public var events: [MatrixEvent]?
    public var limited: Bool?
    public var prevBatch: String?

    public enum CodingKeys: String, CodingKey {
      case events, limited
      case prevBatch = "prev_batch"
    }

    public init(events: [MatrixEvent]? = nil, limited: Bool? = nil, prevBatch: String? = nil) {
      self.events = events
      self.limited = limited
      self.prevBatch = prevBatch
    }
  }

  public struct State: Decodable, Sendable {
    public var events: [MatrixEvent]?

    public init(events: [MatrixEvent]? = nil) { self.events = events }
  }

  public struct Summary: Decodable, Sendable {
    public var heroes: [String]?
    public var joinedMemberCount: Int?

    public enum CodingKeys: String, CodingKey {
      case heroes = "m.heroes"
      case joinedMemberCount = "m.joined_member_count"
    }

    public init(heroes: [String]? = nil, joinedMemberCount: Int? = nil) {
      self.heroes = heroes
      self.joinedMemberCount = joinedMemberCount
    }
  }

  public struct UnreadNotifications: Decodable, Sendable {
    public var notificationCount: Int?

    public enum CodingKeys: String, CodingKey {
      case notificationCount = "notification_count"
    }

    public init(notificationCount: Int? = nil) { self.notificationCount = notificationCount }
  }

  public init(nextBatch: String, rooms: Rooms? = nil, accountData: AccountData? = nil) {
    self.nextBatch = nextBatch
    self.rooms = rooms
    self.accountData = accountData
  }
}

public struct MatrixEvent: Decodable, Sendable {
  public var type: String
  public var eventID: String?
  public var sender: String?
  public var stateKey: String?
  public var originServerTS: Double?
  public var content: MatrixJSON?
  /// `m.room.redaction` : l'event supprimé. Au niveau racine avant la room version 11,
  /// dans `content` depuis — on lit les deux.
  public var redacts: String?

  public enum CodingKeys: String, CodingKey {
    case type, sender, content, redacts
    case eventID = "event_id"
    case stateKey = "state_key"
    case originServerTS = "origin_server_ts"
  }

  public var redactedEventID: String? {
    redacts ?? content?.string(at: "redacts")
  }

  public var sentAt: Date {
    Date(timeIntervalSince1970: (originServerTS ?? 0) / 1000)
  }

  public init(type: String, eventID: String? = nil, sender: String? = nil, stateKey: String? = nil, originServerTS: Double? = nil, content: MatrixJSON? = nil, redacts: String? = nil) {
    self.type = type
    self.eventID = eventID
    self.sender = sender
    self.stateKey = stateKey
    self.originServerTS = originServerTS
    self.content = content
    self.redacts = redacts
  }
}

/// `GET /rooms/{id}/messages`.
public struct MatrixMessagesResponse: Decodable, Sendable {
  public var chunk: [MatrixEvent]
  public var start: String?
  public var end: String?

  public init(chunk: [MatrixEvent], start: String? = nil, end: String? = nil) {
    self.chunk = chunk
    self.start = start
    self.end = end
  }
}
