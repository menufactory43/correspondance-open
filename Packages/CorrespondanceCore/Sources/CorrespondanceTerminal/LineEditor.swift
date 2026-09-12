/// Un champ de texte éditable au clavier, avec les raccourcis d'Emacs et de
/// macOS qu'on attend d'un terminal : ^A/^E, ^W, ^U, ^K, Alt+←/→, etc.
///
/// Le texte est tenu en graphèmes : le curseur ne tombe jamais au milieu d'un
/// emoji composé ou d'une lettre accentuée.
public struct LineEditor: Sendable, Equatable {
  public private(set) var characters: [Character]
  /// Position du curseur, en graphèmes, de 0 à `characters.count`.
  public private(set) var cursor: Int
  public var allowsNewlines: Bool

  public init(_ text: String = "", allowsNewlines: Bool = false) {
    characters = Array(text)
    cursor = characters.count
    self.allowsNewlines = allowsNewlines
  }

  public var text: String {
    get { String(characters) }
    set {
      characters = Array(newValue)
      cursor = characters.count
    }
  }

  public var isEmpty: Bool { characters.isEmpty }

  public mutating func setText(_ text: String, cursorAtEnd: Bool = true) {
    characters = Array(text)
    cursor = cursorAtEnd ? characters.count : min(cursor, characters.count)
  }

  public mutating func insert(_ string: String) {
    var incoming = Array(string)
    if !allowsNewlines {
      incoming = incoming.map { $0.isNewline ? " " : $0 }
    } else {
      // Un collage venu de Windows ou d'un vieux Mac n'amène pas de `\r` orphelin.
      incoming = incoming.compactMap { $0 == "\r" ? nil : ($0 == "\r\n" ? "\n" : $0) }
    }
    characters.insert(contentsOf: incoming, at: cursor)
    cursor += incoming.count
  }

  public mutating func backspace() {
    guard cursor > 0 else { return }
    characters.remove(at: cursor - 1)
    cursor -= 1
  }

  public mutating func deleteForward() {
    guard cursor < characters.count else { return }
    characters.remove(at: cursor)
  }

  public mutating func moveLeft() { cursor = max(0, cursor - 1) }
  public mutating func moveRight() { cursor = min(characters.count, cursor + 1) }

  public mutating func moveToLineStart() {
    while cursor > 0, !characters[cursor - 1].isNewline { cursor -= 1 }
  }

  public mutating func moveToLineEnd() {
    while cursor < characters.count, !characters[cursor].isNewline { cursor += 1 }
  }

  public mutating func moveToStart() { cursor = 0 }
  public mutating func moveToEnd() { cursor = characters.count }

  public mutating func moveWordLeft() { cursor = wordStart(before: cursor) }

  public mutating func moveWordRight() {
    var index = cursor
    while index < characters.count, !isWordCharacter(characters[index]) { index += 1 }
    while index < characters.count, isWordCharacter(characters[index]) { index += 1 }
    cursor = index
  }

  public mutating func deleteWordBackward() {
    let start = wordStart(before: cursor)
    characters.removeSubrange(start..<cursor)
    cursor = start
  }

  public mutating func deleteWordForward() {
    var end = cursor
    while end < characters.count, !isWordCharacter(characters[end]) { end += 1 }
    while end < characters.count, isWordCharacter(characters[end]) { end += 1 }
    characters.removeSubrange(cursor..<end)
  }

  /// ^U : efface jusqu'au début de la ligne.
  public mutating func deleteToLineStart() {
    var start = cursor
    while start > 0, !characters[start - 1].isNewline { start -= 1 }
    if start == cursor, start > 0 { start -= 1 } // en tête de ligne : avale le retour
    characters.removeSubrange(start..<cursor)
    cursor = start
  }

  /// ^K : efface jusqu'à la fin de la ligne.
  public mutating func deleteToLineEnd() {
    var end = cursor
    while end < characters.count, !characters[end].isNewline { end += 1 }
    if end == cursor, end < characters.count { end += 1 }
    characters.removeSubrange(cursor..<end)
  }

