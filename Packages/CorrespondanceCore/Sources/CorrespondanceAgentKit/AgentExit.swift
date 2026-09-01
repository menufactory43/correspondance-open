import CorrespondanceMatrixClient
import Foundation

/// Comment l'agent quitte, et ce que ça veut dire pour qui le surveille.
///
/// Une chute n'est pas une chute : un moteur qui plante mérite qu'on relance,
/// un mot de passe refusé par le Relais ne se répare pas tout seul. Le
/// surveillant a besoin de la différence, et un code de sortie est la seule
/// chose qu'un processus mourant peut encore dire.
public enum AgentExit {
  /// Fin normale.
  public static let normal: Int32 = 0
  /// Une erreur ordinaire : on relance.
  public static let erreur: Int32 = 1
  /// **Les identifiants sont refusés.** Relancer huit fois n'y changera rien —
  /// le compte n'existe pas, ou son mot de passe n'est plus celui de l'amorce.
  /// `EX_CONFIG` de `sysexits.h` : une erreur de configuration, ce que c'est
  /// exactement.
  public static let identifiantsRefuses: Int32 = 78
  /// Un autre agent tourne déjà sur ce compte. Même raisonnement : deux agents
  /// répondraient deux fois, et relancer ne ferait qu'insister.
  public static let dejaEnCours: Int32 = 79

  /// Ce refus vient-il du Relais, ou du réseau ? Un `401`/`403` est une
  /// décision du serveur ; un `timeout` est une panne, et une panne se
  /// réessaie.
  public static func code(for error: Error) -> Int32 {
    if let agent = error as? AgentError, case .dejaEnCours = agent { return dejaEnCours }
    guard let matrix = error as? MatrixError else { return erreur }
    switch matrix {
    case .http(let status, let errcode, _):
      let refus = status == 401 || status == 403
        || errcode == "M_FORBIDDEN" || errcode == "M_USER_DEACTIVATED"
        || errcode == "M_INVALID_USERNAME" || errcode == "M_UNKNOWN_TOKEN"
      return refus ? identifiantsRefuses : erreur
    default:
      return erreur
    }
  }

  /// Ce qu'on dit à l'utilisateur, par code. `nil` : rien de particulier, on
  /// relance comme d'habitude.
  public static func raisonFR(_ code: Int32) -> String? {
    switch code {
    case identifiantsRefuses:
      "identifiants refusés par le Relais — le compte de cc n'existe plus, "
        + "ou son mot de passe a changé. « Réinstaller » le recrée."
    case dejaEnCours:
      "un autre agent tourne déjà sur ce compte — deux agents répondraient deux fois."
    default:
      nil
    }
  }

  /// Faut-il relancer après cette sortie ? Non pour ce qui ne se répare pas
  /// tout seul : insister ne fait que remplir un journal.
  public static func shouldRestart(after code: Int32) -> Bool {
    code != identifiantsRefuses && code != dejaEnCours
  }
}
