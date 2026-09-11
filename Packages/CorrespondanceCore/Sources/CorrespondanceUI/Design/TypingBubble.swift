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

/// UN POINT qui respire, sans animation SwiftUI : son opacité se lit sur
/// l'horloge.
///
/// La version d'avant la posait par `withAnimation(.repeatForever)` depuis son
/// `onAppear`, et cette transaction sans fin s'accrochait au ScrollView du fil
/// qui contient la bulle : tant que quelqu'un écrivait, le décalage du fil
/// faisait un aller-retour de 300 points toutes les 1,4 s, sans que personne
/// n'y touche (mesuré sur le simulateur, en relevant `contentOffset` à chaque
/// changement de géométrie : des milliers de relevés en sinusoïde, contre
/// cinq une fois l'horloge en place). Et un `animation(_:value:)` posé sur la
/// rangée entière, lui, emporte aussi la POSITION des points, qui partent se
/// ranger hors de la bulle. L'horloge ne touche à rien d'autre que ce point.
private struct TypingDot: View {
  let color: Color
  let delay: Double

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Un aller-retour par seconde, chaque point un peu après le précédent.
  private static let period = 1.0

  var body: some View {
    TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
      let t = context.date.timeIntervalSinceReferenceDate - delay
      let phase = (t / Self.period).truncatingRemainder(dividingBy: 1)
      let wave = reduceMotion ? 1 : (1 - cos(phase * 2 * .pi)) / 2
      Circle()
        .fill(color)
        .frame(width: 6, height: 6)
        .opacity(0.4 + 0.6 * wave)
    }
  }
}
