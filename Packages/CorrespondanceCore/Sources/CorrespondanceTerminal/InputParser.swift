/// Une touche, telle que le terminal la décrit.
public struct KeyEvent: Hashable, Sendable {
  public enum Key: Hashable, Sendable {
    case character(Character)
    case enter, tab, backspace, escape
    case up, down, left, right
    case home, end, pageUp, pageDown, insert, delete
    case function(Int)
  }

  public struct Modifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let shift = Modifiers(rawValue: 1 << 0)
    public static let alt = Modifiers(rawValue: 1 << 1)
    public static let control = Modifiers(rawValue: 1 << 2)
    public static let `super` = Modifiers(rawValue: 1 << 3)
  }

  public var key: Key
  public var modifiers: Modifiers

  public init(_ key: Key, _ modifiers: Modifiers = []) {
    self.key = key
    self.modifiers = modifiers
  }

  /// Une lettre avec Contrôle — `KeyEvent.control("c")`.
  public static func control(_ character: Character) -> KeyEvent {
    KeyEvent(.character(character), .control)
  }

  public static func char(_ character: Character) -> KeyEvent {
    KeyEvent(.character(character))
  }
}

public struct MouseEvent: Hashable, Sendable {
  public enum Kind: Hashable, Sendable {
    case press(button: Int)
    case release(button: Int)
    case drag(button: Int)
    case move
    case scrollUp, scrollDown, scrollLeft, scrollRight
  }

  public var kind: Kind
  /// Colonne et ligne, à partir de 0.
  public var x: Int
  public var y: Int
  public var modifiers: KeyEvent.Modifiers
}

/// Ce que le terminal nous envoie.
public enum InputEvent: Hashable, Sendable {
  case key(KeyEvent)
  case paste(String)
  case mouse(MouseEvent)
  case focus(Bool)
  /// Réponse à une requête du protocole graphique Kitty : `i=<id>` et message.
  case graphicsReply(id: Int, message: String)
  /// Réponse à `CSI ? u` : le protocole clavier Kitty est compris.
  case keyboardProtocolFlags(Int)
  /// Réponse à DA1 (`CSI c`) — sert de butée aux sondages.
  case primaryDeviceAttributes
  /// Réponse à DECRQM : un mode privé et son état (1 levé, 2 baissé, 0 inconnu…).
  case modeReport(mode: Int, value: Int)
  /// Réponse à `CSI 16 t` : taille d'une cellule en pixels.
  case cellPixelSize(width: Int, height: Int)
}

/// Découpe le flux d'octets de l'entrée standard en événements.
///
/// Sans état caché : on lui donne des octets, il rend les événements complets
/// et garde le reste pour l'appel suivant. Une séquence d'échappement coupée
/// entre deux lectures se recolle donc toute seule.
public struct InputParser: Sendable {
  private var pending: [UInt8] = []
  private var pasteBuffer: [UInt8]?

  public init() {}

  /// Vrai quand il reste un ESC seul en attente : l'appelant décide, après un
  /// court délai, que c'était la touche Échap (`flushLoneEscape`).
  public var hasLoneEscape: Bool { pending == [0x1B] }

  public mutating func flushLoneEscape() -> [InputEvent] {
    guard hasLoneEscape else { return [] }
    pending.removeAll()
    return [.key(KeyEvent(.escape))]
  }

