import CorrespondanceMatrixClient
import Foundation

/// Le **code d'appairage** d'un Relais : ce que l'installeur affiche à la fin,
/// et que l'app lit pour se connecter.
///
/// C'est lui qui fait le « un clic » — pas l'absence de terminal, mais
/// l'absence de *recopie* : ni URL à retaper, ni mot de passe à dicter, ni
/// port à deviner.
///
/// Deux formes pour la même chose :
/// - le **jeton** (QR, ou copier-coller) : il porte tout ;
/// - l'**empreinte en six mots** : elle ne porte rien, elle *vérifie*. On la
///   lit à voix haute pour s'assurer qu'on appaire bien le Relais qu'on vient
///   d'installer, et pas celui qu'un presse-papiers traînait.
public struct RelayPairingCode: Sendable, Equatable {
  public static let currentVersion = 1
  /// Un quart d'heure : le temps de passer d'un terminal à une app.
  public static let lifetime: TimeInterval = 900

  public var version: Int
  /// L'adresse par laquelle les clients joignent le Relais.
  public var homeserver: URL
  /// Le nom du serveur Matrix (`correspondance.local`) — il ne se déduit pas
  /// toujours de l'URL, et l'app en a besoin pour former les identifiants.
  public var serverName: String
  public var user: String
  public var password: String
  public var expiresAt: Date

  public init(
    homeserver: URL, serverName: String, user: String, password: String,
    expiresAt: Date = Date().addingTimeInterval(RelayPairingCode.lifetime),
    version: Int = RelayPairingCode.currentVersion
  ) {
    self.homeserver = homeserver
    self.serverName = serverName
    self.user = user
    self.password = password
    self.expiresAt = expiresAt
    self.version = version
  }

  public func isExpired(now: Date = Date()) -> Bool { now >= expiresAt }

  public var userID: String { user.hasPrefix("@") ? user : "@\(user):\(serverName)" }

  // MARK: - Le jeton

  public func encoded() -> String {
    let json: MatrixJSON = .object([
      "v": .number(Double(version)),
      "homeserver": .string(homeserver.absoluteString),
      "server": .string(serverName),
      "user": .string(user),
      "password": .string(password),
      "exp": .number(expiresAt.timeIntervalSince1970),
    ])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
    guard let data = try? encoder.encode(json) else { return "" }
    return "correspondance://relais/" + data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  public init?(encoded code: String) {
    let prefixe = "correspondance://relais/"
    var corps = code.trimmingCharacters(in: .whitespacesAndNewlines)
    if corps.hasPrefix(prefixe) { corps = String(corps.dropFirst(prefixe.count)) }
    var base64 = corps
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    while base64.count % 4 != 0 { base64 += "=" }
    guard let data = Data(base64Encoded: base64),
          let json = try? JSONDecoder().decode(MatrixJSON.self, from: data),
          let homeserver = json["homeserver"]?.stringValue.flatMap(URL.init(string:)),
          let server = json["server"]?.stringValue,
          let user = json["user"]?.stringValue,
          let password = json["password"]?.stringValue,
          let exp = json["exp"]?.doubleValue
    else { return nil }
    self.version = json["v"]?.intValue ?? 1
    self.homeserver = homeserver
    self.serverName = server
    self.user = user
    self.password = password
    self.expiresAt = Date(timeIntervalSince1970: exp)
  }

  // MARK: - L'empreinte

  /// Six mots qui nomment **le Relais**, pas le jeton. Ils ne transportent
  /// rien : ils répondent à « est-ce bien celui que je viens d'installer ? ».
  ///
  /// Ils se calculent donc sur l'identité du Relais — son adresse, son nom, son
  /// propriétaire — et **pas** sur la péremption ni le mot de passe : un code
  /// réémis cinq minutes plus tard doit donner les mêmes mots, sinon on ne peut
  /// rien comparer avec quelqu'un au téléphone.
  public func fingerprintWords() -> [String] {
    Self.words(of: "\(homeserver.absoluteString)|\(serverName)|\(userID)")
  }

  public static func words(of token: String) -> [String] {
    // Un condensé simple et stable — pas de dépendance à CryptoKit, qui
    // n'existe pas partout où ce code compile.
    var hash: UInt64 = 1_469_598_103_934_665_603
    for byte in Array(token.utf8) {
      hash ^= UInt64(byte)
      hash = hash &* 1_099_511_628_211
    }
    var mots: [String] = []
    var reste = hash
    for _ in 0..<6 {
      mots.append(lexicon[Int(reste % UInt64(lexicon.count))])
      reste = reste / UInt64(lexicon.count) &+ (reste &* 31)
    }
    return mots
  }

  /// Des mots courts, courants, sans homophone gênant : ils se lisent à voix
  /// haute au téléphone.
  static let lexicon = [
    "arbre", "banc", "cabane", "dune", "encre", "falaise", "givre", "halo",
    "iris", "jardin", "kiosque", "lampe", "marée", "neige", "olive", "pluie",
    "quai", "roseau", "sable", "tuile", "usine", "vague", "wagon", "zeste",
    "brume", "chêne", "digue", "étang", "flotte", "grange", "houle", "index",
  ]
}
