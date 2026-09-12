import Foundation

/// Le journal, sous Linux : `OSLog` n'existe pas, la sortie d'erreur suffit —
/// c'est ce que `journalctl --user` ou un terminal montrent.
///
/// L'interpolation avec `privacy:` du `Logger` d'Apple est acceptée et
/// ignorée, pour que le magasin porté de l'iPhone se lise sans retouche.
package struct Journal: Sendable {
  package let category: String

  package func notice(_ message: JournalMessage) { write("notice", message) }
  package func error(_ message: JournalMessage) { write("error", message) }
  package func info(_ message: JournalMessage) { write("info", message) }
  package func debug(_ message: JournalMessage) {
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

package struct JournalMessage: ExpressibleByStringInterpolation, ExpressibleByStringLiteral {
  package var text: String
  package init(stringLiteral value: String) { text = value }
  package init(stringInterpolation: Interpolation) { text = stringInterpolation.output }

  package struct Interpolation: StringInterpolationProtocol {
    package var output = ""
    package init(literalCapacity: Int, interpolationCount: Int) { output.reserveCapacity(literalCapacity) }
    package mutating func appendLiteral(_ literal: String) { output += literal }
    package mutating func appendInterpolation<T>(_ value: T) { output += "\(value)" }
    package mutating func appendInterpolation<T>(_ value: T, privacy: JournalPrivacy) { output += "\(value)" }
  }
}

package enum JournalPrivacy { case `public`, `private` }
