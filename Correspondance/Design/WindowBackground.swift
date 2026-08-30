import SwiftUI

// Le fond de fenêtre est une notion de bureau : `containerBackground(_:for: .window)`
// n'existe pas sur iPhone. Ce voisin de `GlassSurface` reste donc dans la cible Mac
// plutôt que d'entrer dans CorrespondanceUI derrière un `#if`.
extension View {
  /// Fond de fenêtre natif (macOS 15+) — remplace le bricolage `NSWindow.backgroundColor`.
  @ViewBuilder
  func correspondanceWindowBackground(_ color: Color) -> some View {
    if #available(macOS 15.0, *) {
      containerBackground(color, for: .window)
    } else {
      background(color.ignoresSafeArea())
    }
  }
}
