import CorrespondanceAgentKit
import Foundation

// correspondance-agent — « cc », un membre de tes conversations qui parle à
// Claude Code, sur l'abonnement de la machine.
//
//   correspondance-agent init            écrit ~/.correspondance-agent/config.json
//   correspondance-agent rooms           liste les rooms rejointes (pour la config)
//   correspondance-agent run             tourne (défaut)
//   correspondance-agent ask "…"         un tour de Claude sans Matrix (diagnostic)
//   CORRESPONDANCE_AGENT_HOME=/chemin    change le dossier de config/état
//
// Pas de `main.swift` : son code de premier niveau est `@MainActor`, et un
// `Task` y hériterait de l'acteur principal — bloqué dès qu'on l'attend.
@main
struct AgentCommand {
  static let home = ProcessInfo.processInfo.environment["CORRESPONDANCE_AGENT_HOME"].map { URL(fileURLWithPath: $0) }
    ?? AgentConfig.defaultDirectory
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
        let turn = try await ClaudeCodeBackend(settings: config.claude).run(prompt: prompt, cwd: nil, sessionID: nil)
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
      guard ClaudeCodeBackend.resolveBinary(config.claude.binary) != nil else {
        fail("`claude` introuvable — installe Claude Code ou renseigne claude.binary")
      }
      let agent = Agent(config: config, backend: ClaudeCodeBackend(settings: config.claude), stateURL: stateURL, log: { stamp($0) })
      do {
        try await agent.run()
      } catch {
        fail(error.localizedDescription)
      }

    default:
      fail("commande inconnue « \(command) » — init | rooms | run | ask")
    }
  }
}
