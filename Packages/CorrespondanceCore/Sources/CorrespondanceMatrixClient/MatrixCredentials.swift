import Foundation

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
