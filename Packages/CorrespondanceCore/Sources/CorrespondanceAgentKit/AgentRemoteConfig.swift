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
    if let object = content[AgentWire.ConfigKey.rooms]?.objectValue {
      rooms = object.reduce(into: [String: AgentConfig.RoomBinding]()) { result, entry in
        result[entry.key] = AgentConfig.RoomBinding(
          cwd: entry.value[AgentWire.ConfigKey.roomCwd]?.stringValue,
          mode: entry.value[AgentWire.ConfigKey.roomMode]?.stringValue.flatMap(AgentConfig.RoomMode.init(rawValue:))
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
    if let rooms {
      fields[AgentWire.ConfigKey.rooms] = .object(rooms.mapValues { binding in
        var entry: [String: MatrixJSON] = [:]
        if let cwd = binding.cwd { entry[AgentWire.ConfigKey.roomCwd] = .string(cwd) }
        if let mode = binding.mode { entry[AgentWire.ConfigKey.roomMode] = .string(mode.rawValue) }
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
    if let command = remote.acpCommand, !command.isEmpty {
      config.acp.command = command
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
    if backend == .acp { remote.acpCommand = acp.command }
    return remote
  }
}
