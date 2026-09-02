import Foundation

/// Où l'app range ses affaires — et comment en changer le temps d'un essai.
///
/// `CORRESPONDANCE_HOME` est le symétrique de `CORRESPONDANCE_AGENT_HOME`, qui
/// existe depuis longtemps pour l'agent. Elle déplace **d'un bloc** :
///
/// - le dossier de données (`~/Library/Application Support/Correspondance-<nom>`) :
///   la base, les brouillons, les contacts fusionnés, les messages programmés ;
/// - **et** l'entrée du Trousseau où vit la session Matrix.
///
/// Les deux ensemble, jamais l'un sans l'autre : déplacer la base sans déplacer
/// le Trousseau ferait écrire la session d'un Relais d'essai par-dessus la vraie
/// — c'est précisément l'accident qu'on veut rendre impossible.
///
/// **Absente, rien ne change.** Le dossier et le service du Trousseau sont
/// exactement ceux d'avant, au caractère près : c'est la seule propriété de ce
/// fichier qui ne se négocie pas, et elle est testée.
public enum CorrespondanceHome {
  /// Le nom du dossier de données quand aucun essai n'est en cours.
  public static let defaultFolder = "Correspondance"
  /// Le service du Trousseau, tel qu'il a toujours été.
  public static let defaultKeychainService = "app.correspondance.matrix"

  /// Le nom de l'essai en cours, s'il y en a un. Lu une fois : c'est une
  /// constante de configuration, pas un état qui bouge en cours de route.
  public static var name: String? {
    resolvedName(from: ProcessInfo.processInfo.environment)
  }

  /// Vrai quand l'app tourne sur un jeu de données d'essai. L'écran des
  /// réglages le dit — on ne laisse pas quelqu'un croire qu'il regarde ses
  /// vraies conversations.
  public static var isTrial: Bool { name != nil }

  public static func resolvedName(from environment: [String: String]) -> String? {
    guard let brut = environment["CORRESPONDANCE_HOME"] else { return nil }
    let propre = sanitize(brut)
    return propre.isEmpty ? nil : propre
  }

  /// Un nom d'essai ne fabrique pas de chemin. Même garde que `Workspace` côté
  /// agent : `../../` ne doit pas sortir d'Application Support.
  public static func sanitize(_ name: String) -> String {
    let nettoye = name.map { caractere -> Character in
      caractere.isLetter || caractere.isNumber || caractere == "-" || caractere == "_"
        ? caractere : "-"
    }
    return String(nettoye).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
  }

  /// Le nom du dossier de données, avec ou sans essai.
  public static func folderName(environment: [String: String] = ProcessInfo.processInfo.environment)
    -> String
  {
    guard let name = resolvedName(from: environment) else { return defaultFolder }
    return "\(defaultFolder)-\(name)"
  }

  /// Le suffixe que **tout** ce qui vit au Trousseau doit porter pendant un
  /// essai. Un seul endroit : la session Matrix et le mot de passe de l'agent
  /// se sont déjà désynchronisés une fois, et l'app a écrit une amorce fausse.
  public static var trialSuffix: String {
    guard let name = resolvedName(from: ProcessInfo.processInfo.environment) else { return "" }
    return ".\(name)"
  }

  /// Le service du Trousseau. Suffixé pendant un essai : la vraie session reste
  /// où elle est, intacte, et on la retrouve en relançant sans la variable.
  public static func keychainService(environment: [String: String] = ProcessInfo.processInfo.environment)
    -> String
  {
    guard let name = resolvedName(from: environment) else { return defaultKeychainService }
    return "\(defaultKeychainService).\(name)"
  }

  /// Le dossier de données, créé au besoin. **Tout** ce qui passait par
  /// Application Support passe par ici — sans quoi un essai laisserait la
  /// moitié de ses traces dans les vraies données.
  /// `base` n'est donné que par les tests : on ne veut pas qu'ils dépendent du
  /// vrai Application Support de la machine, ni qu'ils y laissent des dossiers.
  public static func directory(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    base: URL? = nil,
    fileManager: FileManager = .default
  ) -> URL {
    let racine = base
      ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.temporaryDirectory
    let directory = racine.appendingPathComponent(folderName(environment: environment), isDirectory: true)
    try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  /// Un fichier dans le dossier de données.
  public static func file(_ name: String) -> URL {
    directory().appendingPathComponent(name)
  }
}
