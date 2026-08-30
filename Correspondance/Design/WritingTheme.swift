import SwiftUI
import CorrespondanceCore

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
    case .papier: "Parchemin tiède, rose fané"
    case .dune: "Sable et sépia, encre brûlée"
    case .clairDeLune: "Brume claire, bleu franc"
    case .encreDeNuit: "Nuit indigo, bleu de lune"
    case .vieuxBureau: "Lampe verte, forêt sombre"
    case .cireEtChene: "Bois brûlé, cire orangée"
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

/// LE SYSTÈME DE COULEURS D'UN THÈME — des rôles, pas des teintes.
///
/// Méthode reprise de `FauconnierKit/ThemeCouleurs` : un thème se DÉCLARE en
/// quatre teintes de caractère (papier, encre, accent, accent doux) et tout le
/// reste — surfaces creusées, liserés, encres secondaires, bulles, pastilles —
/// se DÉRIVE par mélange et par contrat de contraste. Deux conséquences :
/// aucune valeur n'est posée « à l'œil », et un thème ne peut pas naître
/// illisible (`WritingThemeContrastTests` le rejoue à chaque build).
///
/// Les quatre teintes de caractère viennent de palettes éprouvées (Rosé Pine
/// Dawn, Gruvbox, Catppuccin Latte, Tokyo Night, Everforest — licences MIT) :
/// leurs fonds et leurs accents ont été accordés ensemble par leurs auteurs,
/// c'est ce qui évite les gris tristes et les accents qui hurlent.
struct WritingPalette: Equatable, Sendable {
  let isDark: Bool

  // Surfaces
  let paper: RGB
  let paperSecondary: RGB
  let sidebar: RGB
  let rail: RGB
  let room: RGB
  let glow: RGB
  let selection: RGB
  let separator: RGB

  // Encres
  let ink: RGB
  let inkSecondary: RGB
  let inkTertiary: RGB

  // Accent
  let accent: RGB
  let accentSoft: RGB
  let accentFill: RGB
  let accentInk: RGB
  let caret: RGB

  // Bulles et pastilles
  let bubbleIn: RGB
  let bubbleInInk: RGB
  let bubbleOut: RGB
  let bubbleOutInk: RGB
  let badge: RGB
  let badgeInk: RGB

  /// Les surfaces sur lesquelles du texte courant peut atterrir. Les encres
  /// secondaires se calibrent sur la PIRE d'entre elles, jamais sur le papier
  /// (le papier est toujours le cas facile).
  var textSurfaces: [RGB] {
    [paper, paperSecondary, sidebar, rail, room, selection, bubbleIn]
  }

  /// LE BÂTISSEUR. Quatre teintes entrent, un système sort.
  static func make(
    paper: RGB,
    ink: RGB,
    accent: RGB,
    accentSoft: RGB,
    isDark: Bool
  ) -> WritingPalette {
    // Les surfaces : « creuser » va vers le noir la nuit, vers l'encre le jour
    // (un papier clair se creuse en se salissant, pas en s'éteignant).
    let hollow = isDark ? RGB.black : ink
    let paperSecondary = paper.mix(ink, 0.07)
    let sidebar = paper.mix(hollow, isDark ? 0.42 : 0.05)
    let rail = paper.mix(hollow, isDark ? 0.60 : 0.09)
    let room = paper.mix(hollow, isDark ? 0.72 : 0.13)
    let glow = isDark ? paper.mix(ink, 0.10) : paper.mix(.white, 0.60)
    let selection = paper.mix(accent, isDark ? 0.24 : 0.18)
    let separator = paper.mix(ink, isDark ? 0.22 : 0.17)
    let bubbleIn = paper.mix(ink, isDark ? 0.13 : 0.09)

    // Les encres secondaires se dérivent sur la surface la MOINS favorable.
    let surfaces = [paper, paperSecondary, sidebar, rail, room, selection, bubbleIn]
    let worst = surfaces.min { RGB.contrast($0, ink) < RGB.contrast($1, ink) } ?? paper
    let inkSecondary = RGB.step(on: worst, toward: ink, minRatio: 7.0)
    let inkTertiary = RGB.step(on: worst, toward: ink, minRatio: 4.8)

    // L'accent PLEIN : bulles sortantes, pastilles non lues, badges du rail.
    // Son encre est calculée, jamais choisie.
    let lightInk = RGB.white.mix(accent, 0.06)
    let darkInk = RGB.black.mix(accent, 0.10)
    let filled = RGB.filledAccent(accent, lightInk: lightInk, darkInk: darkInk, minRatio: 4.6)

    return WritingPalette(
      isDark: isDark,
      paper: paper,
      paperSecondary: paperSecondary,
      sidebar: sidebar,
      rail: rail,
      room: room,
      glow: glow,
      selection: selection,
      separator: separator,
      ink: ink,
      inkSecondary: inkSecondary,
      inkTertiary: inkTertiary,
      accent: accent,
      accentSoft: accentSoft,
      accentFill: filled.fill,
      accentInk: filled.ink,
      caret: accent,
      bubbleIn: bubbleIn,
      bubbleInInk: ink,
      bubbleOut: filled.fill,
      bubbleOutInk: filled.ink,
      badge: filled.fill,
      badgeInk: filled.ink
    )
  }
}

