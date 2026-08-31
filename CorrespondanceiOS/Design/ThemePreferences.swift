import CorrespondanceCore
import CorrespondanceUI
import Observation
import SwiftUI

/// L'ambiance d'écriture choisie, persistée. Les six thèmes du Mac, la même
/// typographie : l'iPhone porte l'identité visuelle de Correspondance, pas
/// celle de son repère de mise en page.
@MainActor
@Observable
final class ThemePreferences {
  private static let themeKey = "correspondance.ios.theme"
  private static let typefaceKey = "correspondance.ios.typeface"

  var themeID: WritingThemeID {
    didSet { UserDefaults.standard.set(themeID.rawValue, forKey: Self.themeKey) }
  }

  var typeface: WritingTypeface {
    didSet { UserDefaults.standard.set(typeface.rawValue, forKey: Self.typefaceKey) }
  }

  var theme: WritingTheme { WritingTheme.resolve(themeID) }

  init() {
    let storedTheme = UserDefaults.standard.string(forKey: Self.themeKey) ?? ""
    let storedFace = UserDefaults.standard.string(forKey: Self.typefaceKey) ?? ""
    // Les fontes (iA Writer S, IBM Plex — OFL) sont embarquées dans la cible
    // iOS comme dans celle du Mac : les deux appareils écrivent de la même main.
    themeID = WritingThemeID(rawValue: storedTheme) ?? .papier
    typeface = WritingTypeface(rawValue: storedFace) ?? .quattro
  }
}