  /// Monte ou descend d'une ligne visuelle, dans une mise en page de `width`
  /// cellules. Rend `false` au bord : l'appelant peut s'en servir (↑ sur la
  /// première ligne d'un composer vide = corriger le dernier message).
  public mutating func moveVertically(by delta: Int, width: Int) -> Bool {
    let lines = TextLayout.wrap(text, width: max(1, width))
    let (row, column) = Self.position(of: cursor, in: lines, text: characters)
    let target = row + delta
    guard target >= 0, target < lines.count else { return false }
    let line = lines[target]
    var used = 0
    var offset = line.startOffset
    for character in line.text {
      let w = CellWidth.of(character)
      if used + w > column { break }
      used += w
      offset += 1
    }
    cursor = min(offset, characters.count)
    return true
  }

  /// La ligne et la colonne (en cellules) du curseur dans une mise en page.
  public func cursorPosition(width: Int) -> (row: Int, column: Int, lines: [TextLayout.Line]) {
    let lines = TextLayout.wrap(text, width: max(1, width))
    let (row, column) = Self.position(of: cursor, in: lines, text: characters)
    return (row, column, lines)
  }

  static func position(of cursor: Int, in lines: [TextLayout.Line], text: [Character]) -> (Int, Int) {
    guard !lines.isEmpty else { return (0, 0) }
    var row = 0
    for (index, line) in lines.enumerated() where line.startOffset <= cursor {
      row = index
    }
    let line = lines[row]
    let count = min(max(0, cursor - line.startOffset), line.text.count)
    let column = CellWidth.of(String(line.text.prefix(count)))
    return (row, column)
  }

  private func wordStart(before position: Int) -> Int {
    var index = position
    while index > 0, !isWordCharacter(characters[index - 1]) { index -= 1 }
    while index > 0, isWordCharacter(characters[index - 1]) { index -= 1 }
    return index
  }

  private func isWordCharacter(_ character: Character) -> Bool {
    character.isLetter || character.isNumber || character == "_"
  }
}

extension LineEditor {
  /// Applique une touche d'édition. Rend `true` si la touche a été consommée
  /// (qu'elle ait changé le texte ou non), `false` si l'appelant doit la traiter.
  public mutating func handle(_ event: KeyEvent, layoutWidth: Int? = nil) -> Bool {
    let mods = event.modifiers
    switch event.key {
    case .character(let c) where mods.contains(.control):
      switch c {
      case "a": moveToLineStart()
      case "e": moveToLineEnd()
      case "b": moveLeft()
      case "f": moveRight()
      case "h": backspace()
      case "d": deleteForward()
      case "w": deleteWordBackward()
      case "u": deleteToLineStart()
      case "k": deleteToLineEnd()
      case "j" where allowsNewlines: insert("\n")
      default: return false
      }
    case .character(let c) where mods.contains(.alt):
      switch c {
      case "b": moveWordLeft()
      case "f": moveWordRight()
      case "d": deleteWordForward()
      default: return false
      }
    case .character(let c) where !mods.contains(.super):
      insert(String(c))
    case .backspace:
      if mods.contains(.alt) || mods.contains(.control) { deleteWordBackward() } else { backspace() }
    case .delete:
      if mods.contains(.alt) { deleteWordForward() } else { deleteForward() }
    case .left:
      if mods.contains(.alt) || mods.contains(.control) { moveWordLeft() }
      else if mods.contains(.super) { moveToLineStart() }
      else { moveLeft() }
    case .right:
      if mods.contains(.alt) || mods.contains(.control) { moveWordRight() }
      else if mods.contains(.super) { moveToLineEnd() }
      else { moveRight() }
    case .home:
      moveToLineStart()
    case .end:
      moveToLineEnd()
    case .up where allowsNewlines:
      guard let width = layoutWidth else { return false }
      return moveVertically(by: -1, width: width)
    case .down where allowsNewlines:
      guard let width = layoutWidth else { return false }
      return moveVertically(by: 1, width: width)
    case .enter where allowsNewlines && (mods.contains(.shift) || mods.contains(.alt)):
      insert("\n")
    default:
      return false
    }
    return true
  }
}