struct WritingTheme: Equatable, Sendable {
  let id: WritingThemeID
  let palette: WritingPalette
  let bodySize: CGFloat
  let lineSpacing: CGFloat
  let letterTracking: CGFloat

  // MARK: - Jetons sémantiques (les vues ne voient QUE ça)

  var paper: Color { palette.paper.color }
  var paperSecondary: Color { palette.paperSecondary.color }
  var sidebar: Color { palette.sidebar.color }
  var rail: Color { palette.rail.color }
  var room: Color { palette.room.color }
  var glow: Color { palette.glow.color }
  var selection: Color { palette.selection.color }
  var separator: Color { palette.separator.color }
  /// Ancien nom du liseré — les vues historiques l'appellent encore ainsi.
  var edge: Color { palette.separator.color }

  var ink: Color { palette.ink.color }
  var inkSecondary: Color { palette.inkSecondary.color }
  var inkTertiary: Color { palette.inkTertiary.color }

  var accent: Color { palette.accent.color }
  var accentSoft: Color { palette.accentSoft.color }
  var accentFill: Color { palette.accentFill.color }
  var accentInk: Color { palette.accentInk.color }
  var caret: Color { palette.caret.color }

  var bubbleIn: Color { palette.bubbleIn.color }
  var bubbleInInk: Color { palette.bubbleInInk.color }
  var bubbleOut: Color { palette.bubbleOut.color }
  var bubbleOutInk: Color { palette.bubbleOutInk.color }
  var badge: Color { palette.badge.color }
  var badgeInk: Color { palette.badgeInk.color }

  var isDark: Bool { palette.isDark }

  // MARK: - Interligne

  /// Ce qu'une mesure courte sur fond plein garde de l'interligne d'une page.
  ///
  /// Une bulle n'est pas une lettre : elle tient sur quelques mots, son fond la
  /// délimite déjà, et l'air d'une page l'y ferait flotter. Deux tiers — c'est
  /// ce qui pose un corps 15 autour de 4,3–4,9 pt d'interligne selon le thème,
  /// soit l'interligne de lecture visé sans desserrer la bulle en accordéon.
  static let bubbleTightening: CGFloat = 0.65

  /// L'INTERLIGNE DE LECTURE pour un corps donné.
  ///
  /// Le thème déclare son interligne POUR SON CORPS DE LETTRE (`bodySize`,
  /// 17,5–18 pt) : l'appliquer tel quel à une bulle de 15 pt déchirerait le
  /// paragraphe en lignes flottantes. On le ramène donc au rapport des deux
  /// corps — et comme `size` porte déjà l'échelle utilisateur (⌘+ / ⌘−),
  /// l'interligne la suit sans qu'on ait à la repasser.
  func lineSpacing(forBodySize size: CGFloat, tightening: CGFloat = 1) -> CGFloat {
    guard bodySize > 0 else { return lineSpacing * tightening }
    return lineSpacing * (size / bodySize) * tightening
  }

  /// L'interligne d'une bulle (Inbox) ou du composer, pour le corps effectif.
  func bubbleLineSpacing(forBodySize size: CGFloat) -> CGFloat {
    lineSpacing(forBodySize: size, tightening: Self.bubbleTightening)
  }

  // MARK: - La table

