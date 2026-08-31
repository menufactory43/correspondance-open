import Foundation

/// Un rappel : une conversation mise de côté jusqu'à une heure donnée.
///
/// Elle sort de la file, et y revient à cette heure — ou plus tôt si la
/// personne d'en face a répondu entre-temps. C'est tout le contrat, et il
/// tient dans `isAsleep` : rien ici ne dort, rien ne se réveille tout seul,
/// c'est l'horloge de l'appelant qui décide (une fonction pure se teste).
///
/// L'état vit dans le Relais comme le reste (ADR 0001) : account data de
/// salon `fr.correspondance.reminder`. Un rappel posé sur le Mac attend donc
/// l'iPhone, et un rappel échu se lève sur les deux à la fois.
public struct ConversationReminder: Codable, Sendable, Equatable, Hashable {
  /// L'heure à laquelle la conversation revient dans la file.
  public var wakeAt: Date
  /// Quand le rappel a été posé. Sert de repère : un message arrivé APRÈS
  /// réveille la conversation sans attendre l'heure dite.
  public var setAt: Date

  public init(wakeAt: Date, setAt: Date = Date()) {
    self.wakeAt = wakeAt
    self.setAt = setAt
  }

  /// La conversation est-elle encore de côté ?
  ///
  /// Deux façons d'en sortir : l'heure est venue, ou quelqu'un a parlé depuis
  /// qu'on l'a rangée. Un message de MOI ne réveille rien — poser un rappel
  /// puis écrire un mot, c'est toujours attendre la réponse.
  public func isAsleep(now: Date, lastMessageAt: Date, lastMessageIsFromMe: Bool) -> Bool {
    if now >= wakeAt { return false }
    if !lastMessageIsFromMe, lastMessageAt > setAt { return false }
    return true
  }

  /// Un rappel qui n'a plus rien à retenir : l'heure est passée. On peut alors
  /// l'effacer du Relais plutôt que d'y laisser traîner une date morte.
  public func isElapsed(now: Date) -> Bool { now >= wakeAt }

  /// « Demain matin », « jeudi à 14 h » — la même plume que « Envoyer plus tard ».
  public func labelFR(now: Date = Date(), calendar: Calendar = .current) -> String {
    SendLaterTime.label(for: wakeAt, now: now, calendar: calendar)
  }

  /// Les heures proposées quand on met une conversation de côté. Ce sont celles
  /// de « Envoyer plus tard » : les mêmes mots pour la même question.
  public static func suggestions(now: Date = Date(), calendar: Calendar = .current) -> [SendLaterTime.Suggestion] {
    SendLaterTime.suggestions(now: now, calendar: calendar)
  }
}
