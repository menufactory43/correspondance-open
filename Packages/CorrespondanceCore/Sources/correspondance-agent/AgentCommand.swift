import CorrespondanceAgentKit
import Foundation

// correspondance-agent — « cc », un membre de tes conversations qui parle à
// Claude Code, sur l'abonnement de la machine.
//
//   correspondance-agent init            écrit ~/.correspondance-agent/config.json
//   correspondance-agent rooms           liste les rooms rejointes (pour la config)
//   correspondance-agent run             tourne (défaut)
//   correspondance-agent run --agent hermes   tourne sur ~/.correspondance-hermes
//   correspondance-agent ask "…"         un tour du moteur sans Matrix (diagnostic)
//   correspondance-agent doctor          quels moteurs la machine sait lancer
//   CORRESPONDANCE_AGENT_HOME=/chemin    change le dossier de config/état
//
// Pas de `main.swift` : son code de premier niveau est `@MainActor`, et un
// `Task` y hériterait de l'acteur principal — bloqué dès qu'on l'attend.
@main
struct AgentCommand {
  /// Quel agent, et où vit son amorce. `--agent hermes` d'abord (c'est ce
  /// qu'un plist statique de LaunchAgent sait passer), `CORRESPONDANCE_AGENT_HOME`
  /// ensuite (le montage historique du NUC), le défaut enfin.
  static let resolved = AgentHome.resolve(arguments: CommandLine.arguments)
  static var agent: String { resolved.agent }
  static var home: URL { resolved.directory }
  static var configURL: URL { home.appending(path: "config.json") }
  static var stateURL: URL { home.appending(path: "state.json") }

  static func stamp(_ line: String) {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    // Non tamponné : sous systemd ou Docker, le journal doit suivre en direct.
    FileHandle.standardOutput.write(Data("\(f.string(from: Date())) \(line)\n".utf8))
  }

