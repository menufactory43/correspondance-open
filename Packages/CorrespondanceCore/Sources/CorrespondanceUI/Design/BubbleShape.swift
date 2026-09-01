import CorrespondanceCore
import SwiftUI

public extension BubbleCorners {
  /// La forme à peindre, à découper, à border. Un rectangle aux quatre rayons
  /// inégaux suffit : la queue de bulle, personne ne la dessine plus.
  var shape: UnevenRoundedRectangle {
    UnevenRoundedRectangle(
      topLeadingRadius: topLeading,
      bottomLeadingRadius: bottomLeading,
      bottomTrailingRadius: bottomTrailing,
      topTrailingRadius: topTrailing,
      style: .continuous
    )
  }
}
