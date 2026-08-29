import Foundation

/// Pièces jointes Matrix téléchargées dans `~/Library/Caches/Correspondance/matrix/`.
enum MatrixAttachmentStore {
  static var directory: URL {
    let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    let dir = base
      .appendingPathComponent("Correspondance", isDirectory: true)
      .appendingPathComponent("matrix", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  /// Nom de fichier stable dérivé du `mxc://` — un média ne se télécharge qu'une fois.
  static func fileName(forMXC mxc: String, contentType: String?) -> String {
    let slug = (MatrixClient.parseMXC(mxc).map { "\($0.server)_\($0.mediaID)" } ?? mxc)
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: ":", with: "_")
    return "\(slug).\(fileExtension(for: contentType))"
  }

  static func existingLocalPath(forMXC mxc: String, contentType: String? = nil) -> String? {
    let exact = directory.appendingPathComponent(fileName(forMXC: mxc, contentType: contentType))
    if FileManager.default.fileExists(atPath: exact.path) { return exact.path }
    // Le type MIME peut avoir changé entre deux passes : on retombe sur le préfixe.
    guard let (server, mediaID) = MatrixClient.parseMXC(mxc) else { return nil }
    let prefix = "\(server)_\(mediaID)."
    guard let items = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
          let match = items.first(where: { $0.hasPrefix(prefix) })
    else { return nil }
    return directory.appendingPathComponent(match).path
  }

  @discardableResult
  static func store(data: Data, forMXC mxc: String, contentType: String?) -> String? {
    let url = directory.appendingPathComponent(fileName(forMXC: mxc, contentType: contentType))
    do {
      try data.write(to: url, options: [.atomic])
      return url.path
    } catch {
      return nil
    }
  }

  static func fileExtension(for contentType: String?) -> String {
    switch contentType {
    case "image/jpeg": "jpg"
    case "image/png": "png"
    case "image/gif": "gif"
    case "image/webp": "webp"
    case "image/heic": "heic"
    case "video/mp4": "mp4"
    case "video/quicktime": "mov"
    case "audio/ogg": "ogg"
    case "application/pdf": "pdf"
    default: "bin"
    }
  }
}
