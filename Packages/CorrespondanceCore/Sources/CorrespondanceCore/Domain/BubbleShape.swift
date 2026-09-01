import Foundation

/// Où une bulle se tient dans sa prise de parole.
public enum BubblePosition: Sendable, Equatable {
  case alone
  case first
  case middle
  case last

  /// La place d'une bulle dans un groupe de `count` bulles.
  public init(index: Int, count: Int) {
    if count <= 1 { self = .alone }
    else if index == 0 { self = .first }
    else if index == count - 1 { self = .last }
    else { self = .middle }
  }

  /// Vrai quand une bulle du même auteur la suit : le coin du bas s'y resserre.
  var continuesBelow: Bool { self == .first || self == .middle }
  /// Vrai quand une bulle du même auteur la précède.
  var continuesAbove: Bool { self == .middle || self == .last }
  /// La dernière bulle d'une prise de parole : celle que l'avatar regarde.
  public var endsGroup: Bool { self == .last || self == .alone }
}

/// Les quatre rayons d'une bulle, dans l'ordre où SwiftUI les demande.
public struct BubbleCorners: Equatable, Sendable {
  public var topLeading: CGFloat
  public var bottomLeading: CGFloat
  public var bottomTrailing: CGFloat
  public var topTrailing: CGFloat

  public init(topLeading: CGFloat, bottomLeading: CGFloat, bottomTrailing: CGFloat, topTrailing: CGFloat) {
    self.topLeading = topLeading
    self.bottomLeading = bottomLeading
    self.bottomTrailing = bottomTrailing
    self.topTrailing = topTrailing
  }
}

/// LA FORME D'UNE BULLE selon sa place dans la prise de parole.
///
/// Messages et Telegram ne dessinent pas de queue : ils resserrent le coin du
/// côté où la voix continue. Trois bulles d'affilée forment ainsi un bloc, et
/// l'œil voit une prise de parole au lieu de trois objets identiques.
public enum BubbleShape {
  /// Le coin de l'enchaînement. Assez petit pour souder deux bulles, assez
  /// grand pour ne pas passer pour un angle droit.
  public static let tightRadius: CGFloat = 5

  /// - Parameter isFromMe: mes bulles s'alignent à droite — c'est ce bord-là
  ///   qui porte l'enchaînement ; celles des autres l'ont à gauche.
  public static func corners(
    isFromMe: Bool,
    position: BubblePosition,
    radius: CGFloat,
    tight: CGFloat = tightRadius
  ) -> BubbleCorners {
    let top = position.continuesAbove ? tight : radius
    let bottom = position.continuesBelow ? tight : radius
    return BubbleCorners(
      topLeading: isFromMe ? radius : top,
      bottomLeading: isFromMe ? radius : bottom,
      bottomTrailing: isFromMe ? bottom : radius,
      topTrailing: isFromMe ? top : radius
    )
  }
}
