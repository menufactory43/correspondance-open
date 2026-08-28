import SwiftUI

/// Typo de l’app — par défaut **iA Writer Quattro**, comme iA Writer.
enum Typography {
  /// Corps de message / Focus.
  static func body(
    _ face: WritingTypeface = .quattro,
    size: CGFloat = 16,
    italic: Bool = false
  ) -> Font {
    face.font(size: size, italic: italic)
  }

  static func letterBody(
    _ face: WritingTypeface = .quattro,
    size: CGFloat = 18,
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

  static func composer(_ face: WritingTypeface = .quattro) -> Font {
    face.font(size: 15.5)
  }

  static func bubble(_ face: WritingTypeface = .quattro) -> Font {
    face.font(size: 15)
  }

  // Compat anciens appels sans typeface (fallback Quattro).
  static var sidebarItem: Font { sidebarItem(.quattro) }
  static var sidebarSection: Font { sidebarSection(.quattro) }
  static var meta: Font { meta(.quattro) }
  static var toolbarPhrase: Font { toolbarPhrase(.quattro) }
  static var emptyState: Font { emptyState(.quattro) }
  static var wordCount: Font { WritingTypeface.mono.font(size: 11) }
}
