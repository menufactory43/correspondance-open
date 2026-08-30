import Foundation

/// Fusions de contacts, persistées dans Application Support — un seul fichier
/// JSON dans `Correspondance/`, comme les brouillons et les messages programmés.
///
/// Deux choses à retenir d'un lancement à l'autre : les fusions décidées, et
/// les propositions refusées (sinon la même paire reviendrait s'offrir à chaque
/// démarrage).
public enum MergedContactStore {
  public struct Stored: Codable, Equatable, Sendable {
    public var merged: [MergedContact] = []
    public var dismissedPairs: Set<String> = []

    public init(merged: [MergedContact] = [], dismissedPairs: Set<String> = []) {
      self.merged = merged
      self.dismissedPairs = dismissedPairs
    }
  }

  private static var fileURL: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    let dir = base.appendingPathComponent("Correspondance", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("merged-contacts.json")
  }

  public static func load() -> Stored {
    guard let data = try? Data(contentsOf: fileURL),
          let decoded = try? JSONDecoder().decode(Stored.self, from: data)
    else { return Stored() }
    return sanitized(decoded)
  }

  public static func save(_ stored: Stored) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(sanitized(stored)) else { return }
    try? data.write(to: fileURL, options: [.atomic])
  }

  /// Une fusion à moins de deux membres ne fusionne rien : elle ne mérite pas
  /// de survivre au redémarrage.
  public static func sanitized(_ stored: Stored) -> Stored {
    var cleaned = stored
    cleaned.merged = stored.merged.filter { Set($0.memberIDs).count >= 2 }
    return cleaned
  }
}
