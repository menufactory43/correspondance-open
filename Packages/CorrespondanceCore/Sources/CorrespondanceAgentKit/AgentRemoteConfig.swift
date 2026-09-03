import CorrespondanceMatrixClient
import Foundation

/// La configuration d'un agent telle qu'elle vit **sur le Relais**, dans un
/// event d'état de sa room console — écrite par l'app, lue par l'agent au
/// démarrage puis à chaque `/sync`.
///
/// Sur l'hôte il ne reste que l'amorce (`homeserver`, `user`, `password`) :
/// changer le palier d'outils ou lier un dépôt depuis les réglages prend effet
/// sans SSH et sans redémarrage. C'est l'ADR 0001 appliqué à l'agent — le
/// Relais est la source de vérité, y compris de ce qu'est l'agent.
///
/// Tout est facultatif : ce que l'event ne dit pas, la config du fichier le dit
/// encore. Une room console qui n'existe pas ne casse donc rien, et le NUC
/// continue de tourner sur son `config.json` jusqu'à ce qu'on écrive l'event.
public struct AgentRemoteConfig: Sendable, Equatable {
  /// La version du schéma. Un agent plus vieux que l'event refuse de le lire
  /// plutôt que d'en deviner la moitié.
  public static let currentVersion = AgentWire.configVersion

  public var version: Int
  /// Le nom de l'agent que cet event configure (`cc`, `hermes`) — une room
  /// console par agent, et on ne lit pas la config du voisin.
  public var agent: String

  public var owners: [String]?
  public var trigger: String?
  public var hourlyCap: Int?
  public var defaultMode: AgentConfig.RoomMode?
  public var backend: AgentConfig.Backend?
  /// Le palier d'outils, par son nom (`lire`, `écrire`, `exécuter`) — l'app
  /// règle un palier, pas une liste d'outils.
  public var toolPreset: String?
  public var model: String?
  public var systemPrompt: String?
  /// Liaisons room → dépôt et mode, comme `AgentConfig.rooms`.
  public var rooms: [String: AgentConfig.RoomBinding]?
  /// La commande de l'adaptateur ACP, quand le moteur est `acp`.
  public var acpCommand: String?
  /// Ses arguments. `nil` : l'app n'a rien dit, et l'agent prend ceux qu'il
  /// connaît pour cette commande (`ACPSettings.defaultArguments`).
  public var acpArguments: [String]?
  /// Les autres agents du Relais (MXID). Renseigné par l'app quand plusieurs
  /// agents partagent un salon : c'est ce qui arme la mention obligatoire et la
  /// non-relance mutuelle (`Atelier`).
  public var peers: [String]?
  /// Le nombre de messages du fil donnés au moteur, par défaut. `0` coupe,
  /// et un `0` explicite est respecté — ce n'est pas « rien dit ».
  public var context: Int?
  /// L'heure du point du matin (`"08:00"`). Une chaîne vide efface.
  public var heartbeat: String?

  public init(agent: String, version: Int = AgentRemoteConfig.currentVersion) {
    self.agent = agent
    self.version = version
  }

  /// Lisible par cette version de l'agent ? Un event plus récent est ignoré
  /// (et dit dans le journal) : mieux vaut la config d'hier qu'une moitié de
  /// celle de demain.
  public var isReadable: Bool { version <= Self.currentVersion }

  // MARK: - L'event

