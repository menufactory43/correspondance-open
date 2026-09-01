import Foundation

/// Quelqu'un qu'on peut désigner d'un « @ » dans le fil ouvert.
public struct MentionCandidate: Identifiable, Hashable, Sendable {
  /// Clé de dédoublonnage : la même personne ne revient pas deux fois parce
  /// qu'elle parle sur deux réseaux d'un fil fusionné.
  public let id: String
  public let name: String
  /// Fil synthétique qui porte de quoi charger sa photo (cf. `ConversationAvatarView`).
  public let avatar: Conversation

  public init(id: String, name: String, avatar: Conversation) {
    self.id = id
    self.name = name
    self.avatar = avatar
  }
}

public extension Conversation {
  /// Un fil « stub » : juste ce qu'il faut à `ConversationAvatarStore` pour
  /// retrouver la photo d'une personne — l'adresse sur son réseau, et la photo
  /// distante quand le réseau l'expose lui-même (ghost Matrix).
  public static func avatarStub(
    network: MessageNetwork, address: String, title: String, remoteAvatarID: String? = nil
  ) -> Conversation {
    Conversation(
      id: "mention:\(network.rawValue):\(address)",
      network: network,
      address: address,
      title: title,
      preview: "",
      lastMessageAt: .distantPast,
      unreadCount: 0,
      isArchived: false,
      transportKey: "",
      isGroup: false,
      remoteAvatarID: remoteAvatarID
    )
  }
}
/// La mention en cours de frappe, et comment la compléter. Struct pure : le
/// composer ne connaît pas la position du curseur, on lit donc la fin du texte —
/// c'est là qu'on écrit dans l'immense majorité des cas.
public enum MentionParser {
  public struct Token: Equatable {
    /// Étendue « @requête » à remplacer, l'arobase comprise.
    public let range: Range<String.Index>
    public let query: String
  }

  /// Un « @ » en début de texte ou après un blanc, suivi de ce qu'on a tapé
  /// jusqu'au bout. Rien pour une adresse e-mail (`meffysto@…`), rien dès que
  /// la requête change de ligne, se termine par un blanc (la mention est posée)
  /// ou dépasse la longueur d'un nom.
  public static func activeToken(in text: String) -> Token? {
    guard let at = text.lastIndex(of: "@") else { return nil }
    if at > text.startIndex, !text[text.index(before: at)].isWhitespace { return nil }
    let query = String(text[text.index(after: at)...])
    guard !query.contains(where: \.isNewline), query.count <= 40,
          query.last?.isWhitespace != true
    else { return nil }
    return Token(range: at..<text.endIndex, query: query)
  }

  public static func fold(_ value: String) -> String {
    value
      .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
      .trimmingCharacters(in: .whitespaces)
  }

  /// Les candidats qui répondent à la requête : préfixe du nom entier, ou d'un
  /// de ses mots (« pau » trouve « Hugo Pauline »). Sans requête, tout le monde.
  public static func matches(_ candidates: [MentionCandidate], query: String) -> [MentionCandidate] {
    let needle = fold(query)
    guard !needle.isEmpty else { return candidates }
    return candidates.filter { candidate in
      let name = fold(candidate.name)
      if name.hasPrefix(needle) { return true }
      return name.split(whereSeparator: \.isWhitespace).contains { $0.hasPrefix(needle) }
    }
  }

  /// Remplace la mention en cours par « @Nom », suivi d'une espace pour
  /// reprendre la phrase.
  public static func insert(_ candidate: MentionCandidate, replacing token: Token, in text: String) -> String {
    text.replacingCharacters(in: token.range, with: "@\(candidate.name) ")
  }
}

/// LES MENTIONS POSÉES, une fois le nom choisi. Le composer écrit « @Nom » en
/// texte nu — c'est ce que tous les réseaux transportent — mais rien ne le
/// distinguait ensuite de la phrase autour : ni dans le champ, ni dans la bulle.
///
/// On relit donc le texte avec la liste des gens du fil : ce qui suit un « @ »
/// et qui porte le nom de quelqu'un est une mention, et prend l'encre.
public enum MentionHighlight {
  /// Les plages « @Nom » d'un texte, l'arobase comprise. Le nom le plus long
  /// d'abord : dans un fil où vivent « Marie » et « Marie Claire »,
  /// « @Marie Claire » ne se coupe pas en deux.
  public static func ranges(in text: String, names: [String]) -> [Range<String.Index>] {
    guard text.contains("@") else { return [] }
    let sorted = names
      .filter { !MentionParser.fold($0).isEmpty }
      .sorted { $0.count > $1.count }
    guard !sorted.isEmpty else { return [] }

    var found: [Range<String.Index>] = []
    var cursor = text.startIndex
    while let at = text[cursor...].firstIndex(of: "@") {
      cursor = text.index(after: at)
      // La même règle qu'à la frappe : un « @ » collé à un mot est une adresse
      // e-mail, pas une mention.
      guard at == text.startIndex || text[text.index(before: at)].isWhitespace else { continue }
      let rest = text[cursor...]
      guard let name = sorted.first(where: { starts(rest, with: $0) }) else { continue }
      let end = text.index(cursor, offsetBy: name.count)
      found.append(at..<end)
      cursor = end
    }
    return found
  }

  /// Le nom entier, et rien de plus : « @Paul » ne prend pas le « ine » de
  /// « @Pauline ». Casse et accents ignorés, comme le filtre du menu.
  private static func starts(_ rest: Substring, with name: String) -> Bool {
    guard rest.count >= name.count else { return false }
    let end = rest.index(rest.startIndex, offsetBy: name.count)
    guard MentionParser.fold(String(rest[..<end])) == MentionParser.fold(name) else { return false }
    if end < rest.endIndex, rest[end].isLetter || rest[end].isNumber { return false }
    return true
  }
}
