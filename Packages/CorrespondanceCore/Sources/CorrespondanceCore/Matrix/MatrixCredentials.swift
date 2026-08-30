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

  public static func load() -> MatrixCredentials? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let data = item as? Data
    else { return nil }
    return try? JSONDecoder().decode(MatrixCredentials.self, from: data)
  }

  @discardableResult
  public static func save(_ credentials: MatrixCredentials) -> Bool {
    guard let data = try? JSONEncoder().encode(credentials) else { return false }
    let base: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    // Écraser proprement : update s'il existe, add sinon.
    let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecSuccess { return true }
    var add = base
    add[kSecValueData as String] = data
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
  }

  public static func clear() {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(query as CFDictionary)
  }
}
