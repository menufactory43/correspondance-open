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

  /// Le moteur derrière ce bot : `claude` (défaut) ou `hermes`. Un bot, un
  /// moteur, un utilisateur Matrix — pour un second moteur, on lance une
  /// seconde instance (`CORRESPONDANCE_AGENT_HOME`) avec son propre compte.
  public var backend: Backend = .claude

  public var claude: ClaudeSettings = ClaudeSettings()
  public var hermes: HermesSettings = HermesSettings()
  public var acp: ACPSettings = ACPSettings()

  /// Réglages par room : dans quel dépôt travailler, et si l'agent envoie ou propose.
  public var rooms: [String: RoomBinding] = [:]

  /// Les autres agents du Relais (`@hermes:…`). Une room où l'un d'eux est
  /// présent est un **atelier** : mention obligatoire, budget de salon, et un
  /// agent n'y déclenche pas un agent (cf. `Atelier`). Vide — le défaut — veut
  /// dire qu'il n'y a pas d'atelier, et rien ne change.
  public var peers: [String] = []

  /// Le budget de tours par heure et par atelier, en plus du plafond de l'agent.
  public var atelierBudget: Int = 20

  public init(homeserver: URL, user: String, password: String, owners: [String]) {
    self.homeserver = homeserver
    self.user = user
    self.password = password
    self.owners = owners
  }

  // Tout ce qui a une valeur par défaut est facultatif dans le fichier : un
  // `config.json` de quatre lignes doit suffire.
  private enum CodingKeys: String, CodingKey {
    case homeserver, user, password, owners, trigger, hourlyCap, defaultMode, backend, claude, hermes, acp, rooms
    case peers, atelierBudget
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
    backend = try c.decodeIfPresent(Backend.self, forKey: .backend) ?? .claude
    claude = try c.decodeIfPresent(ClaudeSettings.self, forKey: .claude) ?? ClaudeSettings()
    hermes = try c.decodeIfPresent(HermesSettings.self, forKey: .hermes) ?? HermesSettings()
    acp = try c.decodeIfPresent(ACPSettings.self, forKey: .acp) ?? ACPSettings()
    rooms = try c.decodeIfPresent([String: RoomBinding].self, forKey: .rooms) ?? [:]
    peers = try c.decodeIfPresent([String].self, forKey: .peers) ?? []
    atelierBudget = try c.decodeIfPresent(Int.self, forKey: .atelierBudget) ?? 20
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

  public enum Backend: String, Codable, Sendable {
    case claude
    case hermes
    /// N'importe quel moteur qui parle l'Agent Client Protocol : Claude Code par
    /// son adaptateur, `codex-acp`, `goose acp`. Un moteur de plus est une
    /// entrée de catalogue, pas un backend de plus.
    case acp
  }

  /// Le moteur ACP : la commande à lancer, et le régime qu'on lui impose.
  /// C'est l'esquisse du catalogue des moteurs — une entrée, pas du code.
  public struct ACPSettings: Codable, Sendable, Equatable {
    /// Le nom de l'exécutable cherché aux endroits habituels (`~/.local/bin`,
    /// `/opt/homebrew/bin`…) — le `PATH` d'un LaunchAgent est vide.
    public var command: String = "claude-code-acp"
    /// Un chemin absolu qui court-circuite la recherche.
    public var binary: String?
    public var arguments: [String] = []
    public var defaultCwd: String?
    /// Le mode de permission à poser après chaque `session/new`. **Jamais le
    /// défaut du moteur** : `claude-agent-acp` 0.70.0 démarre en `auto`, où un
    /// classifieur tranche à notre place (cf. `docs/SPIKE-acp.md`).
    /// Les candidats sont essayés dans l'ordre, le premier que le moteur
    /// annonce gagne — les adaptateurs ne nomment pas leurs modes pareil.
    public var permissionModes: [String] = ["bypassPermissions", "acceptEdits", "default"]
    public var timeoutSeconds: Int = 600
    /// La version de l'adaptateur qu'on a **éprouvée**. Elle est posée par
    /// l'installation, pas cherchée au lancement : le régime de permission par
    /// défaut d'un adaptateur change d'une version à l'autre (cf. le mode
    /// `auto` de `claude-agent-acp` dans `docs/SPIKE-acp.md`). Une version
    /// différente ne bloque pas, elle se signale dans le journal.
    public var pinnedVersion: String? = "0.16.2"
    /// Comment l'installer, quand l'app propose de le faire.
    public var installCommand: String = "npm install -g @zed-industries/claude-code-acp@0.16.2"
    /// Le silence après lequel un moteur chaud s'éteint.
    public var idleSeconds: Int = 600

    public init() {}

    /// Les arguments qui font d'une CLI un serveur ACP. Un adaptateur dédié
    /// (`claude-code-acp`, `codex-acp`) n'en a pas ; une CLI complète en a un
    /// (`goose acp`, `gemini --acp`, `grok agent stdio`), et sans lui elle
    /// ouvre son interface interactive et attend un clavier. Éprouvé le
    /// 2 septembre 2026 (`docs/SPIKE-acp.md`).
    public static func defaultArguments(for command: String) -> [String] {
      switch command {
      case "goose": ["acp"]
      case "gemini": ["--acp"]
      case "grok": ["agent", "stdio"]
      case "opencode": ["acp"]
      default: []
      }
    }

    /// Le mode à poser, parmi ceux que ce moteur annonce.
    public func resolvedMode(available: [String]) -> String? {
      guard !available.isEmpty else { return permissionModes.first }
      return permissionModes.first(where: available.contains)
    }

    private enum CodingKeys: String, CodingKey {
      case command, binary, arguments, defaultCwd, permissionModes, timeoutSeconds
      case pinnedVersion, installCommand, idleSeconds
    }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      let defaults = ACPSettings()
      command = try c.decodeIfPresent(String.self, forKey: .command) ?? defaults.command
      binary = try c.decodeIfPresent(String.self, forKey: .binary)
      arguments = try c.decodeIfPresent([String].self, forKey: .arguments) ?? []
      defaultCwd = try c.decodeIfPresent(String.self, forKey: .defaultCwd)
      permissionModes = try c.decodeIfPresent([String].self, forKey: .permissionModes) ?? defaults.permissionModes
      timeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? defaults.timeoutSeconds
      pinnedVersion = try c.decodeIfPresent(String.self, forKey: .pinnedVersion) ?? defaults.pinnedVersion
      installCommand = try c.decodeIfPresent(String.self, forKey: .installCommand) ?? defaults.installCommand
      idleSeconds = try c.decodeIfPresent(Int.self, forKey: .idleSeconds) ?? defaults.idleSeconds
    }
  }

  /// Les paliers d'outils, versionnés. Le défaut est désormais le palier
  /// **plein** : un agent invité par son propriétaire a ses outils, et ce qui
  /// borne le risque est le dossier de la room, pas une liste blanche
  /// (cf. `docs/PLAN-relais-agents.md`, « pleine permission »).
  public enum Presets {
    /// Lire seulement — pour un agent qu'on invite chez des tiers.
    public static let lire = ["Read", "Grep", "Glob", "WebFetch", "WebSearch"]
    /// Lire et écrire dans le dossier lié, sans exécuter.
    public static let ecrire = lire + ["Edit", "Write", "NotebookEdit"]
    /// Tout, `Bash` compris. Le défaut.
    public static let executer: [String] = []

    /// Une liste vide veut dire « aucune restriction » côté `claude -p`.
    public static let defaut = executer

    public static func named(_ name: String) -> [String]? {
      switch name {
      case "lire": lire
      case "ecrire", "écrire": ecrire
      case "executer", "exécuter", "plein": executer
      default: nil
      }
    }

    /// Le nom du palier d'une liste d'outils — ce que l'app affiche.
    public static func name(of tools: [String]) -> String {
      switch tools {
      case executer: "exécuter"
      case ecrire: "écrire"
      case lire: "lire"
      default: "sur mesure"
      }
    }
  }

  public struct HermesSettings: Codable, Sendable, Equatable {
    /// Chemin de l'exécutable `hermes`. Résolu via `PATH` s'il est absent.
    public var binary: String?
    /// Répertoire de travail quand la room n'en fixe pas.
    public var defaultCwd: String?
    public var model: String?
    /// Au-delà, on tue le processus et on le dit dans la room.
    public var timeoutSeconds: Int = 300

    public init() {}

    private enum CodingKeys: String, CodingKey {
      case binary, defaultCwd, model, timeoutSeconds
    }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      binary = try c.decodeIfPresent(String.self, forKey: .binary)
      defaultCwd = try c.decodeIfPresent(String.self, forKey: .defaultCwd)
      model = try c.decodeIfPresent(String.self, forKey: .model)
      timeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 300
    }
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
    /// Faut-il nommer l'agent pour lui parler ici ? `nil` vaut `true` partout,
    /// sauf là où le salon est *à lui* : un tête-à-tête marqué par l'app, sa
    /// console. Mettre `false` sur un salon ordinaire y rend tout message d'un
    /// propriétaire une demande — c'est un choix, pas un défaut : dans une
    /// note à soi ou un fil bridgé, ce serait insupportable.
    public var mention: Bool?

    public init(cwd: String? = nil, mode: RoomMode? = nil, mention: Bool? = nil) {
      self.cwd = cwd
      self.mode = mode
      self.mention = mention
    }
  }

  public struct ClaudeSettings: Codable, Sendable, Equatable {
    /// Chemin de l'exécutable `claude`. Résolu via `PATH` s'il est absent.
    public var binary: String?
    /// Répertoire de travail quand la room n'en fixe pas.
    public var defaultCwd: String?
    /// Outils autorisés sans question en mode `-p`. Vide — le défaut — veut
    /// dire « pas de liste blanche » : c'est `permissionMode` qui décide, et il
    /// vaut `bypassPermissions` (cf. `Presets`).
    public var allowedTools: [String] = Presets.defaut
    /// Le régime posé sur la session, jamais subi. `bypassPermissions` : un
    /// agent invité par son propriétaire a ses outils. Ce qui borne le risque
    /// est le dossier de la room, pas une question à laquelle on répondrait oui.
    public var permissionMode: String = "bypassPermissions"
    public var model: String?
    /// Ajouté au prompt système de Claude Code. Dit à Claude qui il est ici.
    public var systemPrompt: String = ClaudeSettings.defaultSystemPrompt
    /// Au-delà, on tue le processus et on le dit dans la room.
    public var timeoutSeconds: Int = 300
    /// Les outils hors de `allowedTools` : refusés (`enabled: false`), ou
    /// demandés dans la room et accordés par un 👍 d'un propriétaire.
    public var permission: PermissionSettings = PermissionSettings()

    public init() {}

    private enum CodingKeys: String, CodingKey {
      case binary, defaultCwd, allowedTools, permissionMode, model, systemPrompt, timeoutSeconds, permission
    }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      binary = try c.decodeIfPresent(String.self, forKey: .binary)
      defaultCwd = try c.decodeIfPresent(String.self, forKey: .defaultCwd)
      allowedTools = try c.decodeIfPresent([String].self, forKey: .allowedTools) ?? Presets.defaut
      permissionMode = try c.decodeIfPresent(String.self, forKey: .permissionMode) ?? "bypassPermissions"
      model = try c.decodeIfPresent(String.self, forKey: .model)
      systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt) ?? Self.defaultSystemPrompt
      timeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 300
      permission = try c.decodeIfPresent(PermissionSettings.self, forKey: .permission) ?? PermissionSettings()
    }

    public struct PermissionSettings: Codable, Sendable, Equatable {
      public var enabled: Bool = false
      /// Le temps laissé au 👍 avant que la demande ne devienne un refus.
      public var timeoutSeconds: Int = 120

      public init() {}

      private enum CodingKeys: String, CodingKey { case enabled, timeoutSeconds }

      public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        timeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 120
      }
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
