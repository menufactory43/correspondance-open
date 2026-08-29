import AppKit
import SwiftUI

/// Ambiance d’écriture — papier, encre, lumière. Pas un skin décoratif.
enum WritingThemeID: String, CaseIterable, Identifiable, Codable, Sendable {
  case papier
  case dune
  case clairDeLune
  case encreDeNuit
  case vieuxBureau
  case cireEtChene

  var id: String { rawValue }

  var labelFR: String {
    switch self {
    case .papier: "Papier"
    case .dune: "Dune"
    case .clairDeLune: "Clair de lune"
    case .encreDeNuit: "Encre de nuit"
    case .vieuxBureau: "Vieux bureau"
    case .cireEtChene: "Cire et chêne"
    }
  }

  var subtitleFR: String {
    switch self {
    case .papier: "Ivoire chaud, silence de matin"
    case .dune: "Sable et sépia, lumière basse"
    case .clairDeLune: "Gris bleuté, air frais"
    case .encreDeNuit: "Nuit profonde, encre claire"
    case .vieuxBureau: "Lampe de bureau, vert olive"
    case .cireEtChene: "Bois sombre, cire rouge"
    }
  }

  var systemImage: String {
    switch self {
    case .papier: "doc.plaintext"
    case .dune: "sun.haze"
    case .clairDeLune: "moon.stars"
    case .encreDeNuit: "moon.fill"
    case .vieuxBureau: "lamp.desk"
    case .cireEtChene: "flame"
    }
  }

  var prefersDarkChrome: Bool {
    switch self {
    case .papier, .dune, .clairDeLune: false
    case .encreDeNuit, .vieuxBureau, .cireEtChene: true
    }
  }
}

struct WritingTheme: Equatable, Sendable {
  let id: WritingThemeID
  let paper: Color
  let paperSecondary: Color
  let ink: Color
  let inkSecondary: Color
  let inkTertiary: Color
  let accent: Color
  let accentSoft: Color
  let sidebar: Color
  let selection: Color
  let edge: Color
  let glow: Color
  let room: Color
  let caret: Color
  let bodySize: CGFloat
  let lineSpacing: CGFloat
  let letterTracking: CGFloat

  static func resolve(_ id: WritingThemeID) -> WritingTheme {
    switch id {
    case .papier:
      WritingTheme(
        id: .papier,
        paper: Color(hex: 0xFAF7F2),
        paperSecondary: Color(hex: 0xF3EEE6),
        ink: Color(hex: 0x1C1917),
        inkSecondary: Color(hex: 0x6B6560),
        inkTertiary: Color(hex: 0x9C958C),
        accent: Color(hex: 0x8B5E3C),
        accentSoft: Color(hex: 0xC4A484),
        sidebar: Color(hex: 0xF0EBE3),
        selection: Color(hex: 0xE6DCCF),
        edge: Color(hex: 0xE0D6C8),
        glow: Color(hex: 0xFFFCF8),
        room: Color(hex: 0xEDE6DC),
        caret: Color(hex: 0x8B5E3C),
        bodySize: 18,
        lineSpacing: 8,
        letterTracking: 0.2
      )
    case .dune:
      WritingTheme(
        id: .dune,
        paper: Color(hex: 0xF4E8D4),
        paperSecondary: Color(hex: 0xEBD9BE),
        ink: Color(hex: 0x3B2A1A),
        inkSecondary: Color(hex: 0x7A5C3E),
        inkTertiary: Color(hex: 0xA88968),
        accent: Color(hex: 0xA65C2E),
        accentSoft: Color(hex: 0xD4A574),
        sidebar: Color(hex: 0xE8D7BE),
        selection: Color(hex: 0xDFC9A8),
        edge: Color(hex: 0xD4C0A0),
        glow: Color(hex: 0xFFF4E4),
        room: Color(hex: 0xD9C4A4),
        caret: Color(hex: 0xA65C2E),
        bodySize: 18,
        lineSpacing: 9,
        letterTracking: 0.15
      )
    case .clairDeLune:
      WritingTheme(
        id: .clairDeLune,
        paper: Color(hex: 0xF2F4F7),
        paperSecondary: Color(hex: 0xE8ECF2),
        ink: Color(hex: 0x1E2430),
        inkSecondary: Color(hex: 0x5C6778),
        inkTertiary: Color(hex: 0x8B95A5),
        accent: Color(hex: 0x4A6FA5),
        accentSoft: Color(hex: 0x9BB0CC),
        sidebar: Color(hex: 0xE6EAF0),
        selection: Color(hex: 0xD5DDE8),
        edge: Color(hex: 0xCDD5E0),
        glow: Color(hex: 0xFFFFFF),
        room: Color(hex: 0xD8DEE8),
        caret: Color(hex: 0x4A6FA5),
        bodySize: 17.5,
        lineSpacing: 8,
        letterTracking: 0.1
      )
    case .encreDeNuit:
      WritingTheme(
        id: .encreDeNuit,
        paper: Color(hex: 0x141820),
        paperSecondary: Color(hex: 0x1A2030),
        ink: Color(hex: 0xE8ECF4),
        inkSecondary: Color(hex: 0xA8B2C4),
        // Assez clair pour les placeholders sur fond sombre.
        inkTertiary: Color(hex: 0x8E98AA),
        accent: Color(hex: 0x7EA0D4),
        accentSoft: Color(hex: 0x3D5278),
        sidebar: Color(hex: 0x10141C),
        selection: Color(hex: 0x243048),
        edge: Color(hex: 0x2A3348),
        glow: Color(hex: 0x1C2438),
        room: Color(hex: 0x0C0F16),
        caret: Color(hex: 0x9BB8E8),
        bodySize: 18,
        lineSpacing: 9,
        letterTracking: 0.25
      )
    case .vieuxBureau:
      WritingTheme(
        id: .vieuxBureau,
        paper: Color(hex: 0x1A2218),
        paperSecondary: Color(hex: 0x222C1E),
        ink: Color(hex: 0xD8E0C8),
        inkSecondary: Color(hex: 0xA0B090),
        inkTertiary: Color(hex: 0x8A9A78),
        accent: Color(hex: 0xA8C478),
        accentSoft: Color(hex: 0x4A5C38),
        sidebar: Color(hex: 0x141A12),
        selection: Color(hex: 0x2C3826),
        edge: Color(hex: 0x303C2A),
        glow: Color(hex: 0x24301E),
        room: Color(hex: 0x0E120C),
        caret: Color(hex: 0xC4E090),
        bodySize: 17.5,
        lineSpacing: 8,
        letterTracking: 0.3
      )
    case .cireEtChene:
      WritingTheme(
        id: .cireEtChene,
        paper: Color(hex: 0x1E1612),
        paperSecondary: Color(hex: 0x281E18),
        ink: Color(hex: 0xF0E4D4),
        inkSecondary: Color(hex: 0xC4B09C),
        inkTertiary: Color(hex: 0xA09080),
        accent: Color(hex: 0xC45C3A),
        accentSoft: Color(hex: 0x6B3A28),
        sidebar: Color(hex: 0x16100C),
        selection: Color(hex: 0x342820),
        edge: Color(hex: 0x3A2C24),
        glow: Color(hex: 0x2A1E16),
        room: Color(hex: 0x100C0A),
        caret: Color(hex: 0xE07048),
        bodySize: 18,
        lineSpacing: 9,
        letterTracking: 0.2
      )
    }
  }
}

