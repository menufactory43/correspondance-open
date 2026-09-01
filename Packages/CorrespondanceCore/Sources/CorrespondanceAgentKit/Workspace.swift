import Foundation

/// Le dossier où un tour travaille. **C'est le rayon d'explosion**, et depuis
/// qu'on donne la pleine permission aux outils, c'est le seul vrai garde-fou
/// avec « les propriétaires seuls déclenchent » (cf. `docs/PLAN-relais-agents.md`).
///
/// Règle : jamais `~`, jamais le dossier courant du service. Une room sans
/// dépôt lié travaille dans `~/.correspondance-<agent>/ateliers/<room>`, créé
/// au besoin — sous le dossier caché de l'agent (`AgentHome`), et surtout pas
/// sous `~/Correspondance` : sur un disque insensible à la casse, c'est le même
/// chemin que `~/correspondance`, et cc a écrit dans le dépôt de l'app.
public enum Workspace {

  /// Le dossier d'un tour. `binding` est le dépôt lié à cette room dans la
  /// config — la seule façon de sortir du bac à sable, et elle est explicite.
  public static func directory(
    agent: String,
    roomID: String,
    binding: String?,
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> String {
    if let binding, !binding.isEmpty, isAcceptable(binding, home: home) { return binding }
    return AgentHome.directory(agent: agent, home: home)
      .appending(path: "ateliers")
      .appending(path: sanitize(roomID))
      .path()
  }

  /// Un dépôt lié doit être un chemin absolu, et ne peut pas être la maison
  /// elle-même : « lie ce dépôt » ne veut jamais dire « ouvre tout ».
  static func isAcceptable(_ path: String, home: URL) -> Bool {
    guard path.hasPrefix("/") else { return false }
    let normalized = URL(fileURLWithPath: path).standardizedFileURL.path()
    let homePath = home.standardizedFileURL.path()
    if normalized == homePath || normalized == "/" { return false }
    return true
  }

  /// `!AbCd:correspondance.local` → `AbCd-correspondance.local`. Un identifiant
  /// de room contient `!`, `:` et parfois `/` : rien de tout ça dans un chemin.
  static func sanitize(_ component: String) -> String {
    let cleaned = component.map { character -> Character in
      character.isLetter || character.isNumber || character == "." || character == "-" || character == "_"
        ? character : "-"
    }
    let text = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
    return text.isEmpty ? "sans-nom" : text
  }

  /// Crée le dossier s'il manque, en `0700` — personne d'autre sur la machine.
  @discardableResult
  public static func prepare(_ path: String) -> String {
    try? FileManager.default.createDirectory(
      at: URL(fileURLWithPath: path),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    return path
  }
}
