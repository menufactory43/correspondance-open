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
  public struct AgentConsole: Sendable, Equatable, Identifiable {
    /// Le nom de l'agent — `cc`, `hermes`. C'est l'identité : un agent est un
    /// compte Matrix et une console, et l'annuaire se lit par ce nom.
    public var agent: String
    public var roomID: String
    /// La configuration telle qu'elle est écrite sur le Relais — `nil` tant que
    /// l'app ne l'a jamais écrite (l'agent tourne alors sur son `config.json`).
    public var config: AgentConsoleConfig?
    /// Le dernier status posté par l'agent : « cc tourne sur umbrel depuis 14 h 02 ».
    public var status: AgentStatus?
    /// Les derniers tours, du plus récent au plus ancien.
    public var journal: [AgentJournalEntry]

    public var id: String { agent }

    public init(
      agent: String, roomID: String, config: AgentConsoleConfig? = nil,
      status: AgentStatus? = nil, journal: [AgentJournalEntry] = []
    ) {
      self.agent = agent
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
    try await agentConsoleRooms().first { $0.agent == agent }?.roomID
  }

  /// **L'annuaire des agents** : toutes les rooms jointes qui portent un event
  /// de config à un nom d'agent.
  ///
  /// C'est la seule source de vérité de « quels agents existent » — locaux ou
  /// distants. Un drapeau posé par l'app ne prouve rien : l'agent du NUC n'a
  /// jamais été activé depuis ce Mac, et il existe. La console, elle, est une
  /// pièce sur le Relais, écrite par un propriétaire.
  public func agentConsoleRooms() async throws -> [(agent: String, roomID: String)] {
    var trouvees: [(agent: String, roomID: String)] = []
    for roomID in try await client.joinedRooms() {
      guard let content = try? await client.roomState(roomID: roomID, type: AgentWire.configType),
            let remote = AgentConsoleConfig(content: content)
      else { continue }
      trouvees.append((agent: remote.agent, roomID: roomID))
    }
    return trouvees.sorted { $0.agent < $1.agent }
  }

  /// L'annuaire avec la configuration de chacun, et **rien d'autre** : ni
  /// status, ni journal. C'est ce que le fil demande à chaque changement de
  /// conversation pour savoir qui parle à voix haute ici — un aller-retour de
  /// messages par console y coûterait trop cher.
  public func agentConfigs() async throws -> [AgentConsoleConfig] {
    var configs: [AgentConsoleConfig] = []
    for entry in try await agentConsoleRooms() {
      guard let content = try? await client.roomState(roomID: entry.roomID, type: AgentWire.configType),
            let config = AgentConsoleConfig(content: content)
      else { continue }
      configs.append(config)
    }
    return configs
  }

  /// L'annuaire, lu en entier : pour chaque agent connu du Relais, sa console,
  /// sa config, son dernier status et son journal.
  ///
  /// Coûteux (un aller-retour de messages par console) : c'est l'écran des
  /// réglages qui l'appelle, pas le fil.
  public func listAgentConsoles(journalLimit: Int = 30) async throws -> [AgentConsole] {
    var consoles: [AgentConsole] = []
    for entry in try await agentConsoleRooms() {
      guard let console = try? await readAgentConsole(
        agent: entry.agent, roomID: entry.roomID, journalLimit: journalLimit
      ) else { continue }
      consoles.append(console)
    }
    return consoles
  }

  /// La console de cet agent, créée si besoin : une room privée, l'agent
  /// invité, et la configuration écrite dedans. C'est le geste de la première
  /// activation — après quoi l'agent la découvre tout seul à son `/sync`.
  @discardableResult
  public func ensureAgentConsole(agent: String, config: AgentConsoleConfig) async throws -> String {
    if let existing = try await findAgentConsole(agent: agent) {
      // Une console qui existe garde sa config : la réécrire avec celle de
      // départ effaçait les réglages par room — vu en vrai, la voix d'une
      // conversation revenait à « voix haute » au clic suivant. « Assurer »
      // veut dire créer si ça manque, jamais remettre à zéro.
      return existing
    }
    let roomID = try await client.createGroupRoom(
      name: Self.consoleName(agent: agent),
      invite: [MatrixIdentity.agentUserID(named: agent, sameServerAs: selfUserID)]
    )
    try await writeAgentConfig(config, in: roomID)
    return roomID
  }

  /// Invite l'agent dans un salon quelconque — la note à soi, à l'activation.
  /// Idempotent en pratique : un agent déjà membre fait répondre `403` à
  /// Synapse, ce qui n'est pas une erreur ici.
  public func inviteAgentToRoom(_ roomID: String, agent: String = MatrixIdentity.agentName) async throws {
    let userID = MatrixIdentity.agentUserID(named: agent, sameServerAs: currentUserID)
    do {
      try await client.invite(roomID: roomID, userID: userID)
    } catch MatrixError.http(let status, _, _) where status == 403 {
      // Déjà membre, ou déjà invité : c'est le résultat qu'on voulait.
    }
  }

  /// Écrit la configuration. L'agent la relit à son prochain `/sync` : changer
  /// un palier d'outils ne demande ni SSH ni redémarrage.
  public func writeAgentConfig(_ config: AgentConsoleConfig, in roomID: String) async throws {
    try await client.sendStateEvent(
      roomID: roomID, type: AgentWire.configType, content: config.content()
    )
  }

  /// Demande à l'agent de rescanner ses moteurs et de redire son status. Un
  /// event de timeline dans sa console : un ordre, pas un état.
  public func requestAgentRescan(agent: String, in roomID: String) async throws {
    _ = try await client.sendEvent(
      roomID: roomID, type: AgentWire.commandType,
      content: .object([
        AgentWire.CommandKey.agent: .string(agent),
        AgentWire.CommandKey.command: .string(AgentWire.Command.rescan),
      ])
    )
  }

  /// Ce que la console raconte : la config écrite, le dernier status, les
  /// derniers tours.
  public func readAgentConsole(
    agent: String, roomID: String? = nil, journalLimit: Int = 30
  ) async throws -> AgentConsole? {
    // Pas de `??` : son opérande de droite est un autoclosure non-`async`, et
    // `findAgentConsole` en est un. On l'écrit donc en clair.
    var salon = roomID
    if salon == nil { salon = try await findAgentConsole(agent: agent) }
    guard let roomID = salon else { return nil }
    var console = AgentConsole(agent: agent, roomID: roomID)
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
            seconds: (content.value(at: AgentWire.JournalKey.durationMs)?.intValue).map { Double($0) / 1000 } ?? 0,
            tokens: content.value(at: AgentWire.JournalKey.tokens)?.intValue,
            at: event.sentAt
          )
        )
      }
    }
    return console
  }
}