  public mutating func feed(_ bytes: some Sequence<UInt8>) -> [InputEvent] {
    pending.append(contentsOf: bytes)
    var events: [InputEvent] = []
    var index = 0
    let count = pending.count

    while index < count {
      if pasteBuffer != nil {
        // Collage entre crochets : tout est texte jusqu'à `ESC [ 201 ~`.
        let terminator: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]
        if let end = find(terminator, from: index) {
          pasteBuffer!.append(contentsOf: pending[index..<end])
          events.append(.paste(String(decoding: pasteBuffer!, as: UTF8.self)))
          pasteBuffer = nil
          index = end + terminator.count
          continue
        }
        // Garde de quoi reconnaître un terminateur coupé en deux.
        let safe = max(index, count - (terminator.count - 1))
        pasteBuffer!.append(contentsOf: pending[index..<safe])
        index = safe
        break
      }

      let byte = pending[index]
      if byte == 0x1B {
        guard index + 1 < count else { break } // ESC seul : on attend la suite
        let next = pending[index + 1]
        switch next {
        case UInt8(ascii: "["):
          guard let (event, length) = parseCSI(from: index + 2) else {
            if isIncomplete(from: index + 2, terminatorRange: 0x40...0x7E) { break }
            index += 2
            continue
          }
          if let event { events.append(event) }
          index += 2 + length
          continue
        case UInt8(ascii: "O"):
          guard index + 2 < count else { break }
          if let event = ss3(pending[index + 2]) { events.append(event) }
          index += 3
          continue
        case UInt8(ascii: "_"), UInt8(ascii: "]"), UInt8(ascii: "P"):
          // APC (graphiques Kitty), OSC, DCS : jusqu'à ST (`ESC \`) ou BEL.
          guard let (end, stLength) = findStringTerminator(from: index + 2) else { break }
          if next == UInt8(ascii: "_") {
            if let event = parseAPC(pending[(index + 2)..<end]) { events.append(event) }
          }
          index = end + stLength
          continue
        case 0x1B:
          // ESC ESC : Alt+Échap, ou une Échap pressée deux fois.
          events.append(.key(KeyEvent(.escape, .alt)))
          index += 2
          continue
        default:
          // Alt + une touche : ESC suivi de la touche.
          let (decoded, length) = decodeKey(at: index + 1)
          guard length > 0 else { break }
          if var key = decoded {
            key.modifiers.insert(.alt)
            events.append(.key(key))
          }
          index += 1 + length
          continue
        }
        break
      }

      let (decoded, length) = decodeKey(at: index)
      guard length > 0 else { break }
      if let decoded { events.append(.key(decoded)) }
      index += length
    }