  public init?(content: MatrixJSON) {
    guard let agent = content[AgentWire.ConfigKey.agent]?.stringValue else { return nil }
    self.agent = agent
    version = content[AgentWire.ConfigKey.version]?.intValue ?? 1
    owners = content[AgentWire.ConfigKey.owners]?.arrayValue?.compactMap(\.stringValue)
    trigger = content[AgentWire.ConfigKey.trigger]?.stringValue
    hourlyCap = content[AgentWire.ConfigKey.hourlyCap]?.intValue
    defaultMode = content[AgentWire.ConfigKey.defaultMode]?.stringValue.flatMap(AgentConfig.RoomMode.init(rawValue:))
    backend = content[AgentWire.ConfigKey.backend]?.stringValue.flatMap(AgentConfig.Backend.init(rawValue:))
    toolPreset = content[AgentWire.ConfigKey.toolPreset]?.stringValue
    model = content[AgentWire.ConfigKey.model]?.stringValue
    systemPrompt = content[AgentWire.ConfigKey.systemPrompt]?.stringValue
    acpCommand = content[AgentWire.ConfigKey.acpCommand]?.stringValue
    acpArguments = content[AgentWire.ConfigKey.acpArguments]?.arrayValue?.compactMap(\.stringValue)
    peers = content[AgentWire.ConfigKey.peers]?.arrayValue?.compactMap(\.stringValue)
    context = content[AgentWire.ConfigKey.context]?.intValue
    heartbeat = content[AgentWire.ConfigKey.heartbeat]?.stringValue
    if let object = content[AgentWire.ConfigKey.rooms]?.objectValue {
      rooms = object.reduce(into: [String: AgentConfig.RoomBinding]()) { result, entry in
        result[entry.key] = AgentConfig.RoomBinding(
          cwd: entry.value[AgentWire.ConfigKey.roomCwd]?.stringValue,
          mode: entry.value[AgentWire.ConfigKey.roomMode]?.stringValue.flatMap(AgentConfig.RoomMode.init(rawValue:)),
          mention: entry.value[AgentWire.ConfigKey.roomMention]?.boolValue,
          context: entry.value[AgentWire.ConfigKey.roomContext]?.intValue,
          suggest: entry.value[AgentWire.ConfigKey.roomSuggest]?.stringValue,
          keywords: entry.value[AgentWire.ConfigKey.roomKeywords]?.arrayValue?.compactMap(\.stringValue),
          frame: entry.value[AgentWire.ConfigKey.roomFrame]?.stringValue
        )
      }
    }
  }

  /// Ce que l'app écrit dans la room console.
  public func content() -> MatrixJSON {
    var fields: [String: MatrixJSON] = [
      AgentWire.ConfigKey.version: .number(Double(version)),
      AgentWire.ConfigKey.agent: .string(agent),
    ]
    if let owners { fields[AgentWire.ConfigKey.owners] = .array(owners.map(MatrixJSON.string)) }
    if let trigger { fields[AgentWire.ConfigKey.trigger] = .string(trigger) }
    if let hourlyCap { fields[AgentWire.ConfigKey.hourlyCap] = .number(Double(hourlyCap)) }
    if let defaultMode { fields[AgentWire.ConfigKey.defaultMode] = .string(defaultMode.rawValue) }
    if let backend { fields[AgentWire.ConfigKey.backend] = .string(backend.rawValue) }
    if let toolPreset { fields[AgentWire.ConfigKey.toolPreset] = .string(toolPreset) }
    if let model { fields[AgentWire.ConfigKey.model] = .string(model) }
    if let systemPrompt { fields[AgentWire.ConfigKey.systemPrompt] = .string(systemPrompt) }
    if let acpCommand { fields[AgentWire.ConfigKey.acpCommand] = .string(acpCommand) }
    if let acpArguments { fields[AgentWire.ConfigKey.acpArguments] = .array(acpArguments.map(MatrixJSON.string)) }
    if let peers { fields[AgentWire.ConfigKey.peers] = .array(peers.map(MatrixJSON.string)) }
    if let context { fields[AgentWire.ConfigKey.context] = .integer(context) }
    if let heartbeat { fields[AgentWire.ConfigKey.heartbeat] = .string(heartbeat) }
    if let rooms {
      fields[AgentWire.ConfigKey.rooms] = .object(rooms.mapValues { binding in
        var entry: [String: MatrixJSON] = [:]
        if let cwd = binding.cwd { entry[AgentWire.ConfigKey.roomCwd] = .string(cwd) }
        if let mode = binding.mode { entry[AgentWire.ConfigKey.roomMode] = .string(mode.rawValue) }
        if let mention = binding.mention { entry[AgentWire.ConfigKey.roomMention] = .bool(mention) }
        if let context = binding.context { entry[AgentWire.ConfigKey.roomContext] = .integer(context) }
        if let suggest = binding.suggest { entry[AgentWire.ConfigKey.roomSuggest] = .string(suggest) }
        if let keywords = binding.keywords { entry[AgentWire.ConfigKey.roomKeywords] = .array(keywords.map(MatrixJSON.string)) }
        if let frame = binding.frame { entry[AgentWire.ConfigKey.roomFrame] = .string(frame) }
        return .object(entry)
      })
    }
    return .object(fields)
  }
}

