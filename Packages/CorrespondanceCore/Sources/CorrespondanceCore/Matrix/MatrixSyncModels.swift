import Foundation

/// Sous-ensemble de `GET /_matrix/client/v3/sync` réellement exploité par l'inbox.
public struct MatrixSyncResponse: Decodable, Sendable {
  public var nextBatch: String
  public var rooms: Rooms?

  public enum CodingKeys: String, CodingKey {
    case nextBatch = "next_batch"
    case rooms
  }

  public struct Rooms: Decodable, Sendable {
    public var join: [String: JoinedRoom]?
    public var leave: [String: MatrixJSON]?
    public var invite: [String: MatrixJSON]?
  }

  public struct JoinedRoom: Decodable, Sendable {
    public var timeline: Timeline?
    public var state: State?
    public var summary: Summary?
    public var unreadNotifications: UnreadNotifications?
    /// EDU du salon : `m.receipt` (accusés de lecture) et `m.typing`.
    public var ephemeral: Ephemeral?

    public enum CodingKeys: String, CodingKey {
      case timeline, state, summary, ephemeral
      case unreadNotifications = "unread_notifications"
    }
  }

  public struct Ephemeral: Decodable, Sendable {
    public var events: [MatrixEvent]?
  }

  public struct Timeline: Decodable, Sendable {
    public var events: [MatrixEvent]?
    public var limited: Bool?
    public var prevBatch: String?

    public enum CodingKeys: String, CodingKey {
      case events, limited
      case prevBatch = "prev_batch"
    }
  }

  public struct State: Decodable, Sendable {
    public var events: [MatrixEvent]?
  }

  public struct Summary: Decodable, Sendable {
    public var heroes: [String]?
    public var joinedMemberCount: Int?

    public enum CodingKeys: String, CodingKey {
      case heroes = "m.heroes"
      case joinedMemberCount = "m.joined_member_count"
    }
  }

  public struct UnreadNotifications: Decodable, Sendable {
    public var notificationCount: Int?

    public enum CodingKeys: String, CodingKey {
      case notificationCount = "notification_count"
    }
  }

  public init(nextBatch: String, rooms: Rooms? = nil) {
    self.nextBatch = nextBatch
    self.rooms = rooms
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
