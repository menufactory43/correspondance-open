import Foundation

/// « ❤️ » n'est pas une phrase : c'est un geste.
///
/// Un message qui ne contient qu'un ou deux emoji se lit d'un coup d'œil, de
/// loin, sans être lu — à condition qu'on le montre nu et grand plutôt que
/// coincé dans une bulle à sa taille de texte. Reste à décider ce qui compte
/// comme « rien qu'un emoji ».
///
/// Pur, sans SwiftUI : c'est la partie que les tests exercent. Le rendu (pas de
/// fond, corps ~40 pt) appartient à `MessageBubbleView`.
enum EmojiText {
  /// Au-delà de trois, ce n'est plus un geste mais une guirlande : elle
  /// reprend sa place dans une bulle ordinaire.
  static let maxCount = 3

  /// Le texte, une fois trimé, n'est-il fait que de 1 à 3 emoji ?
  ///
  /// On raisonne en GRAPPES au sens Unicode (`Character`), pas en scalaires :
  /// « 👨‍👩‍👧 » est une seule grappe de cinq scalaires, « 👍🏽 » une grappe de
  /// deux, « 🇫🇷 » une grappe de deux indicateurs régionaux. Compter les
  /// scalaires — ou pire, chercher une plage de codes à la main — recracherait
  /// une famille comme « trois emoji » et casserait sur le premier drapeau.
  static func isEmojiOnly(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }

    var count = 0
    for cluster in trimmed {
      // « ❤️ 🎉 » reste un geste : l'espace entre deux emoji ne compte pas.
      if cluster.isWhitespace { continue }
      guard cluster.isEmojiCluster else { return false }
      count += 1
      if count > maxCount { return false }
    }
    return count > 0
  }
}

extension Character {
  /// Cette grappe est-elle un emoji, et rien d'autre ?
  ///
  /// Swift expose les propriétés Unicode des scalaires : on s'en sert plutôt
  /// que d'une expression rationnelle, qui ne saurait ni les jointures ZWJ ni
  /// les modificateurs de teinte.
  ///
  /// Deux cas, et c'est la distinction qui compte :
  ///
  /// - un scalaire seul n'est un emoji que s'il se PRÉSENTE comme tel
  ///   (`Emoji_Presentation`). Sans ça « 3 », « # » ou « © » — qui portent tous
  ///   `Emoji = Yes` pour des raisons historiques — passeraient pour des emoji ;
  /// - une grappe composée l'est dès que sa tête est un emoji et qu'un de ses
  ///   scalaires la pousse vers l'image : sélecteur de présentation `U+FE0F`
  ///   (« ❤️ », « 3️⃣ »), modificateur de teinte (« 👍🏽 »), ou un second emoji
  ///   à présentation (jointure ZWJ « 👨‍👩‍👧 », drapeau « 🇫🇷 »).
  var isEmojiCluster: Bool {
    var scalars = unicodeScalars.makeIterator()
    guard let first = scalars.next() else { return false }
    guard first.properties.isEmoji else { return false }
    if unicodeScalars.count == 1 { return first.properties.isEmojiPresentation }
    return unicodeScalars.contains { scalar in
      scalar == "\u{FE0F}"
        || scalar.properties.isEmojiModifier
        || scalar.properties.isEmojiPresentation
    }
  }
}
