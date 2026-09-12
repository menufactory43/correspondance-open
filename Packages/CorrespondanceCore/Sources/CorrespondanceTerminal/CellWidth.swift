/// Combien de cellules un graphème occupe dans une grille de terminal.
///
/// La règle est celle que Ghostty et Kitty appliquent quand le mode 2027
/// (« grapheme clustering ») est levé : on mesure le **graphème**, pas le
/// scalaire. Un drapeau, un emoji à teinte, une famille ZWJ : deux cellules,
/// comme une idéogramme. Une lettre accentuée composée : une.
///
/// Le chemin ASCII sort en tête : c'est l'immense majorité de ce qu'on dessine,
/// et il ne doit coûter qu'une comparaison.
public enum CellWidth {
  /// La largeur d'un graphème : 0 (rien à poser), 1 ou 2.
  @inline(__always)
  public static func of(_ character: Character) -> Int {
    if let ascii = character.asciiValue {
      return ascii >= 0x20 && ascii != 0x7F ? 1 : 0
    }
    return nonASCII(character)
  }

  /// La largeur d'une chaîne entière.
  public static func of(_ string: Substring) -> Int {
    var total = 0
    for character in string { total += of(character) }
    return total
  }

  public static func of(_ string: String) -> Int {
    // Le cas courant — de l'ASCII imprimable — se compte en octets.
    if string.utf8.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) { return string.utf8.count }
    var total = 0
    for character in string { total += of(character) }
    return total
  }

  private static func nonASCII(_ character: Character) -> Int {
    let scalars = character.unicodeScalars
    guard let first = scalars.first else { return 0 }
    // Un placeholder d'image Kitty occupe exactement une cellule, diacritiques
    // de ligne et de colonne compris.
    if first.value == 0x10EEEE { return 1 }
    var sawVariationSelector16 = false
    var regionalIndicators = 0
    for scalar in scalars {
      switch scalar.value {
      case 0xFE0F: sawVariationSelector16 = true
      case 0x1F1E6...0x1F1FF: regionalIndicators += 1
      default: break
      }
    }
    if regionalIndicators >= 2 || sawVariationSelector16 { return 2 }
    if scalars.count > 1, scalars.contains(where: { $0.value == 0x200D }) {
      // Une séquence ZWJ dont la base est un emoji se dessine d'un seul glyphe large.
      if first.properties.isEmoji { return 2 }
    }
    return scalarWidth(first)
  }

  /// La largeur d'un scalaire isolé, selon East Asian Width et la présentation emoji.
  public static func scalarWidth(_ scalar: Unicode.Scalar) -> Int {
    let value = scalar.value
    if value < 0x20 || (0x7F..<0xA0).contains(value) { return 0 }
    switch scalar.properties.generalCategory {
    case .nonspacingMark, .enclosingMark, .format:
      // Le trait d'union conditionnel se voit, lui.
      return value == 0x00AD ? 1 : 0
    default: break
    }
    if value >= 0x1160 && value <= 0x11FF { return 0 } // jamos médians et finaux
    if value == 0x200B { return 0 }
    if scalar.properties.isEmojiPresentation { return 2 }
    return isWide(value) ? 2 : 1
  }

  /// Les plages « Wide » et « Fullwidth » d'EastAsianWidth.txt, hors emoji
  /// (couverts par la présentation). Triées, pour une recherche dichotomique.
  private static let wideRanges: [ClosedRange<UInt32>] = [
    0x1100...0x115F, 0x231A...0x231B, 0x2329...0x232A, 0x23E9...0x23EC, 0x23F0...0x23F0,
    0x23F3...0x23F3, 0x25FD...0x25FE, 0x2614...0x2615, 0x2648...0x2653, 0x267F...0x267F,
    0x2693...0x2693, 0x26A1...0x26A1, 0x26AA...0x26AB, 0x26BD...0x26BE, 0x26C4...0x26C5,
    0x26CE...0x26CE, 0x26D4...0x26D4, 0x26EA...0x26EA, 0x26F2...0x26F3, 0x26F5...0x26F5,
    0x26FA...0x26FA, 0x26FD...0x26FD, 0x2705...0x2705, 0x270A...0x270B, 0x2728...0x2728,
    0x274C...0x274C, 0x274E...0x274E, 0x2753...0x2755, 0x2757...0x2757, 0x2795...0x2797,
    0x27B0...0x27B0, 0x27BF...0x27BF, 0x2B1B...0x2B1C, 0x2B50...0x2B50, 0x2B55...0x2B55,
    0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
    0xA960...0xA97F, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE10...0xFE19, 0xFE30...0xFE6F,
    0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x16FE0...0x16FE4, 0x17000...0x18CFF, 0x1AFF0...0x1B2FF,
    0x1F004...0x1F004, 0x1F0CF...0x1F0CF, 0x1F18E...0x1F18E, 0x1F191...0x1F19A,
    0x1F200...0x1F202, 0x1F210...0x1F23B, 0x1F240...0x1F248, 0x1F250...0x1F251,
    0x1F260...0x1F265, 0x20000...0x2FFFD, 0x30000...0x3FFFD,
  ]

  private static func isWide(_ value: UInt32) -> Bool {
    guard value >= 0x1100 else { return false }
    var low = 0
    var high = wideRanges.count - 1
    while low <= high {
      let mid = (low + high) / 2
      let range = wideRanges[mid]
      if value < range.lowerBound { high = mid - 1 }
      else if value > range.upperBound { low = mid + 1 }
      else { return true }
    }
    return false
  }
}
