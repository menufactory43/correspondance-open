import Foundation

/// Quand un message mérite le geste d'arrivée (l'encre, la plume).
///
/// Un message qui vient d'être écrit arrive ; un message d'hier découvert en
/// ouvrant le fil est déjà vu, il paraît posé. La coupure se fait sur l'heure
/// d'envoi : le fil n'a pas à se souvenir de tout ce qu'il a montré, et un
/// chargement qui complète un fil ne réveille rien.
public enum MessageArrivalPolicy {
  /// Passé ce délai après l'envoi, un message n'est plus « nouveau ».
  public static let freshWindow: TimeInterval = 120

  public static func isNewArrival(sentAt: Date, now: Date = Date()) -> Bool {
    let age = now.timeIntervalSince(sentAt)
    // Une horloge en avance (message daté dans le futur) compte comme « à l'instant ».
    return age < freshWindow
  }
}
