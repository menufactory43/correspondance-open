import CorrespondanceMatrixClient
import Foundation

/// La **room console** d'un agent : le seul endroit où l'app et l'agent se
/// parlent de la configuration.
///
/// Pourquoi une room et pas l'account data du bot : l'app est connectée comme
/// le propriétaire, elle ne peut pas écrire dans l'account data de quelqu'un
/// d'autre. Une room, si — le propriétaire y a le pouvoir, le bot y lit.
///
/// Ce qu'on y met : la configuration (event d'état, écrasé), le status que
/// l'agent y poste, et le journal de ses tours. Deux membres, jamais plus.
extension MatrixBridgeService {

  /// Ce que l'app sait d'un agent en regardant sa console.
  public struct AgentConsole: Sendable, Equatable {
    public var roomID: String
    /// La configuration telle qu'elle est écrite sur le Relais — `nil` tant que
    /// l'app ne l'a jamais écrite (l'agent tourne alors sur son `config.json`).
    public var config: AgentConsoleConfig?
    /// Le dernier status posté par l'agent : « cc tourne sur umbrel depuis 14 h 02 ».
    public var status: AgentStatus?
    /// Les derniers tours, du plus récent au plus ancien.
    public var journal: [AgentJournalEntry]

    public init(roomID: String, config: AgentConsoleConfig? = nil, status: AgentStatus? = nil, journal: [AgentJournalEntry] = []) {
      self.roomID = roomID
      self.config = config
      self.status = status
      self.journal = journal
    }
  }

  /// Un tour, tel que l'agent l'a journalisé. Depuis la pleine permission,
  /// c'est ce qui rend un agent relisible depuis le téléphone.
  public struct AgentJournalEntry: Sendable, Equatable, Identifiable {
    public var id: String
    public var conversationRoomID: String
    public var sender: String
    public var prompt: String
    public var tools: [String]
    public var seconds: Double
    public var tokens: Int?
    public var at: Date

    /// « 12 s · Bash, Read » — ce que la carte affiche sous la demande.
    public var summaryFR: String {
      var parts = ["\(Int(seconds.rounded())) s"]
      if !tools.isEmpty { parts.append(tools.prefix(3).joined(separator: ", ")) }
      if let tokens { parts.append("\(tokens / 1000) k jetons") }
      return parts.joined(separator: " · ")
    }
  }

  /// Le nom d'une console — visible dans Element, et c'est tant mieux : une
  /// room qui n'a pas de nom est une room qu'on croit pouvoir supprimer.
  public static func consoleName(agent: String) -> String { "Console de \(agent)" }

  /// La console de cet agent, si elle existe déjà. On la reconnaît à son event
  /// d'état de config — pas à son nom, qu'un humain peut changer.
  public func findAgentConsole(agent: String) async throws -> String? {
    for roomID in try await client.joinedRooms() {
      guard let content = try? await client.roomState(roomID: roomID, type: AgentWire.configType),
            let remote = AgentConsoleConfig(content: content), remote.agent == agent
      else { continue }
      return roomID
    }
    return nil
  }

  /// La console de cet agent, créée si besoin : une room privée, l'agent
  /// invité, et la configuration écrite dedans. C'est le geste de la première
  /// activation — après quoi l'agent la découvre tout seul à son `/sync`.
  @discardableResult
  public func ensureAgentConsole(agent: String, config: AgentConsoleConfig) async throws -> String {
    if let existing = try await findAgentConsole(agent: agent) {
      try await writeAgentConfig(config, in: existing)
      return existing
    }
    let roomID = try await client.createGroupRoom(
      name: Self.consoleName(agent: agent),
      invite: [MatrixIdentity.agentUserID(named: agent, sameServerAs: selfUserID)]
    )
    try await writeAgentConfig(config, in: roomID)
    return roomID
  }

  /// Écrit la configuration. L'agent la relit à son prochain `/sync` : changer
  /// un palier d'outils ne demande ni SSH ni redémarrage.
  public func writeAgentConfig(_ config: AgentConsoleConfig, in roomID: String) async throws {
    try await client.sendStateEvent(
      roomID: roomID, type: AgentWire.configType, content: config.content()
    )
  }

  /// Ce que la console raconte : la config écrite, le dernier status, les
  /// derniers tours.
  public func readAgentConsole(agent: String, journalLimit: Int = 30) async throws -> AgentConsole? {
    guard let roomID = try await findAgentConsole(agent: agent) else { return nil }
    var console = AgentConsole(roomID: roomID)
    if let content = try? await client.roomState(roomID: roomID, type: AgentWire.configType) {
      console.config = AgentConsoleConfig(content: content)
    }
    let agentID = MatrixIdentity.agentUserID(named: agent, sameServerAs: selfUserID)
    let messages = try await client.roomMessages(roomID: roomID, limit: 120)
    for event in messages.chunk where event.sender == agentID {
      if event.type == AgentWire.statusType, console.status == nil,
         let body = event.content?.string(at: "body") {
        console.status = AgentStatus(engines: body, publishedAt: event.sentAt)
      }
      if event.type == AgentWire.journalType, console.journal.count < journalLimit,
         let content = event.content, let id = event.eventID {
        console.journal.append(
          AgentJournalEntry(
            id: id,
            conversationRoomID: content.string(at: AgentWire.JournalKey.room) ?? "",
            sender: content.string(at: AgentWire.JournalKey.sender) ?? "",
            prompt: content.string(at: AgentWire.JournalKey.prompt) ?? "",
            tools: content.value(at: AgentWire.JournalKey.tools)?.arrayValue?.compactMap(\.stringValue) ?? [],
            seconds: content.value(at: AgentWire.JournalKey.seconds)?.doubleValue ?? 0,
            tokens: content.value(at: AgentWire.JournalKey.tokens)?.intValue,
            at: event.sentAt
          )
        )
      }
    }
    return console
  }
}
