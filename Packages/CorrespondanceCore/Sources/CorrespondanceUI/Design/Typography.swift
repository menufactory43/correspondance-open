import SwiftUI
import CorrespondanceCore

/// Typo de l’app — par défaut **iA Writer Quattro**, comme iA Writer.
public enum Typography {
  /// LES CORPS DE LECTURE, au repos — avant l'échelle utilisateur (⌘+ / ⌘−).
  ///
  /// Seuls ces quatre-là suivent l'échelle : ce qu'on LIT et ce qu'on ÉCRIT.
  /// Les métas, la sidebar et les pastilles gardent leur taille — un chrome qui
  /// enfle avec le texte ne fait qu'étouffer la page qu'on voulait agrandir.
  public enum Size {
    public static let body: CGFloat = 16
    public static let letterBody: CGFloat = 18
    public static let composer: CGFloat = 15.5
    public static let bubble: CGFloat = 15
  }

  /// Corps de message / Focus.
  public static func body(
    _ face: WritingTypeface = .quattro,
    size: CGFloat = Size.body,
    italic: Bool = false
  ) -> Font {
    face.font(size: size, italic: italic)
  }

  public static func letterBody(
    _ face: WritingTypeface = .quattro,
    size: CGFloat = Size.letterBody,
    italic: Bool = false
  ) -> Font {
    face.font(size: size, italic: italic)
  }

  public static func letterTitle(_ face: WritingTypeface = .quattro, _ size: CGFloat = 28) -> Font {
    face.font(size: size)
  }

  public static func letterHeading(_ face: WritingTypeface = .quattro, _ size: CGFloat = 22) -> Font {
    face.font(size: size)
  }

  public static func sidebarItem(_ face: WritingTypeface = .quattro) -> Font {
    face.font(size: 13.5)
  }

  public static func sidebarSection(_ face: WritingTypeface = .quattro) -> Font {
    face.font(size: 11)
  }

  public static func meta(_ face: WritingTypeface = .quattro) -> Font {
    face.font(size: 11.5)
  }

  public static func toolbarPhrase(_ face: WritingTypeface = .quattro) -> Font {
    face.font(size: 14, italic: true)
  }

  public static func emptyState(_ face: WritingTypeface = .quattro) -> Font {
    face.font(size: 16, italic: true)
  }

  /// Le composer, à l'échelle demandée. Écrire et relire se font au même corps.
  public static func composer(_ face: WritingTypeface = .quattro, scale: CGFloat = 1) -> Font {
    face.font(size: composerSize(scale))
  }

  public static func bubble(_ face: WritingTypeface = .quattro, scale: CGFloat = 1) -> Font {
    face.font(size: bubbleSize(scale))
  }

  /// Le corps EFFECTIF d'une bulle, échelle comprise. Les vues en ont besoin
  /// ailleurs que dans la police : l'interligne et la longueur de ligne s'y
  /// accrochent, et doivent grandir avec elle.
  public static func bubbleSize(_ scale: CGFloat = 1) -> CGFloat { Size.bubble * scale }

  public static func composerSize(_ scale: CGFloat = 1) -> CGFloat { Size.composer * scale }

  // Compat anciens appels sans typeface (fallback Quattro).
  public static var sidebarItem: Font { sidebarItem(.quattro) }
  public static var sidebarSection: Font { sidebarSection(.quattro) }
  public static var meta: Font { meta(.quattro) }
  public static var toolbarPhrase: Font { toolbarPhrase(.quattro) }
  public static var emptyState: Font { emptyState(.quattro) }
  public static var wordCount: Font { WritingTypeface.mono.font(size: 11) }
}
