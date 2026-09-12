/// Une couleur de terminal.
///
/// `default` et les seize couleurs indexées suivent le thème de l'utilisateur
/// — fond transparent, palette claire ou sombre : c'est ce qu'on veut pour
/// presque tout. Le 24 bits reste pour ce qui doit être exact, comme l'identité
/// d'une image Kitty portée par la couleur de ses placeholders.
public enum TerminalColor: Hashable, Sendable {
  case `default`
  case indexed(UInt8)
  case rgb(UInt8, UInt8, UInt8)

  public static let black = TerminalColor.indexed(0)
  public static let red = TerminalColor.indexed(1)
  public static let green = TerminalColor.indexed(2)
  public static let yellow = TerminalColor.indexed(3)
  public static let blue = TerminalColor.indexed(4)
  public static let magenta = TerminalColor.indexed(5)
  public static let cyan = TerminalColor.indexed(6)
  public static let white = TerminalColor.indexed(7)
  public static let brightBlack = TerminalColor.indexed(8)
  public static let brightRed = TerminalColor.indexed(9)
  public static let brightGreen = TerminalColor.indexed(10)
  public static let brightYellow = TerminalColor.indexed(11)
  public static let brightBlue = TerminalColor.indexed(12)
  public static let brightMagenta = TerminalColor.indexed(13)
  public static let brightCyan = TerminalColor.indexed(14)
  public static let brightWhite = TerminalColor.indexed(15)
}

/// Les attributs SGR d'une cellule.
public struct TextAttributes: OptionSet, Hashable, Sendable {
  public let rawValue: UInt8
  public init(rawValue: UInt8) { self.rawValue = rawValue }

  public static let bold = TextAttributes(rawValue: 1 << 0)
  public static let dim = TextAttributes(rawValue: 1 << 1)
  public static let italic = TextAttributes(rawValue: 1 << 2)
  public static let underline = TextAttributes(rawValue: 1 << 3)
  public static let reverse = TextAttributes(rawValue: 1 << 4)
  public static let strikethrough = TextAttributes(rawValue: 1 << 5)
}

/// Le style d'une cellule : couleurs, attributs, et le lien OSC 8 qu'elle porte.
public struct Style: Hashable, Sendable {
  public var foreground: TerminalColor
  public var background: TerminalColor
  public var attributes: TextAttributes
  /// Indice dans la table des liens du canevas ; 0 = aucun lien.
  public var link: UInt16

  public init(
    foreground: TerminalColor = .default,
    background: TerminalColor = .default,
    attributes: TextAttributes = [],
    link: UInt16 = 0
  ) {
    self.foreground = foreground
    self.background = background
    self.attributes = attributes
    self.link = link
  }

  public static let plain = Style()

  public func with(_ attributes: TextAttributes) -> Style {
    var copy = self
    copy.attributes.formUnion(attributes)
    return copy
  }

  public func foreground(_ color: TerminalColor) -> Style {
    var copy = self
    copy.foreground = color
    return copy
  }

  public func background(_ color: TerminalColor) -> Style {
    var copy = self
    copy.background = color
    return copy
  }
}

/// Une cellule de la grille.
///
/// Le graphème est une `String` : Swift range sans allocation les chaînes de
/// moins de seize octets, ce qui couvre l'ASCII, les emoji composés et les
/// placeholders Kitty. Une cellule de **continuation** (la moitié droite d'un
/// graphème large) porte une chaîne vide et `width == 0`.
public struct Cell: Hashable, Sendable {
  public var grapheme: String
  public var style: Style
  public var width: UInt8

  public init(grapheme: String = " ", style: Style = .plain, width: UInt8 = 1) {
    self.grapheme = grapheme
    self.style = style
    self.width = width
  }

  public static let blank = Cell()
  public var isContinuation: Bool { width == 0 }
}

/// Un rectangle de cellules, en coordonnées d'écran.
public struct Rect: Hashable, Sendable {
  public var x: Int
  public var y: Int
  public var width: Int
  public var height: Int

  public init(x: Int, y: Int, width: Int, height: Int) {
    self.x = x
    self.y = y
    self.width = max(0, width)
    self.height = max(0, height)
  }

  public var maxX: Int { x + width }
  public var maxY: Int { y + height }
  public var isEmpty: Bool { width <= 0 || height <= 0 }

  public func inset(dx: Int = 0, dy: Int = 0) -> Rect {
    Rect(x: x + dx, y: y + dy, width: width - 2 * dx, height: height - 2 * dy)
  }

  public func intersection(_ other: Rect) -> Rect {
    let left = max(x, other.x)
    let top = max(y, other.y)
    return Rect(x: left, y: top, width: min(maxX, other.maxX) - left, height: min(maxY, other.maxY) - top)
  }

  public func contains(x px: Int, y py: Int) -> Bool {
    px >= x && px < maxX && py >= y && py < maxY
  }

  /// Coupe une bande en haut.
  public func splitTop(_ rows: Int) -> (top: Rect, rest: Rect) {
    let rows = min(max(0, rows), height)
    return (Rect(x: x, y: y, width: width, height: rows), Rect(x: x, y: y + rows, width: width, height: height - rows))
  }

  /// Coupe une bande en bas.
  public func splitBottom(_ rows: Int) -> (rest: Rect, bottom: Rect) {
    let rows = min(max(0, rows), height)
    return (Rect(x: x, y: y, width: width, height: height - rows), Rect(x: x, y: maxY - rows, width: width, height: rows))
  }

  /// Coupe une colonne à gauche.
  public func splitLeft(_ columns: Int) -> (left: Rect, rest: Rect) {
    let columns = min(max(0, columns), width)
    return (Rect(x: x, y: y, width: columns, height: height), Rect(x: x + columns, y: y, width: width - columns, height: height))
  }
}

