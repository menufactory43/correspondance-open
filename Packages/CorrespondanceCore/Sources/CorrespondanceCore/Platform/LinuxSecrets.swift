#if !canImport(Security)
import Foundation

/// Le Trousseau, sous Linux : un seul fichier JSON dans le dossier de données,
/// à `0600`, que personne d'autre que l'utilisateur ne lit.
///
/// Pas de libsecret ni de portail D-Bus : ils dépendent d'un démon de session
/// (GNOME Keyring, KWallet) qui n'est pas toujours là — sur un serveur, dans
/// un conteneur, sous un gestionnaire de fenêtres minimal — et un binaire
/// statique ne peut pas s'y lier. Un fichier protégé par les droits POSIX
/// vaut ce que vaut le compte Unix, exactement comme `~/.ssh`.
///
/// Le fichier suit `CORRESPONDANCE_HOME` comme la base : un essai a ses
/// propres secrets, jamais ceux du vrai compte.
enum LinuxSecrets {
  private static let lock = NSLock()

  private static var url: URL { CorrespondanceHome.file("secrets.json") }

  static func read(_ key: String) -> Data? {
    lock.lock(); defer { lock.unlock() }
    return load()[key].flatMap { Data(base64Encoded: $0) }
  }

  @discardableResult
  static func write(_ key: String, _ data: Data) -> Bool {
    lock.lock(); defer { lock.unlock() }
    var all = load()
    all[key] = data.base64EncodedString()
    return save(all)
  }

  static func remove(_ key: String) {
    lock.lock(); defer { lock.unlock() }
    var all = load()
    all.removeValue(forKey: key)
    _ = save(all)
  }

  private static func load() -> [String: String] {
    guard let data = try? Data(contentsOf: url),
          let dict = try? JSONDecoder().decode([String: String].self, from: data)
    else { return [:] }
    return dict
  }

  private static func save(_ dict: [String: String]) -> Bool {
    guard let data = try? JSONEncoder().encode(dict) else { return false }
    do {
      try data.write(to: url, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      return true
    } catch { return false }
  }
}

/// La session Matrix de cet appareil — même façade que sur Apple.
public enum MatrixCredentialStore {
  public nonisolated(unsafe) static var accessGroup: String?
  private static var key: String { "matrix:" + CorrespondanceHome.keychainService() }

  public static func load() -> MatrixCredentials? {
    guard let data = LinuxSecrets.read(key) else { return nil }
    return try? JSONDecoder().decode(MatrixCredentials.self, from: data)
  }

  @discardableResult
  public static func save(_ credentials: MatrixCredentials) -> Bool {
    guard let data = try? JSONEncoder().encode(credentials) else { return false }
    return LinuxSecrets.write(key, data)
  }

  public static func clear() { LinuxSecrets.remove(key) }
}

/// Le mot de passe d'un agent, même façade que sur Apple.
public enum AgentSecretStore {
  private static func key(_ agent: String) -> String {
    "agent:" + agent + CorrespondanceHome.trialSuffix
  }

  public static func password(for agent: String) -> String? {
    LinuxSecrets.read(key(agent)).flatMap { String(data: $0, encoding: .utf8) }
  }

  @discardableResult
  public static func save(password: String, for agent: String) -> Bool {
    LinuxSecrets.write(key(agent), Data(password.utf8))
  }

  public static func clear(agent: String) { LinuxSecrets.remove(key(agent)) }

  public static func generatePassword(length: Int = 32) -> String {
    let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    return String((0..<length).map { _ in alphabet.randomElement()! })
  }
}

/// La phrase de récupération gardée sur cet appareil — même façade que le
/// magasin au Trousseau.
public struct MagasinDePhraseAuTrousseau: MagasinDePhrase {
  public init() {}
  private func key(_ compte: String) -> String { "phrase:" + compte + CorrespondanceHome.trialSuffix }
  public func lire(compte: String) -> String? {
    LinuxSecrets.read(key(compte)).flatMap { String(data: $0, encoding: .utf8) }
  }
  public func ecrire(_ phrase: String, compte: String) { LinuxSecrets.write(key(compte), Data(phrase.utf8)) }
  public func effacer(compte: String) { LinuxSecrets.remove(key(compte)) }
}
#endif
