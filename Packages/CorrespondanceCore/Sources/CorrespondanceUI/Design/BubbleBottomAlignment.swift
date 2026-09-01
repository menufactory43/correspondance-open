import CorrespondanceCore
import SwiftUI

public extension VerticalAlignment {
  /// Le bord bas de la BULLE, pas celui de la pile qui la porte.
  ///
  /// Le visage de l'auteur se pose en face de la dernière bulle du groupe.
  /// Aligné sur `.bottom`, il descendait sous elle dès qu'une note « Modifié »,
  /// un « Annuler » ou le débord des réactions allongeait la pile — Messages,
  /// lui, le colle au bord de la bulle, quoi qu'il y ait dessous.
  static let bubbleBottom = VerticalAlignment(BubbleBottomID.self)

  private enum BubbleBottomID: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> CGFloat { context[.bottom] }
  }
}

public extension View {
  /// Pose le repère du bord bas de bulle — seulement sur la dernière du
  /// groupe, la seule que l'avatar regarde.
  @ViewBuilder
  func bubbleBottomGuide(_ position: BubblePosition) -> some View {
    if position.endsGroup {
      alignmentGuide(.bubbleBottom) { $0[.bottom] }
    } else {
      self
    }
  }
}
