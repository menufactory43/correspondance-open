import CorrespondanceMatrixClient
import Foundation

/// Le point du matin : à l'heure réglée (`heartbeat`, « 08:00 »), sans
/// message entrant, cc relit les salons où le dernier mot n'est pas au
/// propriétaire et dit, en une ligne chacun, ce qui attend une réponse.
///
/// Pas de cron : le service tourne déjà 24/7, une tâche qui dort jusqu'à
/// l'heure suffit. Ce fichier est la partie pure — quand, et quoi lire ; la
/// tâche elle-même est dans `Agent`.
public enum Heartbeat {
  /// L'instruction du point du matin. Les fils suivent, chacun comme bloc de
  /// données (`ContexteDuFil`).
  public static let prompt =
    "Fais le point du matin : pour chaque conversation ci-dessous, dis en une ligne "
      + "ce qui attend une réponse du propriétaire ; ignore le bruit."

  /// Au plus tant de salons dans un point, et tant de messages par salon.
  public static let maxRooms = 10
  public static let messagesParRoom = 20

  /// La prochaine fois que `heure` (« HH:mm ») sonne après `now`, dans ce
  /// fuseau : aujourd'hui si elle n'est pas passée, sinon demain. `nil` si
  /// l'heure est illisible — et alors pas de point, plutôt qu'un point à
  /// n'importe quelle heure.
  public static func prochaineOccurrence(de heure: String, apres now: Date, timeZone: TimeZone = .current) -> Date? {
    let parts = heure.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
          (0...23).contains(h), (0...59).contains(m)
    else { return nil }
    var calendrier = Calendar(identifier: .gregorian)
    calendrier.timeZone = timeZone
    guard let aujourdhui = calendrier.date(bySettingHour: h, minute: m, second: 0, of: now) else { return nil }
    if aujourdhui > now { return aujourdhui }
    return calendrier.date(byAdding: .day, value: 1, to: aujourdhui)
  }

  /// Un salon dont on parle dans le point. Les events viennent de `/messages`,
  /// dans n'importe quel ordre.
  public struct Salon: Sendable {
    public var roomID: String
    public var nom: String?
    public var events: [MatrixEvent]

    public init(roomID: String, nom: String?, events: [MatrixEvent]) {
      self.roomID = roomID
      self.nom = nom
      self.events = events
    }
  }

  /// Un salon **attend une réponse** si son dernier message n'est pas d'un
  /// propriétaire — ni de l'agent : ce qu'il a envoyé seul ne compte pas
  /// comme une réponse du propriétaire, mais ce n'est pas non plus une
  /// question qui attend.
  public static func attendUneReponse(_ salon: Salon, owners: Set<String>, moi: String) -> Bool {
    let dernier = salon.events
      .filter { $0.type == "m.room.message" || $0.type == "m.room.encrypted" }
      .max { $0.sentAt < $1.sentAt }
    guard let auteur = dernier?.sender else { return false }
    return !owners.contains(auteur) && auteur != moi
  }

  /// Le prompt entier du point : l'instruction, puis les salons qui attendent
  /// (au plus `maxRooms`, les plus récemment actifs d'abord), chacun encadré
  /// comme données. Vide s'il n'y a rien à dire — et alors pas de tour.
  public static func prompt(
    salons: [Salon], owners: Set<String>, moi: String,
    noms: [String: [String: String]], timeZone: TimeZone = .current
  ) -> String {
    let enAttente = salons
      .filter { attendUneReponse($0, owners: owners, moi: moi) }
      .sorted { ($0.events.map(\.sentAt).max() ?? .distantPast) > ($1.events.map(\.sentAt).max() ?? .distantPast) }
      .prefix(maxRooms)
    guard !enAttente.isEmpty else { return "" }
    let blocs = enAttente.map { salon -> String in
      let titre = salon.nom?.trimmingCharacters(in: .whitespacesAndNewlines)
      let entete = "Conversation « \((titre?.isEmpty == false ? titre : nil) ?? salon.roomID) » :\n"
      return entete + ContexteDuFil.section(
        events: Array(salon.events.suffix(messagesParRoom)), moi: moi,
        noms: noms[salon.roomID] ?? [:], exclure: [], timeZone: timeZone
      )
    }
    return prompt + "\n\n" + blocs.joined(separator: "\n")
  }
}
