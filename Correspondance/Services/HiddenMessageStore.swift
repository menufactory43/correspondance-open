import Foundation
import CorrespondanceCore

/// Messages « supprimés ici » : le réseau les garde, nous ne les montrons plus.
///
/// Aucun catalogue (chat.db, `/sync`, les caches disque) ne connaît cette
/// suppression — comme l'archivage, elle vit chez nous seule, et se **réapplique**
/// à chaque relecture du fil plutôt que d'être attendue du transport.
/// Un identifiant supprimé pour tout le monde (redaction Matrix) n'a pas besoin
/// d'y figurer : l'event a disparu du salon.
enum HiddenMessageStore {
  private static var fileURL: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    let dir = base.appendingPathComponent("Correspondance", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("hidden-messages.json")
  }

  static func load() -> Set<String> {
    guard let data = try? Data(contentsOf: fileURL),
          let decoded = try? JSONDecoder().decode([String].self, from: data)
    else { return [] }
    return Set(decoded.filter { !$0.isEmpty })
  }

  static func save(_ ids: Set<String>) {
    guard let data = try? JSONEncoder().encode(ids.sorted()) else { return }
    try? data.write(to: fileURL, options: [.atomic])
  }

  /// Retire du fil ce qu'on a supprimé ici. Fonction pure : c'est elle que les
  /// tests exercent, sans store ni réseau.
  static func visible(_ messages: [ChatMessage], hiddenIDs: Set<String>) -> [ChatMessage] {
    guard !hiddenIDs.isEmpty else { return messages }
    return messages.filter { !hiddenIDs.contains($0.id) }
  }
}