    pending.removeFirst(index)
    return events
  }

  // MARK: - Octets simples

  private func decodeKey(at index: Int) -> (KeyEvent?, Int) {
    let byte = pending[index]
    switch byte {
    case 0x0D, 0x0A: return (KeyEvent(.enter), 1)
    case 0x09: return (KeyEvent(.tab), 1)
    case 0x7F, 0x08: return (KeyEvent(.backspace), 1)
    case 0x00: return (KeyEvent(.character(" "), .control), 1)
    case 0x01...0x1A: return (KeyEvent(.character(Character(UnicodeScalar(byte + 0x60))), .control), 1)
    case 0x1C...0x1F: return (KeyEvent(.character(Character(UnicodeScalar(byte + 0x40))), .control), 1)
    case 0x20..<0x80: return (KeyEvent(.character(Character(UnicodeScalar(byte)))), 1)
    default:
      // UTF-8 : la longueur se lit dans le premier octet.
      let length: Int
      switch byte {
      case 0xC0...0xDF: length = 2
      case 0xE0...0xEF: length = 3
      case 0xF0...0xF7: length = 4
      default: return (nil, 1)
      }
      guard index + length <= pending.count else { return (nil, 0) }
      let text = String(decoding: pending[index..<(index + length)], as: UTF8.self)
      guard let character = text.first else { return (nil, length) }
      return (KeyEvent(.character(character)), length)
    }
  }

  private func ss3(_ byte: UInt8) -> InputEvent? {
    switch byte {
    case UInt8(ascii: "A"): return .key(KeyEvent(.up))
    case UInt8(ascii: "B"): return .key(KeyEvent(.down))
    case UInt8(ascii: "C"): return .key(KeyEvent(.right))
    case UInt8(ascii: "D"): return .key(KeyEvent(.left))
    case UInt8(ascii: "H"): return .key(KeyEvent(.home))
    case UInt8(ascii: "F"): return .key(KeyEvent(.end))
    case UInt8(ascii: "P"): return .key(KeyEvent(.function(1)))
    case UInt8(ascii: "Q"): return .key(KeyEvent(.function(2)))
    case UInt8(ascii: "R"): return .key(KeyEvent(.function(3)))
    case UInt8(ascii: "S"): return .key(KeyEvent(.function(4)))
    default: return nil
    }
  }

  // MARK: - CSI

  /// Rend l'événement (ou `nil` pour une séquence reconnue mais sans intérêt)
  /// et la longueur consommée après `ESC [`. `nil` tout court : incomplète ou illisible.
  private mutating func parseCSI(from start: Int) -> (InputEvent?, Int)? {
    var index = start
    // Paramètres (0x30–0x3F), intermédiaires (0x20–0x2F), final (0x40–0x7E).
    while index < pending.count, (0x30...0x3F).contains(pending[index]) { index += 1 }
    let paramsEnd = index
    while index < pending.count, (0x20...0x2F).contains(pending[index]) { index += 1 }
    guard index < pending.count else { return nil }
    let final = pending[index]
    guard (0x40...0x7E).contains(final) else { return nil }
    let intermediates = Array(pending[paramsEnd..<index])
    let raw = String(decoding: pending[start..<paramsEnd], as: UTF8.self)
    let length = index - start + 1

    var prefix: Character?
    var body = Substring(raw)
    if let first = body.first, "<=>?".contains(first) {
      prefix = first
      body = body.dropFirst()
    }
    // Chaque paramètre peut porter des sous-paramètres séparés par « : ».
    let params: [[Int?]] = body.split(separator: ";", omittingEmptySubsequences: false).map { field in
      field.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
    }
    func param(_ i: Int, _ sub: Int = 0, default value: Int) -> Int {
      guard i < params.count, sub < params[i].count, let v = params[i][sub] else { return value }
      return v
    }

    if intermediates == [UInt8(ascii: "$")], final == UInt8(ascii: "y"), prefix == "?" {
      return (.modeReport(mode: param(0, default: 0), value: param(1, default: 0)), length)
    }
    guard intermediates.isEmpty else { return (nil, length) }

    switch (prefix, final) {
    case ("<", UInt8(ascii: "M")), ("<", UInt8(ascii: "m")):
      return (mouse(code: param(0, default: 0), x: param(1, default: 1), y: param(2, default: 1), released: final == UInt8(ascii: "m")), length)
    case ("?", UInt8(ascii: "u")):
      return (.keyboardProtocolFlags(param(0, default: 0)), length)
    case ("?", UInt8(ascii: "c")):
      return (.primaryDeviceAttributes, length)
    case (nil, UInt8(ascii: "t")) where param(0, default: 0) == 6:
      return (.cellPixelSize(width: param(2, default: 0), height: param(1, default: 0)), length)
    case (nil, UInt8(ascii: "I")):
      return (.focus(true), length)
    case (nil, UInt8(ascii: "O")):
      return (.focus(false), length)
    case (nil, UInt8(ascii: "u")):
      return (kittyKey(params: params), length)
    case (nil, UInt8(ascii: "~")):
      let number = param(0, default: 0)
      if number == 200 {
        pasteBuffer = []
        return (nil, length)
      }
      let modifiers = Self.modifiers(param(1, default: 1))
      let key: KeyEvent.Key?
      switch number {
      case 1, 7: key = .home
      case 2: key = .insert
      case 3: key = .delete
      case 4, 8: key = .end
      case 5: key = .pageUp
      case 6: key = .pageDown
      case 11...15: key = .function(number - 10)
      case 17...21: key = .function(number - 11)
      case 23, 24: key = .function(number - 12)
      default: key = nil
      }
      return (key.map { .key(KeyEvent($0, modifiers)) }, length)
    case (nil, _):
      let modifiers = Self.modifiers(param(1, default: 1))
      let key: KeyEvent.Key?
      switch final {
      case UInt8(ascii: "A"): key = .up
      case UInt8(ascii: "B"): key = .down
      case UInt8(ascii: "C"): key = .right
      case UInt8(ascii: "D"): key = .left
      case UInt8(ascii: "H"): key = .home
      case UInt8(ascii: "F"): key = .end
      case UInt8(ascii: "P"): key = .function(1)
      case UInt8(ascii: "Q"): key = .function(2)
      case UInt8(ascii: "S"): key = .function(4)
      case UInt8(ascii: "Z"): return (.key(KeyEvent(.tab, .shift)), length)
      default: key = nil
      }
      return (key.map { .key(KeyEvent($0, modifiers)) }, length)
    default:
      return (nil, length)
    }
  }

  /// `CSI code[:shifted[:base]] ; modifiers[:event] ; text u` — le protocole
  /// clavier de Kitty, que Ghostty, WezTerm et foot parlent aussi. Il lève
  /// les ambiguïtés du clavier historique : Échap n'est plus un préfixe,
  /// Maj+Entrée existe, Ctrl+I n'est plus Tab.
  private func kittyKey(params: [[Int?]]) -> InputEvent? {
    guard let code = params.first?.first ?? nil else { return nil }
    let modifierField = params.count > 1 ? params[1] : []
    let modifiers = Self.modifiers(modifierField.first.flatMap { $0 } ?? 1)
    // 3 = relâchement : on ne s'en sert pas.
    if modifierField.count > 1, modifierField[1] == 3 { return nil }
    let key: KeyEvent.Key
    switch code {
    case 13: key = .enter
    case 9: key = .tab
    case 127, 8: key = .backspace
    case 27: key = .escape
    case 57399...57425:
      // Pavé numérique : chiffres et opérateurs.
      let map: [Int: Character] = [57399: "0", 57400: "1", 57401: "2", 57402: "3", 57403: "4", 57404: "5", 57405: "6", 57406: "7", 57407: "8", 57408: "9", 57409: ".", 57410: "/", 57411: "*", 57412: "-", 57413: "+", 57415: "="]
      if code == 57414 { key = .enter } else if let c = map[code] { key = .character(c) } else { return nil }
    case 57441...57454:
      return nil // Maj, Ctrl, Alt… pressées seules
    default:
      guard let scalar = UnicodeScalar(code) else { return nil }
      var character = Character(scalar)
      // Avec Maj, le terminal donne la touche de base : on montre la lettre majuscule.
      if modifiers.contains(.shift), params[0].count > 1, let shifted = params[0][1], let s = UnicodeScalar(shifted) {
        character = Character(s)
        return .key(KeyEvent(.character(character), modifiers.subtracting(.shift)))
      }
      if modifiers.contains(.shift), character.isLetter {
        return .key(KeyEvent(.character(Character(character.uppercased())), modifiers.subtracting(.shift)))
      }
      key = .character(character)
    }
    return .key(KeyEvent(key, modifiers))
  }

  private static func modifiers(_ encoded: Int) -> KeyEvent.Modifiers {
    let bits = max(0, encoded - 1)
    var result: KeyEvent.Modifiers = []
    if bits & 1 != 0 { result.insert(.shift) }
    if bits & 2 != 0 { result.insert(.alt) }
    if bits & 4 != 0 { result.insert(.control) }
    if bits & 8 != 0 { result.insert(.super) }
    return result
  }

  private func mouse(code: Int, x: Int, y: Int, released: Bool) -> InputEvent {
    var modifiers: KeyEvent.Modifiers = []
    if code & 4 != 0 { modifiers.insert(.shift) }
    if code & 8 != 0 { modifiers.insert(.alt) }
    if code & 16 != 0 { modifiers.insert(.control) }
    let button = code & 3
    let kind: MouseEvent.Kind
    if code & 64 != 0 {
      switch button {
      case 0: kind = .scrollUp
      case 1: kind = .scrollDown
      case 2: kind = .scrollLeft
      default: kind = .scrollRight
      }
    } else if code & 32 != 0 {
      kind = button == 3 ? .move : .drag(button: button)
    } else {
      kind = released ? .release(button: button) : .press(button: button)
    }
    return .mouse(MouseEvent(kind: kind, x: x - 1, y: y - 1, modifiers: modifiers))
  }

  // MARK: - Chaînes de contrôle

  private func parseAPC(_ bytes: ArraySlice<UInt8>) -> InputEvent? {
    // `G i=31;OK` — seul le protocole graphique nous répond par APC.
    guard bytes.first == UInt8(ascii: "G") else { return nil }
    let text = String(decoding: bytes.dropFirst(), as: UTF8.self)
    let parts = text.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
    var id = 0
    for pair in (parts.first ?? "").split(separator: ",") {
      let kv = pair.split(separator: "=", maxSplits: 1)
      if kv.count == 2, kv[0] == "i", let value = Int(kv[1]) { id = value }
    }
    return .graphicsReply(id: id, message: parts.count > 1 ? String(parts[1]) : "")
  }

  private func find(_ needle: [UInt8], from start: Int) -> Int? {
    guard needle.count <= pending.count - start else { return nil }
    var index = start
    while index <= pending.count - needle.count {
      if pending[index] == needle[0], pending[index..<(index + needle.count)].elementsEqual(needle) { return index }
      index += 1
    }
    return nil
  }

  private func findStringTerminator(from start: Int) -> (Int, Int)? {
    var index = start
    while index < pending.count {
      if pending[index] == 0x07 { return (index, 1) }
      if pending[index] == 0x1B, index + 1 < pending.count, pending[index + 1] == UInt8(ascii: "\\") { return (index, 2) }
      index += 1
    }
    return nil
  }

  private func isIncomplete(from start: Int, terminatorRange: ClosedRange<UInt8>) -> Bool {
    var index = start
    while index < pending.count {
      let byte = pending[index]
      if terminatorRange.contains(byte) { return false }
      if !(0x20...0x3F).contains(byte) { return false }
      index += 1
    }
    return true
  }
}
