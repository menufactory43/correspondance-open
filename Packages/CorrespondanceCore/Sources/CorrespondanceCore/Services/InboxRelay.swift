import CorrespondanceMatrixClient
import Foundation

/// Ce dont les outils MCP ont besoin du Relais, et rien de plus.
///
/// C'est une couture, pas une abstraction gratuite : sans elle, chaque outil ne
/// serait éprouvable qu'avec un vrai Synapse. Avec elle, un faux Relais suffit
/// à prouver que `archive` archive et que `list_queue` range dans le bon ordre.
public protocol InboxRelay: Sendable {
  func joinedRooms() async throws -> [String]
  /// Le nom affiché d'une conversation, s'il y en a un.
  func roomName(_ roomID: String) async throws -> String?
  /// Les derniers messages, du plus récent au plus ancien.
  func recentMessages(_ roomID: String, limit: Int) async throws -> [InboxRelayMessage]
  /// Les tags du salon : `m.favourite` (épinglé), `fr.correspondance.archived`.
  func tags(_ roomID: String) async throws -> Set<String>
  func setTag(_ roomID: String, tag: String, on: Bool) async throws
  func setRoomAccountData(_ roomID: String, type: String, content: MatrixJSON) async throws
  func setMuted(_ roomID: String, muted: Bool) async throws
  /// Envoi réel — sous les gardes de `MCPInbox`, jamais autrement.
  func sendText(_ roomID: String, text: String) async throws
  /// Une proposition : l'app la rend en brouillon, rien ne part vers personne.
  func sendProposal(_ roomID: String, text: String, agent: String, inReplyTo: String?) async throws
}

/// Un message, réduit à ce qu'un outil de lecture a le droit de rendre.
public struct InboxRelayMessage: Sendable, Equatable {
  public var eventID: String
  public var sender: String
  public var body: String
  public var sentAt: Date
  public var isMine: Bool

  public init(eventID: String, sender: String, body: String, sentAt: Date, isMine: Bool) {
    self.eventID = eventID
    self.sender = sender
    self.body = body
    self.sentAt = sentAt
    self.isMine = isMine
  }
}

/// Le Relais réel, par le client Matrix. La session vient du Trousseau ou de
/// l'amorce de l'agent : **aucun nouveau secret**.
public struct MatrixInboxRelay: InboxRelay {
  let client: MatrixClient
  let selfUserID: String

  public init(client: MatrixClient, selfUserID: String) {
    self.client = client
    self.selfUserID = selfUserID
  }

  public func joinedRooms() async throws -> [String] {
    try await client.joinedRooms()
  }

  public func roomName(_ roomID: String) async throws -> String? {
    (try? await client.roomState(roomID: roomID, type: "m.room.name"))?.string(at: "name")
  }

  public func recentMessages(_ roomID: String, limit: Int) async throws -> [InboxRelayMessage] {
    let response = try await client.roomMessages(roomID: roomID, direction: "b", limit: limit)
    return response.chunk.compactMap { event in
      guard event.type == "m.room.message",
            let eventID = event.eventID,
            let sender = event.sender,
            let body = event.content?.string(at: "body")
      else { return nil }
      return InboxRelayMessage(
        eventID: eventID, sender: sender, body: body,
        sentAt: event.sentAt, isMine: sender == selfUserID
      )
    }
  }

  public func tags(_ roomID: String) async throws -> Set<String> {
    let content = try await client.roomAccountData(roomID: roomID, type: ConversationStateKeys.tagType)
    return Set((content.value(at: "tags")?.objectValue ?? [:]).keys)
  }

  public func setTag(_ roomID: String, tag: String, on: Bool) async throws {
    if on {
      try await client.setRoomTag(roomID: roomID, tag: tag)
    } else {
      try await client.removeRoomTag(roomID: roomID, tag: tag)
    }
  }

  public func setRoomAccountData(_ roomID: String, type: String, content: MatrixJSON) async throws {
    try await client.setRoomAccountData(roomID: roomID, type: type, content: content)
  }

  public func setMuted(_ roomID: String, muted: Bool) async throws {
    try await client.setRoomPushRule(roomID: roomID, muted: muted)
  }

  public func sendText(_ roomID: String, text: String) async throws {
    try await client.sendText(roomID: roomID, body: text)
  }

  public func sendProposal(_ roomID: String, text: String, agent: String, inReplyTo: String?) async throws {
    var content: [String: MatrixJSON] = [
      "body": .string(text),
      "agent": .string(agent),
    ]
    if let inReplyTo {
      content["m.relates_to"] = .object(["m.in_reply_to": .object(["event_id": .string(inReplyTo)])])
    }
    try await client.sendEvent(roomID: roomID, type: AgentWire.proposalType, content: .object(content))
  }
}
