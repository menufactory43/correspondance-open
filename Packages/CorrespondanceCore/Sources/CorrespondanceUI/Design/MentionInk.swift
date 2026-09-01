import SwiftUI
import CorrespondanceCore

/// LES GENS DU FIL OUVERT, portés par l'ambiance plutôt que par vingt
/// paramètres : la bulle est loin du composer qui connaît la liste, et rien
/// dans la longue signature de `MessageBubbleView` ne mérite un argument de
/// plus pour ça.
private struct MentionNamesKey: EnvironmentKey {
  static let defaultValue: [String] = []
}

public extension EnvironmentValues {
  var mentionNames: [String] {
    get { self[MentionNamesKey.self] }
    set { self[MentionNamesKey.self] = newValue }
  }
}

/// Le surlignage d'une mention DANS LE CHAMP DE SAISIE.
///
/// `TextField` n'accepte que du texte nu : on pose donc derrière lui le même
/// texte, rendu invisible, dont les seules plages « @Nom » portent un fond
/// d'accent. Même police, même interligne, même largeur — les deux calques se
/// superposent au pixel, et l'œil ne voit que la bande sous la mention.
public struct MentionUnderlay: View {
  public var text: String
  public var names: [String]
  public var tint: Color
  public var font: Font
  public var lineSpacing: CGFloat

  public init(text: String, names: [String], tint: Color, font: Font, lineSpacing: CGFloat) {
    self.text = text
    self.names = names
    self.tint = tint
    self.font = font
    self.lineSpacing = lineSpacing
  }

  public var body: some View {
    Text(attributed)
      .font(font)
      .lineSpacing(lineSpacing)
      .multilineTextAlignment(.leading)
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }

  private var attributed: AttributedString {
    var attributed = AttributedString(text)
    attributed.foregroundColor = .clear
    for range in MentionHighlight.ranges(in: text, names: names) {
      guard let bounds = Range(NSRange(range, in: text), in: attributed) else { continue }
      attributed[bounds].backgroundColor = tint
    }
    return attributed
  }
}