  static func resolve(_ id: WritingThemeID) -> WritingTheme {
    switch id {
    // « Papier » — Rosé Pine Dawn : parchemin tiède, encre prune, rose fané.
    // Le thème clair par défaut : chaud sans être jaune, doux sans être fade.
    case .papier:
      WritingTheme(
        id: .papier,
        palette: .make(
          paper: RGB(0xFAF4ED),
          ink: RGB(0x4A4462),
          // Le « love » de Rosé Pine Dawn (#B4637A) ne fait que 3,84:1 sur son
          // parchemin : assombri d'un cran pour porter du texte (4,78:1).
          accent: RGB(0xA4536A),
          accentSoft: RGB(0xD7827E),
          isDark: false
        ),
        bodySize: 18,
        lineSpacing: 8,
        letterTracking: 0.2
      )

    // « Dune » — Gruvbox light : le sépia d'iA Writer, mais avec une encre
    // brûlée qui tient debout. Le thème des longues séances de lecture.
    case .dune:
      WritingTheme(
        id: .dune,
        palette: .make(
          paper: RGB(0xFBF1C7),
          ink: RGB(0x3C3836),
          accent: RGB(0xAF3A03),
          accentSoft: RGB(0xD79921),
          isDark: false
        ),
        bodySize: 18,
        lineSpacing: 9,
        letterTracking: 0.15
      )

    // « Clair de lune » — Catppuccin Latte : brume froide, bleu franc.
    // Le contrepoint frais des deux papiers chauds.
    case .clairDeLune:
      WritingTheme(
        id: .clairDeLune,
        palette: .make(
          paper: RGB(0xEFF1F5),
          ink: RGB(0x4C4F69),
          // Le bleu Latte publié (#1E66F5) ne fait que 4,34:1 sur sa propre
          // brume : assombri d'un cran pour porter du texte (5,11:1).
          accent: RGB(0x1A5DDB),
          accentSoft: RGB(0x7287FD),
          isDark: false
        ),
        bodySize: 17.5,
        lineSpacing: 8,
        letterTracking: 0.1
      )

    // « Encre de nuit » — Tokyo Night : une nuit INDIGO, pas un gris éteint.
    // Le fond porte encore du bleu, l'encre aussi : rien n'est neutre.
    case .encreDeNuit:
      WritingTheme(
        id: .encreDeNuit,
        palette: .make(
          paper: RGB(0x1A1B26),
          ink: RGB(0xC0CAF5),
          accent: RGB(0x7AA2F7),
          accentSoft: RGB(0x3D59A1),
          isDark: true
        ),
        bodySize: 18,
        lineSpacing: 9,
        letterTracking: 0.25
      )

    // « Vieux bureau » — Everforest dark : la lampe verte du bureau, un sombre
    // qui tire sur la forêt plutôt que sur l'ardoise.
    case .vieuxBureau:
      WritingTheme(
        id: .vieuxBureau,
        palette: .make(
          paper: RGB(0x2B3339),
          ink: RGB(0xD3C6AA),
          accent: RGB(0xA7C080),
          accentSoft: RGB(0x4F5B45),
          isDark: true
        ),
        bodySize: 17.5,
        lineSpacing: 8,
        letterTracking: 0.3
      )

    // « Cire et chêne » — Gruvbox dark réchauffé jusqu'au bois : fond brun,
    // parchemin en encre, cire orangée en accent.
    case .cireEtChene:
      WritingTheme(
        id: .cireEtChene,
        palette: .make(
          paper: RGB(0x221A15),
          ink: RGB(0xEBDBB2),
          accent: RGB(0xFE8019),
          accentSoft: RGB(0x7C4A2A),
          isDark: true
        ),
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

  /// L'ÉCHELLE DE LECTURE (⌘+ / ⌘− / ⌘0).
  ///
  /// Elle ne touche que les corps qu'on lit et qu'on écrit — bulles, prose
  /// Focus, composer, aperçus. Le chrome (métas, sidebar, pastilles) garde sa
  /// taille : c'est ce qui laisse la place au texte de grandir. Toujours
  /// rangée dans les bornes, d'où le `didSet` qui se corrige lui-même.
  var typeScale: Double {
    didSet {
      // Se réassigner dans son propre `didSet` ne le rejoue pas : la valeur
      // rangée est la bonne, et c'est elle qu'on persiste.
      let clamped = Self.clampTypeScale(typeScale)
      if clamped != typeScale { typeScale = clamped }
      UserDefaults.standard.set(typeScale, forKey: Keys.typeScale)
    }
  }

  /// Le facteur tel que les vues le consomment : un `CGFloat`, déjà borné.
  var textScale: CGFloat { CGFloat(Self.clampTypeScale(typeScale)) }

  /// Les bornes du réglage. En deçà la bulle devient illisible, au-delà une
  /// phrase ne tient plus dans une fenêtre détachée réduite au post-it.
  static let typeScaleRange: ClosedRange<Double> = 0.8...1.4
  static let typeScaleStep: Double = 0.1

  static func clampTypeScale(_ value: Double) -> Double {
    // Arrondi au cran : les raccourcis et le curseur des Réglages doivent
    // tomber sur les mêmes valeurs, sinon « 100 % » n'est jamais tout à fait 1.
    let snapped = (value / typeScaleStep).rounded() * typeScaleStep
    return min(max(snapped, typeScaleRange.lowerBound), typeScaleRange.upperBound)
  }

  /// ⌘+ / ⌘− : un cran dans un sens ou dans l'autre.
  func nudgeTypeScale(_ steps: Int) {
    typeScale = Self.clampTypeScale(typeScale + Double(steps) * Self.typeScaleStep)
  }

  /// ⌘0 : revenir à 100 %.
  func resetTypeScale() { typeScale = 1.0 }

  var isTypeScaleDefault: Bool { abs(typeScale - 1.0) < 0.001 }

  /// « 110 % » — pour le menu et les Réglages.
  var typeScaleLabelFR: String { "\(Int((typeScale * 100).rounded())) %" }

  /// Les aperçus de liens sous les bulles. Allumés d'usine : un lien nu ne dit
  /// pas où il mène.
  var showsLinkPreviews: Bool {
    didSet { UserDefaults.standard.set(showsLinkPreviews, forKey: Keys.linkPreviews) }
  }

  var lineLength: LineLengthPreset {
    didSet { UserDefaults.standard.set(lineLength.rawValue, forKey: Keys.lineLength) }
  }

  var focusScope: FocusScope {
    didSet { UserDefaults.standard.set(focusScope.rawValue, forKey: Keys.focusScope) }
  }

  /// Le geste d'arrivée d'un message, en Focus. L'Inbox garde l'encre.
  var messageArrival: MessageArrival {
    didSet { UserDefaults.standard.set(messageArrival.rawValue, forKey: Keys.messageArrival) }
  }

  var typewriterMode: Bool {
    didSet { UserDefaults.standard.set(typewriterMode, forKey: Keys.typewriter) }
  }

  var showWordCount: Bool {
    didSet { UserDefaults.standard.set(showWordCount, forKey: Keys.wordCount) }
  }

  /// La photo de l'auteur à gauche de chaque prise de parole, en Inbox — comme
  /// Beeper. Se coupe : un tête-à-tête n'a rien à apprendre d'un visage répété.
  var showsMessageAvatars: Bool {
    didSet { UserDefaults.standard.set(showsMessageAvatars, forKey: Keys.messageAvatars) }
  }

  var warmThresholdHours: Double {
    didSet { UserDefaults.standard.set(warmThresholdHours, forKey: Keys.warm) }
  }

  var theme: WritingTheme { WritingTheme.resolve(themeID) }

  init() {
    let raw = UserDefaults.standard.string(forKey: Keys.theme) ?? WritingThemeID.papier.rawValue
    self.themeID = WritingThemeID(rawValue: raw) ?? .papier

    self.typeface = Self.storedTypeface()

    let scale = UserDefaults.standard.object(forKey: Keys.typeScale) as? Double
    self.typeScale = Self.clampTypeScale(scale ?? 1.0)

    if UserDefaults.standard.object(forKey: Keys.linkPreviews) == nil {
      self.showsLinkPreviews = true
    } else {
      self.showsLinkPreviews = UserDefaults.standard.bool(forKey: Keys.linkPreviews)
    }

    let cpl = UserDefaults.standard.object(forKey: Keys.lineLength) as? Int
    self.lineLength = LineLengthPreset(rawValue: cpl ?? 72) ?? .classic

    let scope = UserDefaults.standard.string(forKey: Keys.focusScope) ?? FocusScope.paragraph.rawValue
    self.focusScope = FocusScope(rawValue: scope) ?? .paragraph

    let arrival = UserDefaults.standard.string(forKey: Keys.messageArrival) ?? MessageArrival.encre.rawValue
    self.messageArrival = MessageArrival(rawValue: arrival) ?? .encre

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

    if UserDefaults.standard.object(forKey: Keys.messageAvatars) == nil {
      self.showsMessageAvatars = true
    } else {
      self.showsMessageAvatars = UserDefaults.standard.bool(forKey: Keys.messageAvatars)
    }
    let warm = UserDefaults.standard.object(forKey: Keys.warm) as? Double
    self.warmThresholdHours = warm ?? 12
  }

  /// La fonte rangée dans les réglages — lisible hors du fil principal, pour la
  /// préchauffer au lancement avant que la première bulle la demande.
  nonisolated static func storedTypeface() -> WritingTypeface {
    let raw = UserDefaults.standard.string(forKey: Keys.typeface) ?? ""
    return WritingTypeface(rawValue: raw) ?? .quattro
  }

  private enum Keys {
    static let theme = "correspondance.theme"
    static let typeface = "correspondance.typeface"
    static let typeScale = "correspondance.typeScale"
    static let lineLength = "correspondance.lineLength"
    static let focusScope = "correspondance.focusScope"
    static let messageArrival = "correspondance.messageArrival"
    static let typewriter = "correspondance.typewriter"
    static let wordCount = "correspondance.showWordCount"
    static let messageAvatars = "correspondance.showMessageAvatars"
    static let linkPreviews = "correspondance.showLinkPreviews"
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
  /// Lisière haute qui rappelle la barre d'outils en Focus : assez haute pour
  /// qu'on la trouve sans viser, assez basse pour ne pas s'ouvrir par accident.
  static let focusChromeHoverHeight: CGFloat = 56
}
