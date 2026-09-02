import Foundation

/// **Par où** l'app joint le Relais que ce code d'appairage décrit.
///
/// La question n'est pas cosmétique : les trois chemins n'ont pas les mêmes
/// conséquences pour qui lit l'écran. Tailcat ne demande rien à personne ;
/// Tailscale demande un compte et une extension système, et c'est le seul que
/// l'iPhone sache prendre ; une adresse locale ne marche que depuis la machine
/// du Relais. La feuille du code d'appairage le dit donc **avant** de se
/// connecter, pendant qu'on peut encore refuser.
///
/// Se calcule sur le code seul — aucun réseau, aucun processus — pour que ce
/// soit éprouvable et instantané.
public enum CheminDuRelais: Equatable, Sendable {
  /// Le code porte un jeton Tailcat : WireGuard, sans compte et sans tunnel ssh.
  case tailcat
  /// L'adresse du code est celle d'un tailnet (`100.x.y.z`, ou un `*.ts.net`).
  case tailscale
  /// Le Relais est sur cette machine-ci.
  case memeMachine
  /// Une adresse ordinaire : elle ne vaut que depuis un réseau qui la joint.
  case adresse

  public init(code: RelayPairingCode) {
    if code.tailcat?.isEmpty == false {
      self = .tailcat
      return
    }
    let hote = code.homeserver.host()?.lowercased() ?? ""
    if hote == "127.0.0.1" || hote == "localhost" || hote == "::1" {
      self = .memeMachine
    } else if hote.hasSuffix(".ts.net") || Self.estAdresseDeTailnet(hote) {
      self = .tailscale
    } else {
      self = .adresse
    }
  }

  /// Le CGNAT `100.64.0.0/10` que Tailscale distribue. On vérifie les **deux**
  /// bornes du second octet : `100.200.1.1` est une adresse publique ordinaire,
  /// et la ranger dans un tailnet ferait dire à l'écran une chose fausse.
  static func estAdresseDeTailnet(_ hote: String) -> Bool {
    let morceaux = hote.split(separator: ".")
    guard morceaux.count == 4, morceaux[0] == "100",
          let second = Int(morceaux[1]), (64...127).contains(second),
          morceaux.allSatisfy({ Int($0) != nil })
    else { return false }
    return true
  }

  /// Ce qui s'affiche à côté du code, en une ligne.
  public var titreFR: String {
    switch self {
    case .tailcat: "via Tailcat"
    case .tailscale: "via Tailscale"
    case .memeMachine: "sur cette machine"
    case .adresse: "par son adresse"
    }
  }

  /// Et la phrase qui dit ce que ça coûte à qui lit.
  public var detailFR: String {
    switch self {
    case .tailcat:
      "Ce Mac rejoint le Relais directement, sans Tailscale. L’iPhone, lui, en a encore besoin."
    case .tailscale:
      "Il faut Tailscale sur ce Mac et sur l’iPhone."
    case .memeMachine:
      "Le Relais est sur cette machine."
    case .adresse:
      "Cette adresse ne marche que depuis le réseau du Relais."
    }
  }
}

extension RelayPairingCode {
  /// Par où ce code se joint. Le mot « chemin » plutôt que « transport » :
  /// c'est ce que l'écran montre, pas une couche.
  public var chemin: CheminDuRelais { CheminDuRelais(code: self) }
}
