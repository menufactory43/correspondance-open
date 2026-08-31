import Foundation
import Security

/// Session Matrix persistée. Le token vit dans le Trousseau, jamais dans UserDefaults.
public struct MatrixCredentials: Codable, Hashable, Sendable {
  public var homeserver: URL
  public var userID: String
  public var accessToken: String
  public var deviceID: String?

  /// `correspondance.local` extrait de `@meffysto:correspondance.local`.
  public var serverName: String {
    guard let colon = userID.lastIndex(of: ":") else { return "" }
    return String(userID[userID.index(after: colon)...])
  }

  public var localpart: String {
    let withoutSigil = userID.hasPrefix("@") ? String(userID.dropFirst()) : userID
    return String(withoutSigil.prefix { $0 != ":" })
  }

  public init(homeserver: URL, userID: String, accessToken: String, deviceID: String? = nil) {
    self.homeserver = homeserver
    self.userID = userID
    self.accessToken = accessToken
    self.deviceID = deviceID
  }
}

/// Stockage Trousseau (un seul compte pour l'instant).
public enum MatrixCredentialStore {
  private static let service = "app.correspondance.matrix"
  private static let account = "default"

  /// Groupe d'accès du Trousseau, quand la session doit être lisible par une
  /// **autre** cible du même compte — sur iPhone, l'extension de notification,
  /// qui va chercher l'événement que le push lui a nommé.
  ///
  /// `nil` sur le Mac : rien à partager, et un groupe d'accès y changerait la
  /// requête du Trousseau, donc la session déjà enregistrée.
  ///
  /// Posé une seule fois au lancement, avant tout appel Matrix — d'où
  /// `nonisolated(unsafe)` : c'est une constante de configuration déguisée en
  /// variable, pas un état qui circule.
  public nonisolated(unsafe) static var accessGroup: String?

  private static func query(includeAccessGroup: Bool = true) -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    if includeAccessGroup, let accessGroup {
      query[kSecAttrAccessGroup as String] = accessGroup
    }
    return query
  }

  public static func load() -> MatrixCredentials? {
    // Le groupe partagé d'abord, le Trousseau nu ensuite : une session écrite
    // par une version antérieure (sans groupe) doit continuer d'ouvrir l'app.
    for shared in [true, false] where shared || accessGroup != nil {
      var attributes = query(includeAccessGroup: shared)
      attributes[kSecReturnData as String] = true
      attributes[kSecMatchLimit as String] = kSecMatchLimitOne
      var item: CFTypeRef?
      guard SecItemCopyMatching(attributes as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data,
            let credentials = try? JSONDecoder().decode(MatrixCredentials.self, from: data)
      else { continue }
      return credentials
    }
    return nil
  }

  @discardableResult
  public static func save(_ credentials: MatrixCredentials) -> Bool {
    guard let data = try? JSONEncoder().encode(credentials) else { return false }
    if write(data, includeAccessGroup: true) { return true }
    // Un groupe d'accès refusé (build non signée, simulateur sans droits) ne
    // doit pas empêcher de se connecter : on retombe sur le Trousseau nu, et
    // c'est l'extension qui perdra la parole, pas l'app.
    guard accessGroup != nil else { return false }
    return write(data, includeAccessGroup: false)
  }

  private static func write(_ data: Data, includeAccessGroup: Bool) -> Bool {
    let base = query(includeAccessGroup: includeAccessGroup)
    // Écraser proprement : update s'il existe, add sinon.
    let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecSuccess { return true }
    var add = base
    add[kSecValueData as String] = data
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
  }

  public static func clear() {
    SecItemDelete(query(includeAccessGroup: true) as CFDictionary)
    if accessGroup != nil {
      SecItemDelete(query(includeAccessGroup: false) as CFDictionary)
    }
  }
}