extension AgentConfig {
  /// La config du fichier, revue par ce que le Relais dit. Le Relais gagne
  /// **champ par champ** : ce qu'il ne mentionne pas reste tel quel, pour qu'un
  /// event minuscule n'efface pas une config complète.
  ///
  /// L'amorce ne bouge jamais : `homeserver`, `user`, `password` viennent de
  /// l'hôte, et rien d'écrit dans une room ne peut faire pointer l'agent
  /// ailleurs ni changer son identité.
  public func applying(_ remote: AgentRemoteConfig) -> AgentConfig {
    guard remote.isReadable else { return self }
    var config = self
    if let owners = remote.owners, !owners.isEmpty { config.owners = owners }
    if let trigger = remote.trigger, !trigger.isEmpty { config.trigger = trigger }
    if let cap = remote.hourlyCap, cap > 0 { config.hourlyCap = cap }
    if let mode = remote.defaultMode { config.defaultMode = mode }
    if let backend = remote.backend { config.backend = backend }
    if let rooms = remote.rooms { config.rooms = rooms }
    if let preset = remote.toolPreset, let tools = Presets.named(preset) {
      config.claude.allowedTools = tools
    }
    if let model = remote.model {
      config.claude.model = model.isEmpty ? nil : model
    }
    if let prompt = remote.systemPrompt, !prompt.isEmpty {
      config.claude.systemPrompt = prompt
    }
    if let peers = remote.peers { config.peers = peers }
    // « 0 coupe » : un zéro explicite est un choix, pas une absence. Seul un
    // nombre négatif — qui ne veut rien dire — est ignoré.
    if let context = remote.context, context >= 0 { config.context = context }
    if let heartbeat = remote.heartbeat { config.heartbeat = heartbeat.isEmpty ? nil : heartbeat }
    if let command = remote.acpCommand, !command.isEmpty {
      config.acp.command = command
      // Les arguments suivent la commande : sans eux, `goose` ouvre son
      // interface et `grok` la sienne, et aucun des deux ne parle ACP. Ce que
      // l'app a dit gagne ; sinon ce que l'agent sait de cette commande.
      config.acp.arguments = remote.acpArguments ?? AgentConfig.ACPSettings.defaultArguments(for: command)
    }
    return config
  }

  /// Ce que l'app propose comme configuration de départ pour un agent : l'état
  /// de la room console au moment de l'activation.
  public func remoteConfig() -> AgentRemoteConfig {
    var remote = AgentRemoteConfig(agent: user)
    remote.owners = owners
    remote.trigger = trigger
    remote.hourlyCap = hourlyCap
    remote.defaultMode = defaultMode
    remote.backend = backend
    remote.toolPreset = Presets.name(of: claude.allowedTools)
    remote.rooms = rooms
    remote.context = context
    remote.heartbeat = heartbeat
    if backend == .acp {
      remote.acpCommand = acp.command
      remote.acpArguments = acp.arguments
    }
    return remote
  }
}
