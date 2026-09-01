import Foundation

/// L'agent meurt avec l'app qui l'a lancé — **quelle que soit la façon dont
/// elle meurt**.
///
/// `applicationWillTerminate` ne couvre que la fermeture propre, c'est-à-dire
/// le seul cas où on n'a besoin de personne. Éprouvé au prix fort : un `pkill`
/// sur l'app a laissé l'agent vivant, connecté au Relais, prêt à répondre au
/// nom de son propriétaire — et relancer l'app donnait aussitôt **deux agents
/// sur le même compte**, le risque « deux réponses » que le plan nomme depuis
/// le premier jour.
///
/// ## Pourquoi `getppid()` plutôt qu'un tube hérité
///
/// Le tube est plus immédiat (EOF au lieu d'un sondage), mais il passerait par
/// l'entrée standard de l'agent — or sous systemd ou en service, cette entrée
/// est `/dev/null`, qui rend EOF **tout de suite**. L'agent s'arrêterait au
/// démarrage sur le NUC. `getppid()` n'a pas cette ambiguïté : il ne dit
/// quelque chose que quand on lui a donné un parent à surveiller, et il ne
/// coûte qu'un appel système toutes les deux secondes.
///
/// Quand le parent meurt, le noyau réattribue l'enfant à `launchd` (pid 1, ou
/// un sous-reaper sous Linux) : le parent observé n'est donc plus celui qu'on
/// attendait, et c'est tout ce qu'on a besoin de savoir.
public enum ParentWatch {

  /// L'argument que l'app passe : `--watch-parent <pid>`. Explicite, parce
  /// qu'un agent lancé par systemd ne doit surveiller personne.
  public static let flag = "--watch-parent"

  public static func expectedParent(in arguments: [String]) -> pid_t? {
    for (index, argument) in arguments.enumerated() {
      if argument == flag, index + 1 < arguments.count {
        return Int32(arguments[index + 1])
      }
      if argument.hasPrefix("\(flag)=") {
        let valeur = argument.suffix(from: argument.index(argument.startIndex, offsetBy: flag.count + 1))
        return Int32(String(valeur))
      }
    }
    return nil
  }

  /// Le parent attendu est-il parti ? Pur, donc éprouvé.
  ///
  /// `0` n'est jamais un parent valable : on ne s'arrête pas sur une lecture
  /// aberrante, on continue de tourner.
  public static func isOrphan(expected: pid_t, current: pid_t) -> Bool {
    guard expected > 0, current > 0 else { return false }
    return current != expected
  }

  /// Surveille, et appelle `onOrphan` quand le parent a disparu.
  ///
  /// `currentParent` est injectable pour les tests : la mécanique s'éprouve
  /// sans tuer de processus.
  public static func watch(
    expected: pid_t,
    interval: Duration = .seconds(2),
    currentParent: @escaping @Sendable () -> pid_t = { getppid() },
    onOrphan: @escaping @Sendable () -> Void
  ) -> Task<Void, Never> {
    Task.detached {
      while !Task.isCancelled {
        if isOrphan(expected: expected, current: currentParent()) {
          onOrphan()
          return
        }
        try? await Task.sleep(for: interval)
      }
    }
  }
}
