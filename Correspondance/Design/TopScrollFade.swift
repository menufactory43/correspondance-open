import SwiftUI
import CorrespondanceCore
import CorrespondanceUI

/// Un fil qui passe sous du chrome s'y coupe net, à mi-bulle. On dissout sa
/// bande haute dans le papier — pas de filet, pas d'arête — comme le fait
/// Messages sous sa barre en verre.
struct TopScrollFade: View {
  let theme: WritingTheme
  var height: CGFloat = ThreadMetrics.topFadeHeight
  /// Vrai quand la bande doit remonter jusqu'au bord de la fenêtre, sous une
  /// barre d'outils transparente ; faux quand elle borde un simple entête.
  var reachesWindowEdge: Bool = true

  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  var body: some View {
    LinearGradient(
      stops: [
        .init(color: theme.paper, location: 0),
        .init(color: theme.paper, location: reduceTransparency ? 0.8 : 0.62),
        .init(color: theme.paper.opacity(0), location: 1),
      ],
      startPoint: .top,
      endPoint: .bottom
    )
    .frame(height: height)
    .frame(maxWidth: .infinity)
    .allowsHitTesting(false)
    .modifier(TopEdgeReach(isOn: reachesWindowEdge))
    .accessibilityHidden(true)
  }
}


/// `ignoresSafeArea` ne se laisse pas mettre derrière un booléen dans une
/// chaîne de modificateurs : on l'isole.
private struct TopEdgeReach: ViewModifier {
  let isOn: Bool

  @ViewBuilder
  func body(content: Content) -> some View {
    if isOn {
      content.ignoresSafeArea(edges: .top)
    } else {
      content
    }
  }
}