  static func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("correspondance-agent : \(message)\n".utf8))
    exit(1)
  }

  static func loadConfig() -> AgentConfig {
    do {
      return try AgentConfig.load(from: configURL)
    } catch {
      fail("config illisible (\(configURL.path())) : \(error.localizedDescription) — `correspondance-agent init` pour en créer une")
    }
  }

  /// Le moteur que la config désigne, ou l'échec qui dit quoi installer.
  static func makeBackend(_ config: AgentConfig) -> any AgentBackend {
    switch config.backend {
    case .claude:
      guard ClaudeCodeBackend.resolveBinary(config.claude.binary) != nil else {
        fail("`claude` introuvable — installe Claude Code ou renseigne claude.binary")
      }
      let selfBinary = ClaudeCodeBackend.resolveSelfBinary()
      if config.claude.permission.enabled, selfBinary == nil {
        fail("permission.enabled mais je ne retrouve pas mon propre exécutable — lance-moi par un chemin absolu")
      }
      return ClaudeCodeBackend(settings: config.claude, selfBinary: selfBinary)
    case .hermes:
      guard HermesBackend.resolveBinary(config.hermes.binary) != nil else {
        fail("`hermes` introuvable — installe Hermes (Nous Research) ou renseigne hermes.binary")
      }
      return HermesBackend(settings: config.hermes)
    case .acp:
      let acp = ACPBackend(settings: config.acp, log: { stamp($0) })
      // L'ACP apporte une dépendance neuve (un adaptateur Node) là où `claude`
      // suffisait. Si `claude` est là, il devient le repli : un hôte sans
      // adaptateur répond quand même, et le journal le dit. Sans repli
      // possible, on refuse de démarrer plutôt que de rester muet en silence.
      guard ClaudeCodeBackend.resolveBinary(config.claude.binary) != nil else {
        guard ACPBackend.resolveBinary(config.acp) != nil else {
          fail("ni `\(config.acp.command)` ni `claude` — installe l'adaptateur (\(config.acp.installCommand)) ou Claude Code")
        }
        return acp
      }
      if ACPBackend.resolveBinary(config.acp) == nil {
        stamp("`\(config.acp.command)` introuvable — je réponds par la CLI ; pour l'ACP : \(config.acp.installCommand)")
      }
      return FallbackBackend(
        primary: acp,
        secondary: ClaudeCodeBackend(settings: config.claude, selfBinary: ClaudeCodeBackend.resolveSelfBinary()),
        log: { stamp($0) }
      )
    }
  }

  static func main() async {
    let command = CommandLine.arguments.dropFirst().first ?? "run"
    switch command {
    case "init":
      if FileManager.default.fileExists(atPath: configURL.path()) {
        fail("\(configURL.path()) existe déjà — je ne l'écrase pas")
      }
      do {
        try AgentConfig.example().write(to: configURL)
        print("écrit \(configURL.path()) — remplis homeserver, password, owners, puis `correspondance-agent run`")
      } catch {
        fail("impossible d'écrire la config : \(error.localizedDescription)")
      }

    case "ask":
      let config = (try? AgentConfig.load(from: configURL)) ?? AgentConfig.example()
      let prompt = CommandLine.arguments.dropFirst(2).joined(separator: " ")
      guard !prompt.isEmpty else { fail("ask : il manque la question") }
      do {
        let turn = try await makeBackend(config).run(prompt: prompt, cwd: nil, sessionID: nil)
        print(turn.text)
        print("— session \(turn.sessionID ?? "?")\(turn.isError ? " (erreur)" : "")")
      } catch {
        fail(error.localizedDescription)
      }

    case "rooms":
      let config = loadConfig()
      let agent = Agent(config: config, backend: ClaudeCodeBackend(settings: config.claude), stateURL: stateURL, log: { stamp($0) })
      do {
        for room in try await agent.listRooms() {
          let binding = config.rooms[room.roomID]
          let note = binding.map { " — \($0.mode?.rawValue ?? "auto")\($0.cwd.map { ", \($0)" } ?? "")" } ?? ""
          print("\(room.roomID)  \(room.name)\(note)")
        }
      } catch {
        fail(error.localizedDescription)
      }

    case "run":
      let config = loadConfig()
      // L'app nous passe son pid : quand elle meurt — proprement, par un crash
      // ou par un `pkill` — on meurt avec elle. Sans ça l'agent survit,
      // connecté au Relais, prêt à répondre au nom de son propriétaire, et un
      // relancement donne deux agents sur le même compte.
      var surveillance: Task<Void, Never>?
      if let parent = ParentWatch.expectedParent(in: CommandLine.arguments) {
        stamp("surveillance du parent \(parent) : je m'arrête s'il disparaît")
        surveillance = ParentWatch.watch(expected: parent) {
          FileHandle.standardOutput.write(Data("l'app qui m'a lancé a disparu — je m'arrête\n".utf8))
          exit(0)
        }
      }
      defer { surveillance?.cancel() }
      let agent = Agent(config: config, backend: makeBackend(config), stateURL: stateURL, log: { stamp($0) })
      do {
        try await agent.run()
      } catch {
        fail(error.localizedDescription)
      }

    // Quels moteurs cette machine sait lancer, et si celui de la config est là.
    case "doctor":
      let config = (try? AgentConfig.load(from: configURL)) ?? AgentConfig.example()
      let scan = await Task.detached { EngineScan.scan(config: config) }.value
      print(scan.reportFR(backend: config.backend))
      if !scan.isPresent(config.backend) { exit(1) }

    // Serveur MCP éphémère, lancé par `claude` (jamais à la main) : il porte
    // les demandes d'outils au spool et attend le 👍. Cf. `Permission`.
    case "permission-tool":
      let args = CommandLine.arguments.dropFirst(2)
      guard let spoolPath = args.first else { fail("permission-tool : il manque le dossier de spool") }
      let timeout = args.dropFirst().first.flatMap(Int.init) ?? 120
      PermissionTool(spool: URL(fileURLWithPath: spoolPath), timeoutSeconds: timeout).serve()

    default:
      fail("commande inconnue « \(command) » — init | rooms | run | ask | doctor")
    }
  }
}
