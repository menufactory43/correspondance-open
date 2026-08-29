import Foundation

/// JSON dynamique et `Sendable` — le `content` d'un event Matrix n'a pas de schéma fixe.
/// Évite `[String: Any]` (non `Sendable`) que Swift 6 refuse de traverser un `actor`.
enum MatrixJSON: Codable, Hashable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([MatrixJSON])
  case object([String: MatrixJSON])

  init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
    } else if let v = try? c.decode(Bool.self) {
      self = .bool(v)
    } else if let v = try? c.decode(Double.self) {
      self = .number(v)
    } else if let v = try? c.decode(String.self) {
      self = .string(v)
    } else if let v = try? c.decode([MatrixJSON].self) {
      self = .array(v)
    } else if let v = try? c.decode([String: MatrixJSON].self) {
      self = .object(v)
    } else {
      throw DecodingError.dataCorruptedError(in: c, debugDescription: "JSON Matrix illisible")
    }
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .null: try c.encodeNil()
    case .bool(let v): try c.encode(v)
    case .number(let v): try c.encode(v)
    case .string(let v): try c.encode(v)
    case .array(let v): try c.encode(v)
    case .object(let v): try c.encode(v)
    }
  }

  // MARK: - Accès

  subscript(key: String) -> MatrixJSON? {
    guard case .object(let dict) = self else { return nil }
    return dict[key]
  }

  /// Chemin pointé : `json.value(at: "protocol.id")`.
  ///
  /// Beaucoup de clés Matrix contiennent elles-mêmes des points (`m.relates_to`,
  /// `m.new_content`, `fi.mau.whatsapp.phone_number`) : découper bêtement sur `.`
  /// ne trouverait jamais `m.relates_to.rel_type`. On essaie donc, à chaque niveau,
  /// les préfixes du plus long au plus court.
  func value(at path: String) -> MatrixJSON? {
    Self.resolve(self, path.split(separator: ".").map(String.init))
  }

  private static func resolve(_ node: MatrixJSON, _ components: [String]) -> MatrixJSON? {
    guard !components.isEmpty else { return node }
    guard case .object(let dict) = node else { return nil }
    for length in stride(from: components.count, through: 1, by: -1) {
      let key = components[0..<length].joined(separator: ".")
      guard let child = dict[key] else { continue }
      if let found = resolve(child, Array(components[length...])) { return found }
    }
    return nil
  }

  var stringValue: String? {
    if case .string(let v) = self { return v }
    return nil
  }

  var intValue: Int? {
    if case .number(let v) = self { return Int(v) }
    return nil
  }

  var boolValue: Bool? {
    if case .bool(let v) = self { return v }
    return nil
  }

  var arrayValue: [MatrixJSON]? {
    if case .array(let v) = self { return v }
    return nil
  }

  var objectValue: [String: MatrixJSON]? {
    if case .object(let v) = self { return v }
    return nil
  }

  /// Chaîne au chemin donné, en ignorant les vides.
  func string(at path: String) -> String? {
    guard let raw = value(at: path)?.stringValue else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
