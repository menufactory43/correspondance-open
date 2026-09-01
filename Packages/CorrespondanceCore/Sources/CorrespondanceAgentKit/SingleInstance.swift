import Foundation

/// **Au plus un agent vivant par compte.** Deux instances sur le même compte
/// Matrix, ce sont deux réponses à chaque message — le risque que le plan nomme
/// depuis le premier jour, et qu'un `pkill` sur l'app a rendu réel.
///
/// L'app le prévoyait de son côté (« refuser d'activer un hôte si un autre a
/// posté un status il y a moins de deux minutes »). Le faire **aussi** dans
/// l'agent est plus sûr : ça marche quand les deux lanceurs ne se connaissent
/// pas — un `systemctl start` sur le NUC ne sait rien d'un clic sur le Mac.
///
/// ## Le discriminant, et pourquoi il n'est pas qu'une fenêtre de temps
///
/// Une fenêtre seule ne distingue pas « un autre agent tourne » de « je viens
/// de redémarrer après une chute » — et bloquer un redémarrage légitime pendant
/// deux minutes ferait renoncer le surveillant de l'app. On regarde donc
/// **qui** a publié :
///
/// - **même machine** : le pid est vérifiable (`kill(pid, 0)`). Vivant → on
///   refuse ; mort → c'est notre propre cadavre, on démarre. C'est le cas d'un
///   redémarrage après crash, et il doit marcher.
/// - **autre machine** : on ne peut rien vérifier à distance, alors la fenêtre
///   de deux minutes tranche. Un status plus frais que ça vient d'un agent
///   qu'on doit croire vivant.
///
/// La réponse complète est un **bail** renouvelé dans la room console — c'est
/// l'invariant de Buzz, et c'est écrit comme suite dans `docs/AGENT.md`. Ce qui
/// suit est la version locale, moins chère et déjà juste dans les cas réels.
/// Ce qui empêche l'agent de démarrer.
public enum AgentError: Error, LocalizedError, Equatable {
  case dejaEnCours(String)

  public var errorDescription: String? {
    switch self {
    case .dejaEnCours(let raison): raison
    }
  }
}

public enum SingleInstance {

  /// Ce qu'un status raconte de l'agent qui l'a posté.
  public struct Sighting: Sendable, Equatable {
    public var host: String
    public var pid: Int32
    public var at: Date

    public init(host: String, pid: Int32, at: Date) {
      self.host = host
      self.pid = pid
      self.at = at
    }
  }

  /// Au-delà, un status venu d'une autre machine ne prouve plus rien.
  public static let fenetre: TimeInterval = 120

  public enum Verdict: Equatable, Sendable {
    case demarre
    case refuse(raison: String)
  }

  /// Faut-il démarrer ?
  ///
  /// - `sighting` : le status le plus récent trouvé sur le Relais, s'il y en a ;
  /// - `moi` : la machine et le pid de *cette* instance ;
  /// - `estVivant` : sonde locale de pid, injectable pour les tests.
  public static func verdict(
    sighting: Sighting?,
    moi: Sighting,
    maintenant: Date = Date(),
    estVivant: (Int32) -> Bool = { kill($0, 0) == 0 }
  ) -> Verdict {
    guard let sighting else { return .demarre }
    // Notre propre status d'un lancement précédent, sur cette machine : le pid
    // dit tout, et il n'y a pas à attendre.
    if sighting.host == moi.host {
      guard sighting.pid != moi.pid else { return .demarre }
      guard estVivant(sighting.pid) else { return .demarre }
      return .refuse(
        raison: "un autre agent tourne déjà sur cette machine (pid \(sighting.pid)). "
          + "Arrête-le, ou désactive-le depuis Réglages › Agent."
      )
    }
    // Une autre machine : on ne peut pas sonder son pid, alors on croit ce
    // qu'elle a dit récemment.
    let age = maintenant.timeIntervalSince(sighting.at)
    guard age < fenetre else { return .demarre }
    return .refuse(
      raison: "un agent tourne déjà sur « \(sighting.host) » (il s'est annoncé il y a "
        + "\(Int(age)) s). Deux agents sur le même compte répondraient deux fois."
    )
  }
}
