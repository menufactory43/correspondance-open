import CorrespondanceMatrixClient
import Foundation

/// La configuration d'un agent, vue de l'app : ce qu'on écrit dans sa room
/// console et que l'agent relit à chaque `/sync`.
///
/// C'est le même event que `AgentRemoteConfig` côté agent, et les deux lisent
/// **les mêmes clés** (`AgentWire.ConfigKey`) — pas deux définitions du format
/// qui divergeraient au premier champ ajouté. Deux types, parce que l'app ne
/// peut pas dépendre de l'AgentKit : `Process` n'existe pas sur iOS.
public struct AgentConsoleConfig: Sendable, Equatable {
  public var version: Int
  public var agent: String
  public var owners: [String]?
  public var trigger: String?
  public var hourlyCap: Int?
  public var defaultMode: AgentSettings.Mode?
  /// `claude`, `hermes`, `acp` — le moteur, tel que l'agent le comprend.
  public var backend: String?
  /// Le palier d'outils par son nom : `lire`, `écrire`, `exécuter`.
  public var toolPreset: String?
  public var model: String?
  public var systemPrompt: String?
  public var acpCommand: String?
  /// Les **autres** agents du Relais, par leur MXID. L'app les renseigne quand
  /// plusieurs agents partagent un salon : c'est ce qui fait de ce salon un
  /// atelier — mention obligatoire, et un agent ne relance pas un agent. Sans
  /// eux, deux agents dans une même room se répondraient l'un l'autre.
  public var peers: [String]?
  /// Liaisons conversation → dossier de travail et mode.
  public var rooms: [String: RoomBinding]

  public struct RoomBinding: Sendable, Equatable {
    /// Le dépôt lié. `nil` : l'agent travaille dans le dossier de la
    /// conversation, ce qui est le défaut et le garde-fou.
    public var cwd: String?
    public var mode: AgentSettings.Mode?

    public init(cwd: String? = nil, mode: AgentSettings.Mode? = nil) {
      self.cwd = cwd
      self.mode = mode
    }
  }

  public init(agent: String, version: Int = AgentWire.configVersion) {
    self.agent = agent
    self.version = version
    self.rooms = [:]
  }

  // MARK: - L'event

  public init?(content: MatrixJSON) {
    guard let agent = content[AgentWire.ConfigKey.agent]?.stringValue else { return nil }
    self.agent = agent
    version = content[AgentWire.ConfigKey.version]?.intValue ?? 1
    owners = content[AgentWire.ConfigKey.owners]?.arrayValue?.compactMap(\.stringValue)
    trigger = content[AgentWire.ConfigKey.trigger]?.stringValue
    hourlyCap = content[AgentWire.ConfigKey.hourlyCap]?.intValue
    defaultMode = content[AgentWire.ConfigKey.defaultMode]?.stringValue.flatMap(AgentSettings.Mode.init(rawValue:))
    backend = content[AgentWire.ConfigKey.backend]?.stringValue
    toolPreset = content[AgentWire.ConfigKey.toolPreset]?.stringValue
    model = content[AgentWire.ConfigKey.model]?.stringValue
    systemPrompt = content[AgentWire.ConfigKey.systemPrompt]?.stringValue
    acpCommand = content[AgentWire.ConfigKey.acpCommand]?.stringValue
    peers = content[AgentWire.ConfigKey.peers]?.arrayValue?.compactMap(\.stringValue)
    rooms = (content[AgentWire.ConfigKey.rooms]?.objectValue ?? [:]).reduce(into: [:]) { result, entry in
      result[entry.key] = RoomBinding(
        cwd: entry.value[AgentWire.ConfigKey.roomCwd]?.stringValue,
        mode: entry.value[AgentWire.ConfigKey.roomMode]?.stringValue.flatMap(AgentSettings.Mode.init(rawValue:))
      )
    }
  }

  public func content() -> MatrixJSON {
    var fields: [String: MatrixJSON] = [
      AgentWire.ConfigKey.version: .number(Double(version)),
      AgentWire.ConfigKey.agent: .string(agent),
    ]
    if let owners { fields[AgentWire.ConfigKey.owners] = .array(owners.map(MatrixJSON.string)) }
    if let trigger { fields[AgentWire.ConfigKey.trigger] = .string(trigger) }
    if let hourlyCap { fields[AgentWire.ConfigKey.hourlyCap] = .number(Double(hourlyCap)) }
    if let defaultMode { fields[AgentWire.ConfigKey.defaultMode] = .string(defaultMode.rawValue) }
    if let backend { fields[AgentWire.ConfigKey.backend] = .string(backend) }
    if let toolPreset { fields[AgentWire.ConfigKey.toolPreset] = .string(toolPreset) }
    if let model { fields[AgentWire.ConfigKey.model] = .string(model) }
    if let systemPrompt { fields[AgentWire.ConfigKey.systemPrompt] = .string(systemPrompt) }
    if let acpCommand { fields[AgentWire.ConfigKey.acpCommand] = .string(acpCommand) }
    if let peers, !peers.isEmpty {
      fields[AgentWire.ConfigKey.peers] = .array(peers.map(MatrixJSON.string))
    }
    if !rooms.isEmpty {
      fields[AgentWire.ConfigKey.rooms] = .object(rooms.mapValues { binding in
        var entry: [String: MatrixJSON] = [:]
        if let cwd = binding.cwd { entry[AgentWire.ConfigKey.roomCwd] = .string(cwd) }
        if let mode = binding.mode { entry[AgentWire.ConfigKey.roomMode] = .string(mode.rawValue) }
        return .object(entry)
      })
    }
    return .object(fields)
  }

  /// La voix de l'agent dans une room : ce qu'elle dit elle-même, sinon le
  /// défaut. C'est ce que le tiroir « + » d'une conversation affiche.
  public func voice(in roomID: String) -> AgentSettings.Mode {
    rooms[roomID]?.mode ?? defaultMode ?? .draft
  }

  /// La même config avec la voix de cette room posée. Le dépôt lié, s'il y en
  /// a un, ne bouge pas : ce sont deux réglages sur la même ligne.
  public func settingVoice(_ mode: AgentSettings.Mode, in roomID: String) -> AgentConsoleConfig {
    var copy = self
    var binding = copy.rooms[roomID] ?? RoomBinding()
    binding.mode = mode
    copy.rooms[roomID] = binding
    return copy
  }

  /// Les paliers d'outils tels que l'app les propose. Les listes exactes vivent
  /// côté agent (`AgentConfig.Presets`) : ici on ne manipule que leur nom.
  public enum ToolPreset: String, CaseIterable, Identifiable, Sendable {
    case lire
    case ecrire = "écrire"
    case executer = "exécuter"

    public var id: String { rawValue }

    public var labelFR: String {
      switch self {
      case .lire: "Lire"
      case .ecrire: "Lire et écrire"
      case .executer: "Tout, exécution comprise"
      }
    }

    public var subtitleFR: String {
      switch self {
      case .lire: "Lecture de fichiers et du web. Rien qui modifie."
      case .ecrire: "Peut écrire dans le dossier de la conversation."
      case .executer: "Peut aussi lancer des commandes. Le dossier de la conversation reste sa limite."
      }
    }
  }
}
