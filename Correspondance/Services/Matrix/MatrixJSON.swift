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
  func value(at path: String) -> MatrixJSON? {
    path.split(separator: ".").reduce(self as MatrixJSON?) { node, key in
      node?[String(key)]
    }
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
