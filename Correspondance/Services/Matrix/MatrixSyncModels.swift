import Foundation

/// Sous-ensemble de `GET /_matrix/client/v3/sync` réellement exploité par l'inbox.
struct MatrixSyncResponse: Decodable, Sendable {
  var nextBatch: String
  var rooms: Rooms?

  enum CodingKeys: String, CodingKey {
    case nextBatch = "next_batch"
    case rooms
  }

  struct Rooms: Decodable, Sendable {
    var join: [String: JoinedRoom]?
    var leave: [String: MatrixJSON]?
    var invite: [String: MatrixJSON]?
  }

  struct JoinedRoom: Decodable, Sendable {
    var timeline: Timeline?
    var state: State?
    var summary: Summary?
    var unreadNotifications: UnreadNotifications?

    enum CodingKeys: String, CodingKey {
      case timeline, state, summary
      case unreadNotifications = "unread_notifications"
    }
  }

  struct Timeline: Decodable, Sendable {
    var events: [MatrixEvent]?
    var limited: Bool?
    var prevBatch: String?

    enum CodingKeys: String, CodingKey {
      case events, limited
      case prevBatch = "prev_batch"
    }
  }

  struct State: Decodable, Sendable {
    var events: [MatrixEvent]?
  }

  struct Summary: Decodable, Sendable {
    var heroes: [String]?
    var joinedMemberCount: Int?

    enum CodingKeys: String, CodingKey {
      case heroes = "m.heroes"
      case joinedMemberCount = "m.joined_member_count"
    }
  }

  struct UnreadNotifications: Decodable, Sendable {
    var notificationCount: Int?

    enum CodingKeys: String, CodingKey {
      case notificationCount = "notification_count"
    }
  }
}

struct MatrixEvent: Decodable, Sendable {
  var type: String
  var eventID: String?
  var sender: String?
  var stateKey: String?
  var originServerTS: Double?
  var content: MatrixJSON?
  /// `m.room.redaction` : l'event supprimé. Au niveau racine avant la room version 11,
  /// dans `content` depuis — on lit les deux.
  var redacts: String?

  enum CodingKeys: String, CodingKey {
    case type, sender, content, redacts
    case eventID = "event_id"
    case stateKey = "state_key"
    case originServerTS = "origin_server_ts"
  }

  var redactedEventID: String? {
    redacts ?? content?.string(at: "redacts")
  }

  var sentAt: Date {
    Date(timeIntervalSince1970: (originServerTS ?? 0) / 1000)
  }
}

/// `GET /rooms/{id}/messages`.
struct MatrixMessagesResponse: Decodable, Sendable {
  var chunk: [MatrixEvent]
  var start: String?
  var end: String?
}
