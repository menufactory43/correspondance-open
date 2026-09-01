import SwiftUI

/// « En train d'écrire », comme une vraie bulle : trois points qui respirent à
/// la place où la phrase va paraître. Une ligne de gris disait la même chose,
/// mais elle ne se voyait pas — c'est du mouvement qu'on attrape du coin de l'œil.
public struct TypingBubble: View {
  /// Le libellé du Relais (« Alice écrit… »), écrit au-dessus des points quand
  /// plusieurs personnes parlent. `nil` en tête-à-tête : on sait qui écrit.
  public let name: String?
  /// Ce que la voix synthétique annonce — toujours la phrase entière.
  public let accessibilityLabel: String
  public let theme: WritingTheme
  public var typeface: WritingTypeface = .quattro
  public var cornerRadius: CGFloat = 16

  public init(
    name: String?,
    accessibilityLabel: String,
    theme: WritingTheme,
    typeface: WritingTypeface = .quattro,
    cornerRadius: CGFloat = 16
  ) {
    self.name = name
    self.accessibilityLabel = accessibilityLabel
    self.theme = theme
    self.typeface = typeface
    self.cornerRadius = cornerRadius
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      if let name {
        Text(name)
          .font(Typography.meta(typeface))
          .foregroundStyle(theme.inkTertiary)
          .lineLimit(1)
          .padding(.leading, 12)
      }
      HStack(spacing: 4) {
        ForEach(0..<3, id: \.self) { rank in
          TypingDot(color: theme.inkSecondary, delay: Double(rank) * 0.15)
        }
      }
      .padding(.horizontal, 12)
      // Hauteur fixée : la bulle qui paraît et disparaît ne doit pas faire
      // sauter le bas du fil d'un pixel à chaque frappe.
      .frame(height: 28)
      .background(
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .fill(theme.bubbleIn)
      )
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
  }
}

/// UN POINT qui respire. Chacun tient sa propre animation : posée depuis son
/// `onAppear`, elle ne porte que son opacité — un `animation(_:value:)` sur la
/// rangée entière emportait aussi la POSITION des points, qui partaient alors
/// se ranger hors de la bulle.
private struct TypingDot: View {
  let color: Color
  let delay: Double

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isBright = false

  var body: some View {
    Circle()
      .fill(color)
      .frame(width: 6, height: 6)
      .opacity(isBright ? 1 : 0.4)
      .onAppear {
        guard !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true).delay(delay)) {
          isBright = true
        }
      }
  }
}
