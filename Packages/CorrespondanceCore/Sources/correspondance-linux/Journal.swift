import Foundation

/// Le journal, sous Linux : `OSLog` n'existe pas, la sortie d'erreur suffit —
/// c'est ce que `journalctl --user` ou un terminal montrent.
///
/// L'interpolation avec `privacy:` du `Logger` d'Apple est acceptée et
/// ignorée, pour que le magasin porté de l'iPhone se lise sans retouche.
struct Journal: Sendable {
  let category: String

  func notice(_ message: JournalMessage) { write("notice", message) }
  func error(_ message: JournalMessage) { write("error", message) }
  func info(_ message: JournalMessage) { write("info", message) }
  func debug(_ message: JournalMessage) {
    if ProcessInfo.processInfo.environment["CORRESPONDANCE_DEBUG"] != nil { write("debug", message) }
  }

  private func write(_ level: String, _ message: JournalMessage) {
    let stamp = Journal.formatter.string(from: Date())
    FileHandle.standardError.write(Data("\(stamp) [\(category)] \(level): \(message.text)\n".utf8))
  }

  private static let formatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
  }()
}

struct JournalMessage: ExpressibleByStringInterpolation, ExpressibleByStringLiteral {
  var text: String
  init(stringLiteral value: String) { text = value }
  init(stringInterpolation: Interpolation) { text = stringInterpolation.output }

  struct Interpolation: StringInterpolationProtocol {
    var output = ""
    init(literalCapacity: Int, interpolationCount: Int) { output.reserveCapacity(literalCapacity) }
    mutating func appendLiteral(_ literal: String) { output += literal }
    mutating func appendInterpolation<T>(_ value: T) { output += "\(value)" }
    mutating func appendInterpolation<T>(_ value: T, privacy: JournalPrivacy) { output += "\(value)" }
  }
}

enum JournalPrivacy { case `public`, `private` }
