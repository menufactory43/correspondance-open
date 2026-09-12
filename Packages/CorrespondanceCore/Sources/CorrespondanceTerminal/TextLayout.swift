/// Couper du texte en lignes de cellules.
///
/// Les coupures se font aux espaces ; un mot plus long que la ligne (une URL,
/// un identifiant) se coupe au graphème. Les retours à la ligne du texte sont
/// respectés. Tout se mesure en cellules, jamais en caractères.
public enum TextLayout {
  public struct Line: Equatable, Sendable {
    public var text: String
    public var width: Int
    /// Décalage, en graphèmes, du début de la ligne dans le texte d'origine.
    public var startOffset: Int

    public init(text: String, width: Int, startOffset: Int) {
      self.text = text
      self.width = width
      self.startOffset = startOffset
    }
  }

  /// Coupe `text` en lignes d'au plus `width` cellules.
  public static func wrap(_ text: String, width: Int) -> [Line] {
    guard width > 0 else { return [] }
    var lines: [Line] = []
    var offset = 0
    for paragraph in text.split(separator: "\n", omittingEmptySubsequences: false) {
      wrapParagraph(paragraph, width: width, baseOffset: offset, into: &lines)
      offset += paragraph.count + 1
    }
    return lines
  }

  private static func wrapParagraph(_ paragraph: Substring, width: Int, baseOffset: Int, into lines: inout [Line]) {
    var current = ""
    var currentWidth = 0
    var currentStart = baseOffset
    var offset = baseOffset
    var emittedAny = false

    func emit() {
      lines.append(Line(text: current, width: currentWidth, startOffset: currentStart))
      current = ""
      currentWidth = 0
      emittedAny = true
    }

    var index = paragraph.startIndex
    while index < paragraph.endIndex {
      // Un jeton : une suite d'espaces, ou une suite de non-espaces.
      let isSpace = paragraph[index] == " "
      var end = index
      while end < paragraph.endIndex, (paragraph[end] == " ") == isSpace {
        end = paragraph.index(after: end)
      }
      let token = paragraph[index..<end]
      let tokenCount = token.count
      let tokenWidth = CellWidth.of(token)
      defer {
        offset += tokenCount
        index = end
      }

      if isSpace {
        if currentWidth + tokenWidth <= width {
          if current.isEmpty { currentStart = offset }
          current += token
          currentWidth += tokenWidth
        } else {
          // Les espaces qui débordent disparaissent dans la coupure.
          emit()
          currentStart = offset + tokenCount
        }
        continue
      }
      if currentWidth + tokenWidth <= width {
        if current.isEmpty { currentStart = offset }
        current += token
        currentWidth += tokenWidth
        continue
      }
      if tokenWidth <= width {
        // Le mot passe à la ligne suivante ; les espaces de fin s'effacent.
        while current.last == " " {
          current.removeLast()
          currentWidth -= 1
        }
        emit()
        currentStart = offset
        current = String(token)
        currentWidth = tokenWidth
        continue
      }
      // Un mot plus long que la ligne : coupé au graphème.
      var consumed = 0
      for character in token {
        let w = CellWidth.of(character)
        if currentWidth + w > width, !current.isEmpty { emit() }
        if current.isEmpty { currentStart = offset + consumed }
        current.append(character)
        currentWidth += w
        consumed += 1
      }
    }
    if !current.isEmpty || !emittedAny {
      lines.append(Line(text: current, width: currentWidth, startOffset: current.isEmpty ? offset : currentStart))
    }
  }

  /// Tronque à `width` cellules, avec « … » s'il a fallu couper.
  public static func truncate(_ text: String, to width: Int) -> String {
    guard width > 0 else { return "" }
    if CellWidth.of(text) <= width { return text }
    var result = ""
    var used = 0
    for character in text {
      let w = CellWidth.of(character)
      if used + w > width - 1 { break }
      result.append(character)
      used += w
    }
    return result + "…"
  }

  /// Aplati sur une ligne : les retours et tabulations deviennent des espaces.
  public static func singleLine(_ text: String) -> String {
    var result = ""
    result.reserveCapacity(text.utf8.count)
    var previousWasSpace = false
    for character in text {
      if character.isNewline || character == "\t" {
        if !previousWasSpace { result.append(" ") }
        previousWasSpace = true
      } else {
        result.append(character)
        previousWasSpace = character == " "
      }
    }
    return result
  }
}
