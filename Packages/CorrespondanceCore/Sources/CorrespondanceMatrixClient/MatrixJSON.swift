import Foundation

/// JSON dynamique et `Sendable` — le `content` d'un event Matrix n'a pas de schéma fixe.
/// Évite `[String: Any]` (non `Sendable`) que Swift 6 refuse de traverser un `actor`.
public enum MatrixJSON: Codable, Hashable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([MatrixJSON])
  case object([String: MatrixJSON])

  public init(from decoder: Decoder) throws {
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

  public func encode(to encoder: Encoder) throws {
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

  public subscript(key: String) -> MatrixJSON? {
    guard case .object(let dict) = self else { return nil }
    return dict[key]
  }

  /// Chemin pointé : `json.value(at: "protocol.id")`.
  ///
  /// Beaucoup de clés Matrix contiennent elles-mêmes des points (`m.relates_to`,
  /// `m.new_content`, `fi.mau.whatsapp.phone_number`) : découper bêtement sur `.`
  /// ne trouverait jamais `m.relates_to.rel_type`. On essaie donc, à chaque niveau,
  /// les préfixes du plus long au plus court.
  public func value(at path: String) -> MatrixJSON? {
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

  public var stringValue: String? {
    if case .string(let v) = self { return v }
    return nil
  }

  public var intValue: Int? {
    if case .number(let v) = self { return Int(v) }
    return nil
  }

  /// Le nombre tel quel. Les temps Matrix sont des millisecondes : un `Int`
  /// n'aurait pas suffi à les traverser sans perte sur 32 bits.
  public var doubleValue: Double? {
    if case .number(let v) = self { return v }
    return nil
  }

  // MARK: - Ce que Matrix refuse

  /// **Matrix n'accepte aucun flottant dans un event.** Le JSON canonique
  /// (spécification, § Canonical JSON) ne connaît que des entiers ; Synapse
  /// répond `400 Bad JSON value: float` et l'event est perdu.
  ///
  /// Ce n'est pas un caprice d'un event particulier : c'est une règle du
  /// protocole, et c'est pourquoi elle se vérifie ici, une fois, plutôt que
  /// dans chaque constructeur de contenu. Éprouvé au prix fort — le journal des
  /// tours, l'un des trois garde-fous de la pleine permission, n'a jamais
  /// réussi à s'écrire à cause d'une durée en secondes décimales.
  ///
  /// Rend les chemins fautifs, pour que le message dise *quoi* corriger.
  public func nonIntegerNumberPaths(prefix: String = "") -> [String] {
    switch self {
    case .number(let value):
      let entier = value.rounded() == value && value.isFinite
      return entier ? [] : [prefix.isEmpty ? "(racine)" : prefix]
    case .array(let items):
      return items.enumerated().flatMap { index, item in
        item.nonIntegerNumberPaths(prefix: "\(prefix)[\(index)]")
      }
    case .object(let fields):
      return fields.sorted { $0.key < $1.key }.flatMap { key, value in
        value.nonIntegerNumberPaths(prefix: prefix.isEmpty ? key : "\(prefix).\(key)")
      }
    case .null, .bool, .string:
      return []
    }
  }

  /// Un entier, tel que Matrix l'accepte. À préférer à `.number(Double(x))`
  /// quand la valeur vient d'un calcul : une durée, un horodatage, un compte.
  public static func integer(_ value: Int) -> MatrixJSON { .number(Double(value)) }

  public var boolValue: Bool? {
    if case .bool(let v) = self { return v }
    return nil
  }

  public var arrayValue: [MatrixJSON]? {
    if case .array(let v) = self { return v }
    return nil
  }

  public var objectValue: [String: MatrixJSON]? {
    if case .object(let v) = self { return v }
    return nil
  }

  /// Chaîne au chemin donné, en ignorant les vides.
  public func bool(at path: String) -> Bool? {
    value(at: path)?.boolValue
  }

  public func double(at path: String) -> Double? {
    value(at: path)?.doubleValue
  }

  public func int(at path: String) -> Int? {
    value(at: path)?.intValue
  }

  public func string(at path: String) -> String? {
    guard let raw = value(at: path)?.stringValue else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
