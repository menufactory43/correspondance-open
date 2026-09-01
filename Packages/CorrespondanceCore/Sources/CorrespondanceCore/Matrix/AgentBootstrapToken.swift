import CorrespondanceMatrixClient
import Foundation

/// Le jeton d'amorce : ce qu'on colle dans un terminal pour installer l'agent
/// sur une autre machine.
///
/// **Il porte l'amorce, il ne la va pas la chercher.** L'app ne lance aucun
/// serveur (décision du chantier R), il n'y a donc personne pour servir un
/// secret contre un jeton : le jeton *est* le secret, encodé. C'est ce qui rend
/// l'installation possible en une commande, et ça a deux conséquences qu'il
/// faut dire plutôt que taire :
///
/// - **il contient un mot de passe** : il se colle dans un terminal, pas dans
///   une conversation, et il traîne ensuite dans l'historique du shell ;
/// - **l'usage unique n'est pas vérifiable de notre côté** — sans serveur, rien
///   ne peut « consommer » un jeton. On lui donne donc une **date de péremption
///   courte**, que l'installeur refuse de dépasser, et l'app propose de
///   régénérer le mot de passe du bot si le jeton a fuité.
public struct AgentBootstrapToken: Sendable, Equatable {
  /// La version du format — l'installeur refuse ce qu'il ne sait pas lire.
  public static let currentVersion = 1
  /// Dix minutes : le temps de coller une commande, pas celui d'oublier un
  /// secret dans un presse-papiers.
  public static let lifetime: TimeInterval = 600

  public var version: Int
  public var homeserver: URL
  public var user: String
  public var password: String
  public var owner: String
  public var expiresAt: Date

  public init(
    homeserver: URL, user: String, password: String, owner: String,
    expiresAt: Date = Date().addingTimeInterval(AgentBootstrapToken.lifetime),
    version: Int = AgentBootstrapToken.currentVersion
  ) {
    self.homeserver = homeserver
    self.user = user
    self.password = password
    self.owner = owner
    self.expiresAt = expiresAt
    self.version = version
  }

  public init(bootstrap: MatrixBridgeService.AgentBootstrap, now: Date = Date()) {
    self.init(
      homeserver: bootstrap.homeserver, user: bootstrap.user, password: bootstrap.password,
      owner: bootstrap.owner, expiresAt: now.addingTimeInterval(Self.lifetime)
    )
  }

  public func isExpired(now: Date = Date()) -> Bool { now >= expiresAt }

  // MARK: - Encodage

  /// Base64 sans caractère qui casse une ligne de commande (`+`, `/`, `=`) :
  /// un jeton se colle, il ne se met pas entre guillemets.
  public func encoded() -> String {
    let json: MatrixJSON = .object([
      "v": .number(Double(version)),
      "homeserver": .string(homeserver.absoluteString),
      "user": .string(user),
      "password": .string(password),
      "owner": .string(owner),
      "exp": .number(expiresAt.timeIntervalSince1970),
    ])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
    guard let data = try? encoder.encode(json) else { return "" }
    return data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  public init?(encoded token: String) {
    var base64 = token
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    while base64.count % 4 != 0 { base64 += "=" }
    guard let data = Data(base64Encoded: base64),
          let json = try? JSONDecoder().decode(MatrixJSON.self, from: data),
          let homeserver = json["homeserver"]?.stringValue.flatMap(URL.init(string:)),
          let user = json["user"]?.stringValue,
          let password = json["password"]?.stringValue,
          let owner = json["owner"]?.stringValue,
          let exp = json["exp"]?.doubleValue
    else { return nil }
    self.version = json["v"]?.intValue ?? 1
    self.homeserver = homeserver
    self.user = user
    self.password = password
    self.owner = owner
    self.expiresAt = Date(timeIntervalSince1970: exp)
  }

  /// La commande à coller sur l'hôte. Une seule ligne, un seul jeton.
  public func installCommand(
    installerURL: String = "https://correspondance.app/agent/install.sh"
  ) -> String {
    "curl -fsSL \(installerURL) | sh -s -- \(encoded())"
  }
}