/// Préférences d’ambiance + écriture (parité iA Writer).
@MainActor
@Observable
final class ThemePreferences {
  var themeID: WritingThemeID {
    didSet { UserDefaults.standard.set(themeID.rawValue, forKey: Keys.theme) }
  }

  var typeface: WritingTypeface {
    didSet { UserDefaults.standard.set(typeface.rawValue, forKey: Keys.typeface) }
  }

  var typeScale: Double {
    didSet { UserDefaults.standard.set(typeScale, forKey: Keys.typeScale) }
  }

  var lineLength: LineLengthPreset {
    didSet { UserDefaults.standard.set(lineLength.rawValue, forKey: Keys.lineLength) }
  }

  var focusScope: FocusScope {
    didSet { UserDefaults.standard.set(focusScope.rawValue, forKey: Keys.focusScope) }
  }

  var typewriterMode: Bool {
    didSet { UserDefaults.standard.set(typewriterMode, forKey: Keys.typewriter) }
  }

  var showWordCount: Bool {
    didSet { UserDefaults.standard.set(showWordCount, forKey: Keys.wordCount) }
  }

  var warmThresholdHours: Double {
    didSet { UserDefaults.standard.set(warmThresholdHours, forKey: Keys.warm) }
  }

  var theme: WritingTheme { WritingTheme.resolve(themeID) }

  init() {
    let raw = UserDefaults.standard.string(forKey: Keys.theme) ?? WritingThemeID.papier.rawValue
    self.themeID = WritingThemeID(rawValue: raw) ?? .papier

    let face = UserDefaults.standard.string(forKey: Keys.typeface) ?? WritingTypeface.quattro.rawValue
    self.typeface = WritingTypeface(rawValue: face) ?? .quattro

    let scale = UserDefaults.standard.object(forKey: Keys.typeScale) as? Double
    self.typeScale = scale ?? 1.0

    let cpl = UserDefaults.standard.object(forKey: Keys.lineLength) as? Int
    self.lineLength = LineLengthPreset(rawValue: cpl ?? 72) ?? .classic

    let scope = UserDefaults.standard.string(forKey: Keys.focusScope) ?? FocusScope.paragraph.rawValue
    self.focusScope = FocusScope(rawValue: scope) ?? .paragraph

    if UserDefaults.standard.object(forKey: Keys.typewriter) == nil {
      self.typewriterMode = true
    } else {
      self.typewriterMode = UserDefaults.standard.bool(forKey: Keys.typewriter)
    }

    if UserDefaults.standard.object(forKey: Keys.wordCount) == nil {
      self.showWordCount = true
    } else {
      self.showWordCount = UserDefaults.standard.bool(forKey: Keys.wordCount)
    }
    let warm = UserDefaults.standard.object(forKey: Keys.warm) as? Double
    self.warmThresholdHours = warm ?? 12
  }

  private enum Keys {
    static let theme = "correspondance.theme"
    static let typeface = "correspondance.typeface"
    static let typeScale = "correspondance.typeScale"
    static let lineLength = "correspondance.lineLength"
    static let focusScope = "correspondance.focusScope"
    static let typewriter = "correspondance.typewriter"
    static let wordCount = "correspondance.showWordCount"
    static let warm = "correspondance.warmHours"
  }
}

enum LayoutMetrics {
  static let letterWidth: CGFloat = 560
  static let noteMinWidth: CGFloat = 420
  /// Largeur type Claude / Codex — un peu plus généreuse qu’une sidebar Finder.
  static let sidebarWidth: CGFloat = 260
  static let pageTopInset: CGFloat = 72
  static let pageBottomInset: CGFloat = 120
  /// Marge gauche type iA Writer — à gauche du centre, loin des feux.
  static let pageLeading: CGFloat = 168
}
