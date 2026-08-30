import Foundation

/// Brouillons par conversation, persistés dans Application Support.
///
/// Le fichier suit la même convention que les autres caches (`Correspondance/`),
/// pour qu'effacer un dossier suffise à tout remettre à zéro.
public enum DraftStore {
  public struct Draft: Codable, Sendable, Equatable {
    public var text: String
    /// Chemins locaux des pièces jointes en attente.
    public var attachmentPaths: [String]

    public var isEmpty: Bool {
      text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachmentPaths.isEmpty
    }

    public init(text: String = "", attachmentPaths: [String] = []) {
      self.text = text
      self.attachmentPaths = attachmentPaths
    }
  }

  private static var fileURL: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    let dir = base.appendingPathComponent("Correspondance", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("drafts.json")
  }

  public static func load() -> [String: Draft] {
    guard let data = try? Data(contentsOf: fileURL),
          let decoded = try? JSONDecoder().decode([String: Draft].self, from: data)
    else { return [:] }
    return sanitized(decoded)
  }

  public static func save(_ drafts: [String: Draft]) {
    guard let data = try? JSONEncoder().encode(sanitized(drafts)) else { return }
    try? data.write(to: fileURL, options: [.atomic])
  }

  /// Jette les brouillons vides et les pièces jointes disparues du disque :
  /// restaurer un chemin mort ferait échouer l'envoi sans rien expliquer.
  public static func sanitized(_ drafts: [String: Draft]) -> [String: Draft] {
    var result: [String: Draft] = [:]
    for (id, draft) in drafts {
      var cleaned = draft
      cleaned.attachmentPaths = draft.attachmentPaths.filter {
        FileManager.default.fileExists(atPath: $0)
      }
      guard !cleaned.isEmpty else { continue }
      result[id] = cleaned
    }
    return result
  }
}
