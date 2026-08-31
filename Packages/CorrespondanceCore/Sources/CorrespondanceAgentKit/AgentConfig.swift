import Foundation

/// Ce que l'agent doit savoir pour tourner. Lu une fois au démarrage depuis
/// `~/.correspondance-agent/config.json` ; rien n'est en dur, l'URL du Relais
/// en premier (règle du plan iOS : « configuration, jamais en dur »).
public struct AgentConfig: Codable, Sendable, Equatable {
  /// Le Relais, tel que le bot le joint (`http://100.x.y.z:8008` sur le tailnet).
  public var homeserver: URL
  /// Localpart du bot (`cc`) et son mot de passe — le token, une fois obtenu,
  /// vit dans l'état, pas ici.
  public var user: String
  public var password: String

  /// Qui a le droit de parler à l'agent. Tout autre expéditeur est ignoré en
  /// silence : dans un groupe, les humains lisent, ils ne déclenchent pas.
  public var owners: [String]

  /// Le préfixe qui réveille l'agent. `@cc` par défaut.
  public var trigger: String = "@cc"

  /// Appels à Claude autorisés par heure glissante. Une boucle bête ne doit
  /// pas vider la fenêtre de l'abonnement pendant la nuit.
  public var hourlyCap: Int = 30

  /// Le mode d'une room qui n'est pas dans `rooms` et qui n'est pas un tête-à-tête
  /// avec un propriétaire : `draft`, toujours. `direct` ne se donne qu'à la main.
  public var defaultMode: RoomMode = .draft

  public var claude: ClaudeSettings = ClaudeSettings()

  /// Réglages par room : dans quel dépôt travailler, et si l'agent envoie ou propose.
  public var rooms: [String: RoomBinding] = [:]

  public init(homeserver: URL, user: String, password: String, owners: [String]) {
    self.homeserver = homeserver
    self.user = user
    self.password = password
    self.owners = owners
  }

  // Tout ce qui a une valeur par défaut est facultatif dans le fichier : un
  // `config.json` de quatre lignes doit suffire.
  private enum CodingKeys: String, CodingKey {
    case homeserver, user, password, owners, trigger, hourlyCap, defaultMode, claude, rooms
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    homeserver = try c.decode(URL.self, forKey: .homeserver)
    user = try c.decode(String.self, forKey: .user)
    password = try c.decode(String.self, forKey: .password)
    owners = try c.decode([String].self, forKey: .owners)
    trigger = try c.decodeIfPresent(String.self, forKey: .trigger) ?? "@cc"
    hourlyCap = try c.decodeIfPresent(Int.self, forKey: .hourlyCap) ?? 30
    defaultMode = try c.decodeIfPresent(RoomMode.self, forKey: .defaultMode) ?? .draft
    claude = try c.decodeIfPresent(ClaudeSettings.self, forKey: .claude) ?? ClaudeSettings()
    rooms = try c.decodeIfPresent([String: RoomBinding].self, forKey: .rooms) ?? [:]
  }

  /// Le Matrix ID complet du bot, déduit du `server_name` d'un propriétaire.
  /// `@cc:correspondance.local` si les propriétaires sont sur `correspondance.local`.
  public var botUserID: String {
    if user.hasPrefix("@") { return user }
    let serverName = owners.first.flatMap { owner -> String? in
      guard let colon = owner.lastIndex(of: ":") else { return nil }
      return String(owner[owner.index(after: colon)...])
    }
    return "@\(user):\(serverName ?? homeserver.host() ?? "localhost")"
  }

  public enum RoomMode: String, Codable, Sendable {
    /// L'agent envoie sa réponse dans la room, en `m.room.message`. Sur une
    /// room-portail en relais, elle part vers le réseau **au nom du propriétaire**.
    case direct
    /// L'agent propose : un event `fr.correspondance.agent.proposal` que les
    /// ponts ignorent. Seul Correspondance le voit, et c'est le propriétaire qui envoie.
    case draft
  }

  public struct RoomBinding: Codable, Sendable, Equatable {
    /// Répertoire de travail de Claude pour cette room. `nil` : le répertoire par défaut.
    public var cwd: String?
    public var mode: RoomMode?

    public init(cwd: String? = nil, mode: RoomMode? = nil) {
      self.cwd = cwd
      self.mode = mode
    }
  }

  public struct ClaudeSettings: Codable, Sendable, Equatable {
    /// Chemin de l'exécutable `claude`. Résolu via `PATH` s'il est absent.
    public var binary: String?
    /// Répertoire de travail quand la room n'en fixe pas.
    public var defaultCwd: String?
    /// Outils autorisés sans question en mode `-p`. Tout le reste est refusé,
    /// pas demandé : on n'est pas devant le terminal.
    public var allowedTools: [String] = ["Read", "Grep", "Glob"]
    public var model: String?
    /// Ajouté au prompt système de Claude Code. Dit à Claude qui il est ici.
    public var systemPrompt: String = ClaudeSettings.defaultSystemPrompt
    /// Au-delà, on tue le processus et on le dit dans la room.
    public var timeoutSeconds: Int = 300

    public init() {}

    private enum CodingKeys: String, CodingKey {
      case binary, defaultCwd, allowedTools, model, systemPrompt, timeoutSeconds
    }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      binary = try c.decodeIfPresent(String.self, forKey: .binary)
      defaultCwd = try c.decodeIfPresent(String.self, forKey: .defaultCwd)
      allowedTools = try c.decodeIfPresent([String].self, forKey: .allowedTools) ?? ["Read", "Grep", "Glob"]
      model = try c.decodeIfPresent(String.self, forKey: .model)
      systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt) ?? Self.defaultSystemPrompt
      timeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 300
    }

    public static let defaultSystemPrompt = """
      Tu es « cc », l'agent de ton propriétaire dans une conversation de messagerie \
      (WhatsApp, Signal, Instagram ou une note à soi). Tes réponses sont lues dans \
      une bulle de chat : réponds en français, court, en texte brut — pas de Markdown, \
      pas de titres, pas de listes à puces sauf nécessité absolue. Va droit au fait.
      """
  }

  // MARK: - Fichier

  public static var defaultDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser.appending(path: ".correspondance-agent")
  }

  public static func load(from url: URL) throws -> AgentConfig {
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(AgentConfig.self, from: data)
  }

  /// Un exemple prêt à remplir, écrit par `correspondance-agent init`.
  public static func example() -> AgentConfig {
    var config = AgentConfig(
      homeserver: URL(string: "http://100.64.0.1:8008")!,
      user: "cc",
      password: "à-remplir",
      owners: ["@meffysto:correspondance.local"]
    )
    config.claude.defaultCwd = FileManager.default.homeDirectoryForCurrentUser.path()
    config.rooms["!exemple:correspondance.local"] = RoomBinding(cwd: "/Users/moi/mon-repo", mode: .direct)
    return config
  }

  public func write(to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(self).write(to: url, options: .atomic)
  }
}
