import CorrespondanceAgentKit
import CorrespondanceCore
import CorrespondanceMatrixClient
import Foundation

// correspondance-cli — l'inbox en ligne de commande.
//
// La deuxième porte sur le même cœur que `correspondance-mcp` : un cron, un
// raccourci macOS, un script, un agent qui ne parle pas MCP. Même session
// (l'amorce de l'agent), mêmes outils (`MCPInboxTools`), mêmes gardes
// (`MCPInbox`) : ce qui est refusé au modèle est refusé au shell.
//
// Un processus est un tour : « lire puis envoyer » se fait en deux commandes,
// et c'est voulu — c'est exactement la séparation que la garde MCP impose.
// Tout sur l'acteur principal : un processus, un tour, aucun partage.
@main
@MainActor
struct CLICommand {
  static func main() async {
    let (invocation, options) = InboxCommandLine.parse(
      Array(CommandLine.arguments.dropFirst()),
      stdin: { readAll() }
    )

    switch invocation {
    case .help:
      print(InboxCommandLine.usage)
    case .version:
      print("correspondance-cli 1")
    case .usage(let message):
      quit(message, code: 2, options: options, tool: nil)
    case .tools:
      for outil in MCPInbox.tools {
        let nom = outil.name.padding(toLength: 20, withPad: " ", startingAt: 0)
        print("\(nom) \(outil.regime.rawValue)  \(outil.descriptionFR)")
      }
    case .doctor:
      await doctor()
    case .call(let tool, let arguments):
      await call(tool: tool, arguments: arguments, options: options)
    }
  }

  // MARK: - Les appels

  static var allowlist: Set<String> {
    Set(
      (ProcessInfo.processInfo.environment["CORRESPONDANCE_MCP_SEND"] ?? "")
        .split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    )
  }

  static func call(tool: String, arguments: [String: Any], options: InboxCommandLine.Options) async {
    let politique = MCPInbox.Policy(sendAllowlist: allowlist)
    let conversation = arguments["conversation"] as? String
    if let refus = MCPInbox.refuse(tool: tool, conversation: conversation, policy: politique, turn: .init()) {
      quit(refus.messageFR, code: 1, options: options, tool: tool)
    }
    guard let session = await ouvrirSession() else {
      quit(
        "Pas de session sur le Relais : lance l'agent une fois, ou pointe "
          + "CORRESPONDANCE_MCP_CONFIG sur son config.json.",
        code: 3, options: options, tool: tool)
    }
    let outils = MCPInboxTools(relay: session.relais, agent: session.agent)
    let sortie = await outils.call(tool: tool, arguments: arguments)
    if options.json {
      print(InboxCommandLine.jsonLine(tool: tool, outcome: sortie))
    } else if sortie.isError {
      FileHandle.standardError.write(Data((sortie.text + "\n").utf8))
    } else {
      print(sortie.text)
    }
    exit(sortie.isError ? 1 : 0)
  }

  static func doctor() async {
    guard let config = loadConfig() else {
      print("✗ amorce introuvable — lance l'agent une fois, ou pointe CORRESPONDANCE_MCP_CONFIG")
      exit(3)
    }
    guard let session = await ouvrirSession(config) else {
      print("✗ le Relais a refusé la session de \(config.user)")
      exit(3)
    }
    let salons = (try? await session.relais.joinedRooms().count) ?? 0
    print("✓ connecté comme \(session.identite) — \(salons) conversation(s)")
    let liste = allowlist
    print(liste.isEmpty
      ? "  envoi : aucune conversation autorisée (on propose des brouillons)"
      : "  envoi autorisé dans : \(liste.sorted().joined(separator: ", "))")
  }

  // MARK: - La session

  struct Session {
    var relais: MatrixInboxRelay
    var identite: String
    var agent: String
  }

  /// L'amorce, comme celle de l'agent et du serveur MCP — la même machine, la
  /// même session. Aucun nouveau secret.
  static func loadConfig() -> AgentConfig? {
    let path = ProcessInfo.processInfo.environment["CORRESPONDANCE_MCP_CONFIG"]
    let url = path.map { URL(fileURLWithPath: $0) }
      ?? AgentHome.resolve(arguments: CommandLine.arguments).directory.appending(path: "config.json")
    return try? AgentConfig.load(from: url)
  }

  static func ouvrirSession(_ config: AgentConfig? = nil) async -> Session? {
    guard let config = config ?? loadConfig() else { return nil }
    let client = MatrixClient(credentials: nil)
    guard let credentials = try? await client.login(
      homeserver: config.homeserver, user: config.user, password: config.password
    ) else { return nil }
    return Session(
      relais: MatrixInboxRelay(client: client, selfUserID: credentials.userID),
      identite: credentials.userID,
      agent: config.user
    )
  }

  // MARK: - Sortie

  static func quit(_ message: String, code: Int32, options: InboxCommandLine.Options, tool: String?) -> Never {
    if options.json {
      print(InboxCommandLine.jsonLine(tool: tool ?? "", outcome: .init(text: message, isError: true)))
    } else {
      FileHandle.standardError.write(Data((message + "\n").utf8))
    }
    exit(code)
  }

  static func readAll() -> String? {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)
  }
}
