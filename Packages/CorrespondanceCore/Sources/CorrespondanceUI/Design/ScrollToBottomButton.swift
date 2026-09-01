import SwiftUI

/// LA PILULE ↓ du fil : elle ne paraît que lorsqu'on a remonté, et dit combien
/// de messages sont arrivés pendant qu'on lisait ailleurs. Sans ce compte, le
/// chevron pose la même question à chaque fois — « qu'est-ce que j'ai raté ? ».
public struct ScrollToBottomButton: View {
  public let unreadCount: Int
  public let theme: WritingTheme
  public var size: CGFloat = 38
  public let action: () -> Void

  public init(unreadCount: Int, theme: WritingTheme, size: CGFloat = 38, action: @escaping () -> Void) {
    self.unreadCount = unreadCount
    self.theme = theme
    self.size = size
    self.action = action
  }

  public var body: some View {
    Button(action: action) {
      Image(systemName: "chevron.down")
        .font(.system(size: size * 0.4, weight: .semibold))
        .foregroundStyle(theme.ink)
        .frame(width: size, height: size)
        // Verre NON interactif : le mode interactif héberge la vue dans une
        // couche de verre qui avale les touches en overlay — vérifié au test
        // d'interface, le bouton devenait intouchable.
        .glassSurface(
          cornerRadius: size / 2,
          fallbackFill: theme.paperSecondary,
          border: theme.edge
        )
        // Sans forme explicite, un bouton « plain » n'est touchable que là où
        // il y a de l'encre : le doigt tombait dans le creux du chevron.
        .contentShape(Circle())
        .overlay(alignment: .top) {
          if unreadCount > 0 {
            Text(unreadCount > 99 ? "99+" : "\(unreadCount)")
              .font(.system(size: 10, weight: .bold))
              .monospacedDigit()
              .foregroundStyle(theme.badgeInk)
              .padding(.horizontal, 5)
              .padding(.vertical, 2)
              .background(Capsule().fill(theme.badge))
              .offset(y: -8)
          }
        }
    }
    .buttonStyle(.plain)
    .accessibilityLabel(
      unreadCount > 0
        ? "Aller au dernier message, \(unreadCount) nouveau\(unreadCount > 1 ? "x" : "")"
        : "Aller au dernier message"
    )
  }
}
