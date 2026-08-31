import Foundation

/// Un sondage, tel que MSC3381 le décrit et que les ponts mautrix le relaient
/// (WhatsApp en fait, Instagram et Signal non — voir `MessageNetwork` plus bas).
///
/// Trois events, jamais un seul : `poll.start` pose la question, chaque
/// `poll.response` est une voix, `poll.end` ferme les votes et fige le résultat.
/// Le dépouillement est ici, pur : une voix par personne (la **dernière** qu'elle
/// a émise), les réponses qui n'existent pas ignorées, rien après la clôture.
public struct Poll: Hashable, Codable, Sendable {
  public struct Answer: Hashable, Identifiable, Codable, Sendable {
    public let id: String
    public let text: String

    public init(id: String, text: String) {
      self.id = id
      self.text = text
    }
  }

  /// Voit-on qui a voté quoi avant la clôture ?
  public enum Kind: String, Hashable, Codable, Sendable {
    /// Les résultats sont visibles au fil des votes.
    case disclosed
    /// Rien ne se voit avant la clôture — c'est un vote à bulletin secret.
    case undisclosed
  }

  public var question: String
  public var answers: [Answer]
  public var kind: Kind
  /// Nombre de réponses qu'une personne peut cocher. 1 dans l'immense majorité.
  public var maxSelections: Int
  /// Le sondage est clos : plus aucune voix ne compte.
  public var isClosed: Bool
  /// Les voix retenues, par personne : identifiants de réponses.
  public var votesByVoter: [String: [String]]
  /// Mes propres voix — ce que les cases cochées montrent.
  public var myAnswerIDs: [String]

  public init(
    question: String,
    answers: [Answer],
    kind: Kind = .disclosed,
    maxSelections: Int = 1,
    isClosed: Bool = false,
    votesByVoter: [String: [String]] = [:],
    myAnswerIDs: [String] = []
  ) {
    self.question = question
    self.answers = answers
    self.kind = kind
    self.maxSelections = maxSelections
    self.isClosed = isClosed
    self.votesByVoter = votesByVoter
    self.myAnswerIDs = myAnswerIDs
  }

  /// Le nombre de voix par réponse.
  public func count(of answerID: String) -> Int {
    votesByVoter.values.reduce(0) { $0 + ($1.contains(answerID) ? 1 : 0) }
  }

  /// Le nombre de personnes qui ont voté — pas le nombre de voix : avec
  /// plusieurs choix, une personne en pose plusieurs.
  public var voterCount: Int { votesByVoter.count }

  public var totalVotes: Int { votesByVoter.values.reduce(0) { $0 + $1.count } }

  /// La part d'une réponse, 0…1, pour la barre. Rapportée aux **voix**, pas aux
  /// personnes : sinon un sondage à choix multiples dépasserait les 100 %.
  public func fraction(of answerID: String) -> Double {
    guard totalVotes > 0 else { return 0 }
    return Double(count(of: answerID)) / Double(totalVotes)
  }

  /// Les résultats sont-ils montrables ? Un sondage secret ne dit rien avant
  /// sa clôture — l'afficher quand même trahirait ceux qui ont voté.
  public var showsResults: Bool { kind == .disclosed || isClosed }

  public func hasVoted(_ answerID: String) -> Bool { myAnswerIDs.contains(answerID) }

  /// Ce que devient ma sélection quand je touche une réponse. Un sondage à
  /// choix unique bascule ; à choix multiples, on coche et décoche, sans
  /// jamais dépasser `maxSelections` — la plus ancienne cède sa place.
  public func toggling(_ answerID: String) -> [String] {
    guard answers.contains(where: { $0.id == answerID }) else { return myAnswerIDs }
    if myAnswerIDs.contains(answerID) { return myAnswerIDs.filter { $0 != answerID } }
    guard maxSelections > 1 else { return [answerID] }
    var next = myAnswerIDs + [answerID]
    if next.count > maxSelections { next.removeFirst(next.count - maxSelections) }
    return next
  }

  /// « 3 votes · 2 personnes », ou le silence avant les résultats.
  public func summaryFR() -> String {
    guard showsResults else { return isClosed ? "Sondage clos" : "Résultats après la clôture" }
    let people = voterCount
    let suffix = isClosed ? " · clos" : ""
    switch people {
    case 0: return "Personne n'a encore voté" + suffix
    case 1: return "1 vote" + suffix
    default: return "\(people) votes" + suffix
    }
  }
}

/// Les types d'events MSC3381, forme stable et forme instable. mautrix pose
/// encore la seconde (v26.08) ; on lit les deux, et on écrit celle qu'on a lue
/// — répondre à un sondage instable avec un event stable ne compterait pas.
public enum PollEventTypes {
  public static let startStable = "m.poll.start"
  public static let startUnstable = "org.matrix.msc3381.poll.start"
  public static let responseStable = "m.poll.response"
  public static let responseUnstable = "org.matrix.msc3381.poll.response"
  public static let endStable = "m.poll.end"
  public static let endUnstable = "org.matrix.msc3381.poll.end"

  /// Le texte d'un morceau MSC1767, quelle qu'en soit la forme.
  public static let textStable = "m.text"
  public static let textUnstable = "org.matrix.msc1767.text"

  public static let starts = [startStable, startUnstable]
  public static let responses = [responseStable, responseUnstable]
  public static let ends = [endStable, endUnstable]

  public static func isStart(_ type: String) -> Bool { starts.contains(type) }
  public static func isResponse(_ type: String) -> Bool { responses.contains(type) }
  public static func isEnd(_ type: String) -> Bool { ends.contains(type) }

  /// La réponse à écrire pour un sondage lu sous telle forme.
  public static func responseType(forStart type: String) -> String {
    type == startStable ? responseStable : responseUnstable
  }
}