/// La grille qu'on dessine pour une image. Rien n'y part au terminal : c'est
/// `Renderer` qui compare deux grilles et n'écrit que la différence.
public struct Canvas: Sendable {
  public private(set) var width: Int
  public private(set) var height: Int
  public var cells: [Cell]
  /// Où poser le curseur à la fin de l'image, et s'il se voit.
  public var cursor: (x: Int, y: Int)?
  public var cursorShape: CursorShape = .bar
  /// Les adresses des liens OSC 8 de cette image ; l'indice 0 est réservé.
  public private(set) var links: [String] = [""]

  public enum CursorShape: Sendable { case block, bar, underline }

  public init(width: Int, height: Int) {
    self.width = max(0, width)
    self.height = max(0, height)
    cells = Array(repeating: .blank, count: self.width * self.height)
  }

  public var bounds: Rect { Rect(x: 0, y: 0, width: width, height: height) }

  /// Vide la grille sans réallouer.
  public mutating func clear() {
    for index in cells.indices { cells[index] = .blank }
    cursor = nil
    links.removeAll(keepingCapacity: true)
    links.append("")
  }

  public mutating func resize(width: Int, height: Int) {
    self.width = max(0, width)
    self.height = max(0, height)
    cells = Array(repeating: .blank, count: self.width * self.height)
    cursor = nil
  }

  /// Enregistre l'adresse d'un lien et rend l'indice à porter dans le style.
  public mutating func link(_ url: String) -> UInt16 {
    if let index = links.firstIndex(of: url) { return UInt16(index) }
    guard links.count < Int(UInt16.max) else { return 0 }
    links.append(url)
    return UInt16(links.count - 1)
  }

  @inline(__always)
  public subscript(x: Int, y: Int) -> Cell {
    get { cells[y * width + x] }
    set { cells[y * width + x] = newValue }
  }

  /// Remplit un rectangle d'espaces d'un style.
  public mutating func fill(_ rect: Rect, style: Style) {
    let clipped = rect.intersection(bounds)
    guard !clipped.isEmpty else { return }
    let cell = Cell(grapheme: " ", style: style, width: 1)
    for y in clipped.y..<clipped.maxY {
      for x in clipped.x..<clipped.maxX { cells[y * width + x] = cell }
    }
  }

  /// Écrit du texte sur une ligne, sans jamais déborder de `clip`.
  ///
  /// Un graphème large coupé par le bord droit est remplacé par un espace : on
  /// ne laisse jamais une demi-idéogramme que le terminal dessinerait à cheval.
  /// Rend la colonne qui suit le dernier graphème posé.
  @discardableResult
  public mutating func put(_ text: some StringProtocol, x: Int, y: Int, style: Style, clip: Rect? = nil) -> Int {
    let area = (clip ?? bounds).intersection(bounds)
    guard y >= area.y, y < area.maxY else { return x + CellWidth.of(String(text)) }
    var column = x
    for character in text {
      let w = CellWidth.of(character)
      guard w > 0 else { continue }
      if column >= area.maxX { break }
      if column + w > area.maxX {
        if column >= area.x { self[column, y] = Cell(grapheme: " ", style: style, width: 1) }
        column += w
        break
      }
      if column >= area.x {
        breakWideNeighbours(x: column, y: y, width: w)
        if w == 1, let ascii = character.asciiValue {
          self[column, y] = Cell(grapheme: String(UnicodeScalar(ascii)), style: style, width: 1)
        } else {
          self[column, y] = Cell(grapheme: String(character), style: style, width: UInt8(w))
          if w == 2 { self[column + 1, y] = Cell(grapheme: "", style: style, width: 0) }
        }
      } else if column + w > area.x {
        // La moitié droite dépasse du bord gauche : un espace à sa place.
        self[area.x, y] = Cell(grapheme: " ", style: style, width: 1)
      }
      column += w
    }
    return column
  }

  /// Écrit du texte tronqué à `maxWidth` cellules, avec « … » s'il a fallu couper.
  @discardableResult
  public mutating func put(_ text: String, x: Int, y: Int, maxWidth: Int, style: Style, clip: Rect? = nil) -> Int {
    guard maxWidth > 0 else { return x }
    let truncated = TextLayout.truncate(text, to: maxWidth)
    return put(truncated, x: x, y: y, style: style, clip: clip)
  }

  /// Pose une cellule déjà formée (un placeholder d'image, par exemple).
  public mutating func setCell(_ cell: Cell, x: Int, y: Int, clip: Rect? = nil) {
    let area = (clip ?? bounds).intersection(bounds)
    guard area.contains(x: x, y: y) else { return }
    breakWideNeighbours(x: x, y: y, width: Int(max(cell.width, 1)))
    self[x, y] = cell
  }

  /// Change le style d'une zone sans toucher au texte.
  public mutating func restyle(_ rect: Rect, _ transform: (inout Style) -> Void) {
    let clipped = rect.intersection(bounds)
    guard !clipped.isEmpty else { return }
    for y in clipped.y..<clipped.maxY {
      for x in clipped.x..<clipped.maxX { transform(&cells[y * width + x].style) }
    }
  }

  /// Écraser la moitié d'un graphème large laisse l'autre moitié orpheline :
  /// on la remplace par un espace pour que la grille reste cohérente.
  private mutating func breakWideNeighbours(x: Int, y: Int, width w: Int) {
    let row = y * width
    if cells[row + x].isContinuation, x > 0 {
      cells[row + x - 1] = Cell(grapheme: " ", style: cells[row + x - 1].style, width: 1)
    }
    let end = x + w
    if end < width, cells[row + end].isContinuation {
      cells[row + end] = Cell(grapheme: " ", style: cells[row + end].style, width: 1)
    }
  }
}
