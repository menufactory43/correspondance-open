import SwiftUI

/// LA COULEUR D'UN NOM dans un groupe. Stable (dérivée du nom), et tirée des
/// teintes du thème plutôt que d'une palette étrangère : le fil garde son
/// ambiance même quand douze personnes y parlent. Une seule fonction pour les
/// deux appareils — la même personne a la même encre sur le Mac et sur l'iPhone.
public enum SenderTint {
  public static func color(for name: String, theme: WritingTheme) -> Color {
    var hash = 0
    for scalar in name.unicodeScalars { hash = (hash &* 31) &+ Int(scalar.value) }
    let hue = Double(abs(hash) % 360) / 360
    return Color(
      hue: hue,
      saturation: theme.isDark ? 0.45 : 0.62,
      brightness: theme.isDark ? 0.86 : 0.52
    )
  }
}
