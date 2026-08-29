import AppKit
import SwiftUI

enum Theme {
  static let letterWidth = LayoutMetrics.letterWidth
  static let noteMinWidth = LayoutMetrics.noteMinWidth
  static let sidebarWidth = LayoutMetrics.sidebarWidth
}

extension Color {
  init(hex: UInt32, opacity: Double = 1) {
    let r = Double((hex >> 16) & 0xFF) / 255
    let g = Double((hex >> 8) & 0xFF) / 255
    let b = Double(hex & 0xFF) / 255
    self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
  }
}

/// Une teinte sRGB qu'on peut MESURER, pas seulement peindre.
///
/// Un thème n'est pas une liste de jolis hex : c'est un système de rôles où
/// chaque encre est posée à une distance vérifiable de son fond. `RGB` porte
/// donc la luminance relative WCAG 2.1, le rapport de contraste et le mélange
/// linéaire — de quoi DÉRIVER les encres secondaires et l'encre des bulles au
/// lieu de les deviner à l'œil. `WritingThemeContrastTests` rejoue ces calculs
/// sur les six thèmes et échoue sous 4,5:1 (texte) ou 3:1 (composants).
struct RGB: Equatable, Hashable, Sendable {
  let r: Double
  let g: Double
  let b: Double

  init(r: Double, g: Double, b: Double) {
    self.r = min(max(r, 0), 1)
    self.g = min(max(g, 0), 1)
    self.b = min(max(b, 0), 1)
  }

  init(_ hex: UInt32) {
    self.init(
      r: Double((hex >> 16) & 0xFF) / 255,
      g: Double((hex >> 8) & 0xFF) / 255,
      b: Double(hex & 0xFF) / 255
    )
  }

  static let black = RGB(0x000000)
  static let white = RGB(0xFFFFFF)

  var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1) }

  /// Mélange linéaire en sRGB : `t = 0` rend soi-même, `t = 1` rend l'autre.
  func mix(_ other: RGB, _ t: Double) -> RGB {
    let k = min(max(t, 0), 1)
    return RGB(
      r: r + (other.r - r) * k,
      g: g + (other.g - g) * k,
      b: b + (other.b - b) * k
    )
  }

  /// Luminance relative WCAG 2.1 (§ relative luminance).
  var relativeLuminance: Double {
    func lin(_ c: Double) -> Double {
      c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
  }

  /// Rapport de contraste WCAG entre deux teintes opaques (1:1 … 21:1).
  static func contrast(_ a: RGB, _ b: RGB) -> Double {
    let l1 = a.relativeLuminance
    let l2 = b.relativeLuminance
    return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
  }

  func contrast(with other: RGB) -> Double { RGB.contrast(self, other) }

  /// LE PLUS PETIT PAS du fond vers l'encre qui tient `minRatio`.
  ///
  /// C'est la dérivation des encres secondaires : au lieu d'écrire « gris 55 % »
  /// et d'espérer, on demande la teinte la plus DISCRÈTE qui reste lisible sur
  /// le fond le plus défavorable du thème. Marche dans les deux sens (encre
  /// claire sur fond sombre comme l'inverse), le contraste étant monotone le
  /// long du mélange.
  static func step(on background: RGB, toward ink: RGB, minRatio: Double) -> RGB {
    guard contrast(background, ink) >= minRatio else { return ink }
    var low = 0.0
    var high = 1.0
    for _ in 0..<24 {
      let mid = (low + high) / 2
      if contrast(background.mix(ink, mid), background) >= minRatio {
        high = mid
      } else {
        low = mid
      }
    }
    return background.mix(ink, high)
  }

  /// UNE SURFACE PLEINE D'ACCENT ET SON ENCRE, garanties lisibles.
  ///
  /// Les bulles sortantes et les pastilles portent du TEXTE sur l'accent : le
  /// rapport doit tenir 4,5:1. On garde l'accent tel quel quand il le tient
  /// déjà ; sinon on le pousse (vers le noir s'il est clair, vers le blanc s'il
  /// est sombre) jusqu'au seuil — l'identité du thème reste, la lisibilité
  /// n'est pas négociée.
  static func filledAccent(
    _ accent: RGB,
    lightInk: RGB,
    darkInk: RGB,
    minRatio: Double
  ) -> (fill: RGB, ink: RGB) {
    var fill = accent
    for _ in 0..<60 {
      let onLight = contrast(fill, lightInk)
      let onDark = contrast(fill, darkInk)
      if max(onLight, onDark) >= minRatio {
        return (fill, onLight >= onDark ? lightInk : darkInk)
      }
      fill = onLight >= onDark ? fill.mix(.black, 0.03) : fill.mix(.white, 0.03)
    }
    let onLight = contrast(fill, lightInk)
    let onDark = contrast(fill, darkInk)
    return (fill, onLight >= onDark ? lightInk : darkInk)
  }
}
