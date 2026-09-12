/// Transforme une grille en octets pour le terminal — seulement ce qui a changé.
///
/// Les pratiques qui font qu'une TUI paraît aussi fluide que le terminal qui
/// la montre (Ghostty, Kitty) :
///
/// - **Différentiel** : on garde la grille de l'image précédente et on n'écrit
///   que les cellules qui diffèrent. Un message qui arrive coûte une poignée
///   d'octets, pas un écran.
/// - **Sortie synchronisée** (mode 2026) : l'image entière est encadrée par
///   `CSI ? 2026 h` / `l`. Le terminal l'applique d'un bloc, jamais à moitié
///   dessinée — pas de déchirure, même sur un gros défilement.
/// - **Un seul `write`** par image, dans un tampon réutilisé : pas d'allocation
///   par image, pas de syscall par cellule.
/// - **Stylo suivi** : on sait quels attributs SGR le terminal a en tête, et on
///   n'en réémet que la différence ; même chose pour la position du curseur,
///   qu'on ne déplace que quand l'écriture ne l'a pas déjà amené au bon endroit.
/// - **Pas de retour à la ligne automatique** (DECAWM coupé) : écrire la
///   dernière colonne ne fait jamais défiler l'écran.
public struct Renderer: Sendable {
  private var front: Canvas
  /// Vrai quand le terminal ne ressemble plus à `front` (redimensionnement,
  /// reprise après ^Z, ^L) : la prochaine image repeint tout.
  private var invalidated = true
  private var buffer: [UInt8] = []

  /// Le terminal comprend-il le mode 2026 ? S'il ne le connaît pas, il l'ignore
  /// sans dommage : on l'émet donc toujours, sauf demande contraire.
  public var synchronizedOutput = true
  /// OSC 8 : les liens sont cliquables. Sans effet visible là où il n'est pas compris.
  public var hyperlinks = true

  public init() {
    front = Canvas(width: 0, height: 0)
    buffer.reserveCapacity(64 * 1024)
  }

  /// Oublie ce que montre le terminal : la prochaine image est complète.
  public mutating func invalidate() { invalidated = true }

  /// Les octets qui amènent le terminal de l'image précédente à `canvas`.
  /// Vide si rien n'a changé, curseur compris.
  public mutating func render(_ canvas: Canvas, extraPrefix: [UInt8] = []) -> [UInt8] {
    buffer.removeAll(keepingCapacity: true)
    var pen = Pen()
    let full = invalidated || front.width != canvas.width || front.height != canvas.height

    if synchronizedOutput { append("\u{1B}[?2026h") }
    buffer.append(contentsOf: extraPrefix)
    // Le curseur se cache le temps d'écrire : sinon on le voit courir.
    append("\u{1B}[?25l")
    if full {
      append("\u{1B}[0m\u{1B}[2J")
      pen.style = .plain
    }

    var wroteCells = false
    var cursorX = -1
    var cursorY = -1
    let width = canvas.width
    for y in 0..<canvas.height {
      let row = y * width
      var x = 0
      while x < width {
        let cell = canvas.cells[row + x]
        if cell.isContinuation {
          x += 1
          continue
        }
        let span = Int(max(cell.width, 1))
        if !full {
          var same = front.cells[row + x] == cell
          if same, span == 2, x + 1 < width { same = front.cells[row + x + 1] == canvas.cells[row + x + 1] }
          if same {
            x += span
            continue
          }
        }
        if cursorX != x || cursorY != y {
          moveCursor(x: x, y: y)
        }
        applyStyle(cell.style, links: canvas.links, pen: &pen)
        if cell.grapheme.isEmpty {
          buffer.append(0x20)
        } else {
          buffer.append(contentsOf: cell.grapheme.utf8)
        }
        wroteCells = true
        x += span
        cursorX = x
        cursorY = y
      }
    }

    if pen.link != 0 { append("\u{1B}]8;;\u{1B}\\") }
    if pen.style != .plain { append("\u{1B}[0m") }

    if let cursor = canvas.cursor {
      moveCursor(x: cursor.x, y: cursor.y)
      switch canvas.cursorShape {
      case .block: append("\u{1B}[2 q")
      case .underline: append("\u{1B}[4 q")
      case .bar: append("\u{1B}[6 q")
      }
      append("\u{1B}[?25h")
    }
    if synchronizedOutput { append("\u{1B}[?2026l") }

    let cursorChanged = canvas.cursor.map { ($0.x, $0.y) } ?? (-1, -1) != front.cursor.map { ($0.x, $0.y) } ?? (-1, -1)
    let changed = full || wroteCells || cursorChanged || canvas.cursorShape != front.cursorShape || !extraPrefix.isEmpty
    front = canvas
    invalidated = false
    // Même avec le curseur visible, rien n'a bougé : on n'écrit rien du tout.
    return changed ? buffer : []
  }

