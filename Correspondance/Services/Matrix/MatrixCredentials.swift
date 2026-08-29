import Foundation
import Security

/// Session Matrix persistée. Le token vit dans le Trousseau, jamais dans UserDefaults.
struct MatrixCredentials: Codable, Hashable, Sendable {
  var homeserver: URL
  var userID: String
  var accessToken: String
  var deviceID: String?

  /// `correspondance.local` extrait de `@meffysto:correspondance.local`.
  var serverName: String {
    guard let colon = userID.lastIndex(of: ":") else { return "" }
    return String(userID[userID.index(after: colon)...])
  }

  var localpart: String {
    let withoutSigil = userID.hasPrefix("@") ? String(userID.dropFirst()) : userID
    return String(withoutSigil.prefix { $0 != ":" })
  }
}

/// Stockage Trousseau (un seul compte pour l'instant).
enum MatrixCredentialStore {
  private static let service = "app.correspondance.matrix"
  private static let account = "default"

  static func load() -> MatrixCredentials? {
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
  static func save(_ credentials: MatrixCredentials) -> Bool {
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

  static func clear() {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(query as CFDictionary)
  }
}
