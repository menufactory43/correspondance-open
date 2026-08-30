import SwiftUI

/// Typo de l’app — par défaut **iA Writer Quattro**, comme iA Writer.
enum Typography {
  /// LES CORPS DE LECTURE, au repos — avant l'échelle utilisateur (⌘+ / ⌘−).
  ///
  /// Seuls ces quatre-là suivent l'échelle : ce qu'on LIT et ce qu'on ÉCRIT.
  /// Les métas, la sidebar et les pastilles gardent leur taille — un chrome qui
  /// enfle avec le texte ne fait qu'étouffer la page qu'on voulait agrandir.
  enum Size {
    static let body: CGFloat = 16
    static let letterBody: CGFloat = 18
    static let composer: CGFloat = 15.5
    static let bubble: CGFloat = 15
  }

  /// Corps de message / Focus.
  static func body(
    _ face: WritingTypeface = .quattro,
    size: CGFloat = Size.body,
    italic: Bool = false
  ) -> Font {
    face.font(size: size, italic: italic)
  }

  static func letterBody(
    _ face: WritingTypeface = .quattro,
    size: CGFloat = Size.letterBody,
    italic: Bool = false
  ) -> Font {
    face.font(size: size, italic: italic)
  }

  static func letterTitle(_ face: WritingTypeface = .quattro, _ size: CGFloat = 28) -> Font {
    face.font(size: size)
  }

  static func letterHeading(_ face: WritingTypeface = .quattro, _ size: CGFloat = 22) -> Font {
    face.font(size: size)
  }

  static func sidebarItem(_ face: WritingTypeface = .quattro) -> Font {
    face.font(size: 13.5)
  }

  static func sidebarSection(_ face: WritingTypeface = .quattro) -> Font {
    face.font(size: 11)
  }

  static func meta(_ face: WritingTypeface = .quattro) -> Font {
    face.font(size: 11.5)
  }

  static func toolbarPhrase(_ face: WritingTypeface = .quattro) -> Font {
    face.font(size: 14, italic: true)
  }

  static func emptyState(_ face: WritingTypeface = .quattro) -> Font {
    face.font(size: 16, italic: true)
  }

  /// Le composer, à l'échelle demandée. Écrire et relire se font au même corps.
  static func composer(_ face: WritingTypeface = .quattro, scale: CGFloat = 1) -> Font {
    face.font(size: composerSize(scale))
  }

  static func bubble(_ face: WritingTypeface = .quattro, scale: CGFloat = 1) -> Font {
    face.font(size: bubbleSize(scale))
  }

  /// Le corps EFFECTIF d'une bulle, échelle comprise. Les vues en ont besoin
  /// ailleurs que dans la police : l'interligne et la longueur de ligne s'y
  /// accrochent, et doivent grandir avec elle.
  static func bubbleSize(_ scale: CGFloat = 1) -> CGFloat { Size.bubble * scale }

  static func composerSize(_ scale: CGFloat = 1) -> CGFloat { Size.composer * scale }

  // Compat anciens appels sans typeface (fallback Quattro).
  static var sidebarItem: Font { sidebarItem(.quattro) }
  static var sidebarSection: Font { sidebarSection(.quattro) }
  static var meta: Font { meta(.quattro) }
  static var toolbarPhrase: Font { toolbarPhrase(.quattro) }
  static var emptyState: Font { emptyState(.quattro) }
  static var wordCount: Font { WritingTypeface.mono.font(size: 11) }
}
