import Foundation

/// Le texte enfoui dans une archive `typedstream` (NeXTSTEP), format que Messages
/// utilise encore pour `message.attributedBody` et pour chaque version d'un
/// message modifié. `NSUnarchiver` sait le lire mais n'existe plus en Swift ;
/// on n'a de toute façon besoin que de la chaîne, pas des attributs.
///
/// Structure repérée : … `NSString` 01 94 84 01 `+` <longueur> <utf8> …
/// La longueur est un entier typedstream : 1 octet si < 0x81, sinon 0x81 + 2
/// octets (petit-boutiste) ou 0x82 + 4 octets.
enum TypedStreamText {
  static func string(in data: Data) -> String? {
    let bytes = [UInt8](data)
    guard let marker = firstRange(of: Array("NSString".utf8), in: bytes) else { return nil }

    // Le marqueur de type « chaîne C » (`+`) précède immédiatement la longueur.
    var index = marker
    while index < bytes.count, bytes[index] != 0x2B { index += 1 }
    guard index + 1 < bytes.count else { return nil }
    index += 1

    guard let (length, start) = readLength(bytes, at: index),
          length > 0,
          start + length <= bytes.count
    else { return nil }

    return String(bytes: bytes[start..<(start + length)], encoding: .utf8)
  }

  private static func readLength(_ bytes: [UInt8], at index: Int) -> (length: Int, next: Int)? {
    guard index < bytes.count else { return nil }
    switch bytes[index] {
    case 0x81:
      guard index + 2 < bytes.count else { return nil }
      let value = Int(bytes[index + 1]) | (Int(bytes[index + 2]) << 8)
      return (value, index + 3)
    case 0x82:
      guard index + 4 < bytes.count else { return nil }
      var value = 0
      for offset in 1...4 { value |= Int(bytes[index + offset]) << (8 * (offset - 1)) }
      return (value, index + 5)
    case let byte where byte < 0x81:
      return (Int(byte), index + 1)
    default:
      return nil
    }
  }

  private static func firstRange(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
    guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
    for start in 0...(haystack.count - needle.count) {
      if Array(haystack[start..<(start + needle.count)]) == needle {
        return start + needle.count
      }
    }
    return nil
  }
}

/// `message.message_summary_info` : un plist binaire qui garde, entre autres,
/// l'historique des modifications d'un message.
///
/// Forme observée sur macOS 26 :
/// `ec` → { "<index de partie>": [ { "d": date, "t": <typedstream> }, … ] },
/// la dernière entrée d'une partie étant la version courante (celle de `text`).
enum IMessageSummaryInfo {
  /// Toutes les versions du message, dans l'ordre chronologique.
  static func editedVersions(from data: Data) -> [String] {
    guard let plist = try? PropertyListSerialization.propertyList(
      from: data, options: [], format: nil
    ) as? [String: Any],
      let edits = plist["ec"] as? [String: Any]
    else { return [] }

    // Les parties sont numérotées par des clés textuelles : on les remet en ordre.
    var versions: [(part: Int, date: Double, text: String)] = []
    for (rawPart, rawEntries) in edits {
      let part = Int(rawPart) ?? 0
      guard let entries = rawEntries as? [[String: Any]] else { continue }
      for (offset, entry) in entries.enumerated() {
        guard let blob = entry["t"] as? Data,
              let text = TypedStreamText.string(in: blob)
        else { continue }
        let date = (entry["d"] as? Double) ?? Double(offset)
        versions.append((part, date, text))
      }
    }

    return versions
      .sorted { ($0.part, $0.date) < ($1.part, $1.date) }
      .map(\.text)
  }

  /// Versions *antérieures* : l'historique montré au survol, la version courante
  /// étant déjà dans la bulle.
  static func editHistory(from data: Data, currentText: String) -> [String] {
    var versions = editedVersions(from: data)
    let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
    if versions.last?.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed {
      versions.removeLast()
    }
    return versions
  }
}
