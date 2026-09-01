import Foundation

/// Où vit l'amorce d'un agent sur sa machine.
///
/// Un plist de LaunchAgent est un fichier statique : il ne connaît ni `~`, ni
/// la variable d'environnement qu'on aurait aimé lui donner. Le dossier se
/// déduit donc du **nom de l'agent**, passé en argument — `--agent hermes` →
/// `~/.correspondance-hermes`. C'est ce qui permet à un même binaire embarqué
/// de servir plusieurs agents sur le même Mac.
///
/// Ce qu'on y trouve : `config.json` (l'amorce — homeserver, user, password),
/// `state.json` (le jeton, les sessions, la position de sync) et `agent.log`.
public enum AgentHome {

  /// Le nom par défaut, quand personne ne dit lequel.
  public static let defaultAgent = "cc"

  /// Le dossier de cet agent. `cc` garde l'ancien chemin
  /// (`~/.correspondance-agent`) : un NUC en production ne doit pas perdre son
  /// état parce qu'on a introduit `--agent`.
  public static func directory(
    agent: String,
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> URL {
    let name = sanitize(agent)
    if name == defaultAgent { return home.appending(path: ".correspondance-agent") }
    return home.appending(path: ".correspondance-\(name)")
  }

  /// Un nom d'agent est un localpart Matrix : lettres, chiffres, `.`, `-`, `_`.
  /// Ce qui déborde ne fabrique pas de chemin.
  public static func sanitize(_ agent: String) -> String {
    let cleaned = agent.lowercased().map { character -> Character in
      character.isLetter || character.isNumber || character == "." || character == "-" || character == "_"
        ? character : "-"
    }
    let text = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
    return text.isEmpty ? defaultAgent : text
  }

  /// Le dossier que la commande doit utiliser : l'argument `--agent` d'abord,
  /// la variable d'environnement ensuite (le montage historique du NUC, qui
  /// lance plusieurs services avec `CORRESPONDANCE_AGENT_HOME`), le défaut
  /// enfin. L'ordre compte : un plist statique passe `--agent`, et il doit
  /// gagner sur un environnement hérité.
  public static func resolve(
    arguments: [String],
    environment: [String: String] = ProcessInfo.processInfo.environment,
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> (agent: String, directory: URL) {
    if let agent = agentName(in: arguments) {
      return (agent, directory(agent: agent, home: home))
    }
    if let path = environment["CORRESPONDANCE_AGENT_HOME"], !path.isEmpty {
      let url = URL(fileURLWithPath: path)
      // Le nom se relit du dossier : `~/.correspondance-hermes` → `hermes`.
      let last = url.lastPathComponent
      let agent = last.hasPrefix(".correspondance-") && last != ".correspondance-agent"
        ? String(last.dropFirst(".correspondance-".count))
        : defaultAgent
      return (agent, url)
    }
    return (defaultAgent, directory(agent: defaultAgent, home: home))
  }

  /// `--agent hermes` ou `--agent=hermes`.
  static func agentName(in arguments: [String]) -> String? {
    for (index, argument) in arguments.enumerated() {
      if argument == "--agent", index + 1 < arguments.count {
        return sanitize(arguments[index + 1])
      }
      if argument.hasPrefix("--agent=") {
        return sanitize(String(argument.dropFirst("--agent=".count)))
      }
    }
    return nil
  }
}
