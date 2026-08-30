import Foundation
import CorrespondanceCore

/// Messages programmés, persistés dans Application Support — comme les
/// brouillons, un seul fichier JSON dans `Correspondance/`.
///
/// Rien ne part quand l'app ne tourne pas : c'est la limite assumée de
/// Beeper aussi (« Send Later messages can only send if the app is running »).
/// Au relancement, les échéances passées partent aussitôt.
enum ScheduledMessageStore {
  private static var fileURL: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    let dir = base.appendingPathComponent("Correspondance", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("scheduled-messages.json")
  }

  static func load() -> [ScheduledMessage] {
    guard let data = try? Data(contentsOf: fileURL),
          let decoded = try? decoder.decode([ScheduledMessage].self, from: data)
    else { return [] }
    return sanitized(decoded)
  }

  static func save(_ messages: [ScheduledMessage]) {
    guard let data = try? encoder.encode(sanitized(messages)) else { return }
    try? data.write(to: fileURL, options: [.atomic])
  }

  /// Écarte les pièces jointes disparues et les messages devenus vides, trie par échéance.
  static func sanitized(_ messages: [ScheduledMessage]) -> [ScheduledMessage] {
    messages.compactMap { message -> ScheduledMessage? in
      var cleaned = message
      cleaned.attachmentPaths = message.attachmentPaths.filter { FileManager.default.fileExists(atPath: $0) }
      let hasText = !cleaned.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      guard hasText || !cleaned.attachmentPaths.isEmpty else { return nil }
      return cleaned
    }
    .sorted { $0.sendAt < $1.sendAt }
  }

  private static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  private static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
