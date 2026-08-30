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