  // MARK: - Écriture

  private struct Pen {
    var style = Style.plain
    var link: UInt16 = 0
  }

  private mutating func append(_ string: StaticString) {
    string.withUTF8Buffer { buffer.append(contentsOf: $0) }
  }

  private mutating func appendNumber(_ value: Int) {
    if value < 10 {
      buffer.append(UInt8(48 + value))
      return
    }
    var digits: [UInt8] = []
    var rest = value
    while rest > 0 {
      digits.append(UInt8(48 + rest % 10))
      rest /= 10
    }
    buffer.append(contentsOf: digits.reversed())
  }

  private mutating func moveCursor(x: Int, y: Int) {
    append("\u{1B}[")
    appendNumber(y + 1)
    buffer.append(UInt8(ascii: ";"))
    appendNumber(x + 1)
    buffer.append(UInt8(ascii: "H"))
  }

  private mutating func applyStyle(_ style: Style, links: [String], pen: inout Pen) {
    if hyperlinks, style.link != pen.link {
      if style.link == 0 || Int(style.link) >= links.count {
        append("\u{1B}]8;;\u{1B}\\")
        pen.link = 0
      } else {
        append("\u{1B}]8;;")
        buffer.append(contentsOf: links[Int(style.link)].utf8.filter { $0 >= 0x20 && $0 != 0x7F })
        append("\u{1B}\\")
        pen.link = style.link
      }
    }
    var target = style
    target.link = 0
    var current = pen.style
    current.link = 0
    guard target != current else { return }

    append("\u{1B}[")
    // Retirer un attribut n'a pas d'inverse commun à tous (22 éteint gras ET
    // atténué) : dès qu'on en retire un, on repart de zéro. C'est rare.
    let removed = !current.attributes.subtracting(target.attributes).isEmpty
    var first = true
    func separator() {
      if first { first = false } else { buffer.append(UInt8(ascii: ";")) }
    }
    if removed {
      separator(); buffer.append(UInt8(ascii: "0"))
      current = .plain
    }
    let added = target.attributes.subtracting(current.attributes)
    if added.contains(.bold) { separator(); buffer.append(UInt8(ascii: "1")) }
    if added.contains(.dim) { separator(); buffer.append(UInt8(ascii: "2")) }
    if added.contains(.italic) { separator(); buffer.append(UInt8(ascii: "3")) }
    if added.contains(.underline) { separator(); buffer.append(UInt8(ascii: "4")) }
    if added.contains(.reverse) { separator(); buffer.append(UInt8(ascii: "7")) }
    if added.contains(.strikethrough) { separator(); buffer.append(UInt8(ascii: "9")) }
    if target.foreground != current.foreground {
      separator()
      appendColor(target.foreground, base: 30, brightBase: 90, extended: 38, reset: 39)
    }
    if target.background != current.background {
      separator()
      appendColor(target.background, base: 40, brightBase: 100, extended: 48, reset: 49)
    }
    if first { buffer.append(UInt8(ascii: "0")) }
    buffer.append(UInt8(ascii: "m"))
    pen.style = target
    pen.style.link = pen.link
  }

  private mutating func appendColor(_ color: TerminalColor, base: Int, brightBase: Int, extended: Int, reset: Int) {
    switch color {
    case .default:
      appendNumber(reset)
    case .indexed(let index) where index < 8:
      appendNumber(base + Int(index))
    case .indexed(let index) where index < 16:
      appendNumber(brightBase + Int(index) - 8)
    case .indexed(let index):
      appendNumber(extended)
      append(";5;")
      appendNumber(Int(index))
    case .rgb(let r, let g, let b):
      appendNumber(extended)
      append(";2;")
      appendNumber(Int(r))
      buffer.append(UInt8(ascii: ";"))
      appendNumber(Int(g))
      buffer.append(UInt8(ascii: ";"))
      appendNumber(Int(b))
    }
  }
}
