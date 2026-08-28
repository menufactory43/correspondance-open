import Foundation

enum SignalAttachmentStore {
  /// Dossier où signal-cli dépose les pièces jointes téléchargées.
  static var attachmentsDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".local/share/signal-cli/attachments", isDirectory: true)
  }

  static func localPath(forAttachmentID id: String) -> String? {
    let candidates = [
      attachmentsDirectory.appendingPathComponent(id),
      attachmentsDirectory.appendingPathComponent(id).appendingPathExtension("jpg"),
      attachmentsDirectory.appendingPathComponent(id).appendingPathExtension("jpeg"),
      attachmentsDirectory.appendingPathComponent(id).appendingPathExtension("png"),
      attachmentsDirectory.appendingPathComponent(id).appendingPathExtension("webp"),
      attachmentsDirectory.appendingPathComponent(id).appendingPathExtension("gif"),
    ]
    for url in candidates where FileManager.default.fileExists(atPath: url.path) {
      return url.path
    }
    // Parfois le fichier est stocké tel quel sans extension, id seul.
    if let items = try? FileManager.default.contentsOfDirectory(atPath: attachmentsDirectory.path) {
      if let match = items.first(where: { $0 == id || $0.hasPrefix(id) }) {
        return attachmentsDirectory.appendingPathComponent(match).path
      }
    }
    return nil
  }

  static func parseAttachments(from dataMessage: [String: Any]) -> [MessageAttachment] {
    guard let raw = dataMessage["attachments"] as? [[String: Any]] else { return [] }
    return raw.compactMap { item in
      let id: String = {
        if let s = item["id"] as? String { return s }
        if let n = item["id"] as? NSNumber { return n.stringValue }
        if let i = item["id"] as? Int { return String(i) }
        if let i = item["id"] as? Int64 { return String(i) }
        return ""
      }()
      guard !id.isEmpty else { return nil }
      let contentType = (item["contentType"] as? String) ?? "application/octet-stream"
      let filename = item["filename"] as? String
      let path = localPath(forAttachmentID: id)
      return MessageAttachment(
        id: id,
        contentType: contentType,
        filename: filename,
        localPath: path
      )
    }
  }
}
