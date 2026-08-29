import Foundation

/// Recherche de l'inbox : pure, sans dépendance, sans index sur disque.
///
/// Le champ cherche dans le titre, l'adresse réseau, l'aperçu **et** le corps des
/// messages connus (`index`). La comparaison ignore la casse et les diacritiques :
/// « eleonore » trouve « Éléonore », « ca va » trouve « ça va ».
enum ConversationSearch {
  /// Forme comparable d'une chaîne : minuscules, sans accents, espaces normalisés.
  static func fold(_ raw: String) -> String {
    raw.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Tous les mots de la requête doivent être trouvés (ET), dans n'importe quel champ.
  /// « marie resto » trouve le fil « Marie » dont un message parle de restaurant.
  static func matches(_ conversation: Conversation, query: String, messageBlob: String?) -> Bool {
    let terms = fold(query).split(separator: " ").map(String.init).filter { !$0.isEmpty }
    guard !terms.isEmpty else { return true }
    let haystack = [
      fold(conversation.title),
      fold(conversation.address),
      fold(conversation.preview),
      // Les adresses des participants : le numéro d'un fil replié sous une
      // ligne fusionnée n'apparaît nulle part ailleurs.
      fold(conversation.participantHandles.joined(separator: " ")),
      messageBlob ?? "",
    ].joined(separator: "\n")
    return terms.allSatisfy { haystack.contains($0) }
  }

  /// `index` associe un identifiant de conversation au corps replié de ses messages.
  static func filter(
    _ conversations: [Conversation],
    query: String,
    index: [String: String]
  ) -> [Conversation] {
    guard !fold(query).isEmpty else { return conversations }
    return conversations.filter { matches($0, query: query, messageBlob: index[$0.id]) }
  }

  /// Corps replié d'une conversation, prêt pour l'index.
  ///
  /// Le nom de l'auteur y entre AVEC le texte : depuis qu'il ne se colle plus
  /// dans le corps du message, chercher « vince » ne trouverait plus rien de ce
  /// qu'il a écrit. La recherche du fil (⌘F), elle, reste sur le seul corps —
  /// elle surligne ce qu'elle trouve, et un nom n'est pas dans la bulle.
  static func blob(for messages: [ChatMessage]) -> String {
    fold(messages.map { [$0.senderName, $0.text].compactMap { $0 }.joined(separator: " ") }
      .joined(separator: "\n"))
  }

  // MARK: - Recherche dans le fil (⌘F)

  /// Identifiants des messages contenant la requête, dans l'ordre du fil.
  static func matchingMessageIDs(in messages: [ChatMessage], query: String) -> [String] {
    let needle = fold(query)
    guard !needle.isEmpty else { return [] }
    return messages.filter { fold($0.text).contains(needle) }.map(\.id)
  }

  /// Plages à surligner dans un texte, pour la requête donnée.
  /// Travaille sur le texte replié puis reporte les positions sur l'original :
  /// `folding` conserve le nombre de caractères pour les accents latins.
  static func highlightRanges(in text: String, query: String) -> [Range<String.Index>] {
    let needle = fold(query)
    guard !needle.isEmpty, !text.isEmpty else { return [] }
    let folded = fold(text)
    guard folded.count == text.count else {
      // Repli prudent : un repli qui change la longueur (ligatures, largeur) rendrait
      // les positions fausses — on cherche alors directement, sans accents ignorés.
      return directRanges(in: text, needle: query)
    }
    var ranges: [Range<String.Index>] = []
    var cursor = folded.startIndex
    while let found = folded.range(of: needle, range: cursor..<folded.endIndex) {
      let lower = text.index(text.startIndex, offsetBy: folded.distance(from: folded.startIndex, to: found.lowerBound))
      let upper = text.index(text.startIndex, offsetBy: folded.distance(from: folded.startIndex, to: found.upperBound))
      ranges.append(lower..<upper)
      cursor = found.upperBound
    }
    return ranges
  }

  private static func directRanges(in text: String, needle: String) -> [Range<String.Index>] {
    var ranges: [Range<String.Index>] = []
    var cursor = text.startIndex
    while let found = text.range(of: needle, options: [.caseInsensitive], range: cursor..<text.endIndex) {
      ranges.append(found)
      cursor = found.upperBound
    }
    return ranges
  }
}
