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
  ///
  /// **`CORRESPONDANCE_HOME` le déplace, comme il déplace les données de l'app.**
  /// C'était le piège que `docs/MATRIX-SETUP.md` signalait sans le corriger :
  /// un essai déplaçait la base et le Trousseau, mais « Activer sur ce Mac »
  /// écrivait quand même l'amorce dans `~/.correspondance-agent/` — le dossier
  /// d'un cc de production, qu'un essai n'a rien à toucher. Le suffixe est le
  /// même que celui du dossier de données (`Correspondance-unclic` →
  /// `~/.correspondance-agent-unclic`), et il vaut pour l'app comme pour
  /// l'agent : le processus enfant hérite de la variable, donc les deux
  /// calculent le même chemin sans se parler.
  public static func directory(
    agent: String,
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL {
    home.appending(path: folderName(agent: agent, environment: environment))
  }

  /// Le nom du dossier, sans le chemin. Séparé pour être relu à l'envers.
  public static func folderName(
    agent: String,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> String {
    let name = sanitize(agent)
    let base = name == defaultAgent ? ".correspondance-agent" : ".correspondance-\(name)"
    guard let essai = essai(environment) else { return base }
    return "\(base)-\(essai)"
  }

  /// Le nom de l'essai en cours, s'il y en a un. Même nettoyage que
  /// `CorrespondanceHome.sanitize` côté app — les deux doivent donner le même
  /// suffixe, et un test les tient ensemble.
  public static func essai(_ environment: [String: String] = ProcessInfo.processInfo.environment)
    -> String?
  {
    guard let brut = environment["CORRESPONDANCE_HOME"] else { return nil }
    let propre = String(
      brut.map { caractere -> Character in
        caractere.isLetter || caractere.isNumber || caractere == "-" || caractere == "_"
          ? caractere : "-"
      }
    ).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
    return propre.isEmpty ? nil : propre
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
      return (agent, directory(agent: agent, home: home, environment: environment))
    }
    if let path = environment["CORRESPONDANCE_AGENT_HOME"], !path.isEmpty {
      let url = URL(fileURLWithPath: path)
      // Le nom se relit du dossier : `~/.correspondance-hermes` → `hermes`.
      // Le suffixe d'essai se retire d'abord, sinon `.correspondance-agent-unclic`
      // fabriquerait un agent qui s'appellerait « agent-unclic ».
      var last = url.lastPathComponent
      if let essai = essai(environment), last.hasSuffix("-\(essai)") {
        last.removeLast(essai.count + 1)
      }
      let agent = last.hasPrefix(".correspondance-") && last != ".correspondance-agent"
        ? String(last.dropFirst(".correspondance-".count))
        : defaultAgent
      return (agent, url)
    }
    return (defaultAgent, directory(agent: defaultAgent, home: home, environment: environment))
  }

  /// La contradiction qui a coûté la phase 7a, dite à voix haute.
  ///
  /// L'unité du NUC passait `--agent cc` **et** `CORRESPONDANCE_AGENT_HOME`
  /// vers le dossier du spike. `--agent` gagne — c'est la règle, et elle est
  /// juste : un plist statique doit gagner sur un environnement hérité, sinon
  /// une variable oubliée détourne un agent vers le dossier d'un autre. Mais
  /// ici les deux venaient de la même main, et le perdant était le seul des
  /// deux à dire « ceci est un essai » : `cc` a donc lu l'amorce de la
  /// production et s'est connecté au vrai Relais. Seule la garde du second
  /// agent l'a arrêté.
  ///
  /// On ne renverse pas la règle — ce serait rouvrir le trou qu'elle bouche.
  /// On rend le silence impossible : quand `--agent` fait ignorer un
  /// `CORRESPONDANCE_AGENT_HOME` qui désignait ailleurs, la première ligne du
  /// journal le dit et nomme la variable à utiliser à la place.
  ///
  /// Un essai s'écrit `CORRESPONDANCE_HOME`, qui se **multiplie** avec
  /// `--agent` au lieu de se disputer avec lui.
  public static func contradiction(
    arguments: [String],
    environment: [String: String] = ProcessInfo.processInfo.environment,
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> String? {
    guard let agent = agentName(in: arguments) else { return nil }
    guard let chemin = environment["CORRESPONDANCE_AGENT_HOME"], !chemin.isEmpty else { return nil }
    let retenu = directory(agent: agent, home: home, environment: environment)
    let ignore = URL(fileURLWithPath: chemin).standardizedFileURL
    guard ignore.path() != retenu.standardizedFileURL.path() else { return nil }
    return "⚠ `--agent \(agent)` l'emporte : CORRESPONDANCE_AGENT_HOME=\(chemin) est ignoré,"
      + " je lis \(retenu.path()). Pour un essai, c'est CORRESPONDANCE_HOME qu'il faut poser"
      + " — elle se combine avec --agent au lieu de se faire ignorer."
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
