import Foundation

/// La session Instagram telle que le pont l'attend, extraite d'un jeu de cookies.
///
/// Isolée de WebKit exprès : la vue de connexion récolte des `HTTPCookie`, mais la
/// question « cette session est-elle complète ? » et la mise en forme du JSON se
/// testent sans navigateur, et se relisent sans ouvrir une `NSViewRepresentable`.
///
/// Rien n'est journalisé ni conservé ici : la valeur ne fait que traverser l'app,
/// de la fenêtre de connexion au salon de gestion du pont.
public struct InstagramSessionCookies: Equatable, Sendable {
  /// Sans ces trois-là, la session n'existe pas encore : l'utilisateur est sur le
  /// formulaire, ou au milieu d'une 2FA. C'est ce trio qui déclenche l'envoi.
  public static let requiredNames: Set<String> = ["sessionid", "ds_user_id", "csrftoken"]

  /// Ce que le pont accepte en plus. `mid` et `ig_did` sont posés par instagram.com
  /// dès la première page ; `rur`, `shbid` et `shbts` n'arrivent pas partout, et le
  /// bot ne s'en formalise pas.
  public static let optionalNames: Set<String> = ["mid", "ig_did", "rur", "shbid", "shbts"]

  /// Uniquement les cookies que le pont sait lire, les autres sont écartés.
  public let values: [String: String]

  /// `nil` tant que la session n'est pas complète — appeler ne coûte rien, et évite
  /// à l'appelant de retenir la liste des clés.
  public init?(rawCookies: [String: String]) {
    var kept: [String: String] = [:]
    for (name, value) in rawCookies where !value.isEmpty {
      guard Self.requiredNames.contains(name) || Self.optionalNames.contains(name) else { continue }
      kept[name] = value
    }
    guard Self.requiredNames.isSubset(of: Set(kept.keys)) else { return nil }
    values = kept
  }

  /// Depuis le magasin de cookies du navigateur intégré. On ne garde que le domaine
  /// Instagram : un `csrftoken` d'un autre site n'a rien à faire dans la charge utile.
  public init?(httpCookies: [HTTPCookie]) {
    var raw: [String: String] = [:]
    for cookie in httpCookies where Self.isInstagramDomain(cookie.domain) {
      raw[cookie.name] = cookie.value
    }
    self.init(rawCookies: raw)
  }

  public static func isInstagramDomain(_ domain: String) -> Bool {
    let host = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
    return host == "instagram.com" || host.hasSuffix(".instagram.com")
  }

  /// L'objet JSON attendu par `mautrix-instagram`, clés triées pour être reproductible.
  public var jsonPayload: String {
    guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8)
    else { return "{}" }
    return text
  }
}
