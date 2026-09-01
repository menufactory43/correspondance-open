import Foundation
import Security

/// Le mot de passe Matrix d'un agent, au Trousseau.
///
/// L'app le génère à l'activation et l'écrit deux fois : ici, pour pouvoir le
/// remontrer ou le reposer, et dans l'amorce de l'agent sur sa machine (en
/// `0600`). Il ne passe **jamais** par une room : le Relais garderait en clair,
/// dans sa base, de quoi se faire passer pour l'agent.
public enum AgentSecretStore {
  private static let service = "app.correspondance.agent"

  private static func query(agent: String) -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: agent,
    ]
    if let group = MatrixCredentialStore.accessGroup {
      query[kSecAttrAccessGroup as String] = group
    }
    return query
  }

  public static func password(for agent: String) -> String? {
    var request = query(agent: agent)
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
          let data = item as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  @discardableResult
  public static func save(password: String, for agent: String) -> Bool {
    let data = Data(password.utf8)
    let base = query(agent: agent)
    let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecSuccess { return true }
    var insert = base
    insert[kSecValueData as String] = data
    insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
  }

  public static func clear(agent: String) {
    SecItemDelete(query(agent: agent) as CFDictionary)
  }

  /// Un mot de passe qu'aucun humain n'aura à taper : long, tiré au hasard du
  /// générateur du système. Pas de mot mémorisable — personne ne le mémorise.
  public static func generatePassword(length: Int = 32) -> String {
    let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    var bytes = [UInt8](repeating: 0, count: length)
    if SecRandomCopyBytes(kSecRandomDefault, length, &bytes) != errSecSuccess {
      // Le générateur du système a refusé : on ne fabrique pas un secret
      // approximatif, on prend celui de Swift, qui est cryptographique aussi.
      return String((0..<length).map { _ in alphabet.randomElement()! })
    }
    return String(bytes.map { alphabet[Int($0) % alphabet.count] })
  }
}
