import Foundation

/// LE MARKDOWN DES PONTS. Instagram, Messenger et WhatsApp livrent des corps
/// déjà balisés — `**gras**`, `[texte](adresse)` — et la bulle les montrait
/// tels quels : astérisques, crochets, adresse écrite deux fois.
///
/// Foundation sait les lire ; tout le travail est de savoir QUAND lui donner la
/// parole. Un message ordinaire ne doit pas changer d'un cheveu : ni le
/// `2 * 3` d'un calcul, ni le souligné d'une adresse `mon_site/a_b`, ni les
/// retours à la ligne — que le mode « inline en préservant les blancs » garde.
public enum InlineMarkdown {
  /// Le texte relu comme du Markdown, ou `nil` s'il n'en porte aucun marqueur
  /// (ou si Foundation refuse de le lire).
  public static func attributed(_ text: String) -> AttributedString? {
    guard hasMarker(text) else { return nil }
    return try? AttributedString(
      markdown: text,
      options: .init(
        allowsExtendedAttributes: true,
        interpretedSyntax: .inlineOnlyPreservingWhitespace,
        failurePolicy: .returnPartiallyParsedIfPossible
      )
    )
  }

  /// Un marqueur PAIRÉ, pas un caractère isolé. Sans cette exigence, une
  /// astérisque de multiplication ou le tiret bas d'une URL emportait la moitié
  /// du message dans une emphase qui n'existait pas.
  public static func hasMarker(_ text: String) -> Bool {
    markers.contains { text.range(of: $0, options: .regularExpression) != nil }
  }

  private static let markers = [
    #"\*\*[^*\n]+\*\*"#,
    #"~~[^~\n]+~~"#,
    "`[^`\n]+`",
    #"\[[^\]\n]+\]\([^)\s]+\)"#,
    // Emphase simple : le marqueur doit border un mot, jamais s'y coller —
    // c'est ce qui épargne `a_b_c` et `x * y * z`.
    #"(?<![\w*])\*[^*\s][^*\n]*\*(?![\w*])"#,
    #"(?<![\w_])_[^_\s][^_\n]*_(?![\w_])"#,
  ]
}
