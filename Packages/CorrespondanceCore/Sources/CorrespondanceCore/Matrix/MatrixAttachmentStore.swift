import Foundation

/// Pièces jointes Matrix téléchargées dans `~/Library/Caches/Correspondance/matrix/`.
public enum MatrixAttachmentStore {
  /// Calculé une fois : le chemin ne bouge pas, et l'ancienne version créait le
  /// dossier à chaque lecture — un appel système par photo affichée.
  public static let directory: URL = {
    let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    let dir = base
      .appendingPathComponent("Correspondance", isDirectory: true)
      .appendingPathComponent("matrix", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }()

  /// Nom de fichier stable dérivé du `mxc://` — un média ne se télécharge qu'une fois.
  public static func fileName(forMXC mxc: String, contentType: String?) -> String {
    let slug = (MatrixClient.parseMXC(mxc).map { "\($0.server)_\($0.mediaID)" } ?? mxc)
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: ":", with: "_")
    return "\(slug).\(fileExtension(for: contentType))"
  }

  public static func existingLocalPath(forMXC mxc: String, contentType: String? = nil) -> String? {
    let exact = directory.appendingPathComponent(fileName(forMXC: mxc, contentType: contentType))
    if FileManager.default.fileExists(atPath: exact.path) { return exact.path }
    // Le type MIME peut avoir changé entre deux passes : on retombe sur le préfixe.
    guard let (server, mediaID) = MatrixClient.parseMXC(mxc) else { return nil }
    let prefix = "\(server)_\(mediaID)."
    guard let match = listing.names(in: directory).first(where: { $0.hasPrefix(prefix) })
    else { return nil }
    return directory.appendingPathComponent(match).path
  }

  /// Le repli par préfixe listait tout le dossier des médias à chaque appel — et
  /// il est appelé depuis le corps des vues, une fois par photo et à chaque
  /// recomposition. La liste est gardée, et relue seulement quand le dossier
  /// change de date, c'est-à-dire quand un média y est déposé.
  private static let listing = DirectoryListing()

  private final class DirectoryListing: @unchecked Sendable {
    private let lock = NSLock()
    private var stamp: Date?
    private var names: [String] = []

    func names(in directory: URL) -> [String] {
      let current = (try? FileManager.default.attributesOfItem(atPath: directory.path))?[.modificationDate] as? Date
      lock.lock()
      defer { lock.unlock() }
      if let stamp, let current, stamp == current { return names }
      names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
      stamp = current
      return names
    }
  }

  @discardableResult
  public static func store(data: Data, forMXC mxc: String, contentType: String?) -> String? {
    let url = directory.appendingPathComponent(fileName(forMXC: mxc, contentType: contentType))
    do {
      // Le dossier peut avoir été vidé depuis le lancement (nettoyage des caches).
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try data.write(to: url, options: [.atomic])
      return url.path
    } catch {
      return nil
    }
  }

  public static func fileExtension(for contentType: String?) -> String {
    switch contentType {
    case "image/jpeg": "jpg"
    case "image/png": "png"
    case "image/gif": "gif"
    case "image/webp": "webp"
    case "image/heic": "heic"
    case "video/mp4": "mp4"
    case "video/quicktime": "mov"
    case "audio/ogg": "ogg"
    case "audio/mp4", "audio/m4a", "audio/aac": "m4a"
    case "audio/wav", "audio/x-wav": "wav"
    case "application/pdf": "pdf"
    default: "bin"
    }
  }
}

/// Photos de profil / de groupe des portails, dans leur propre dossier.
/// Séparées des pièces jointes : elles se remplacent (une par salon, écrasée quand
/// le `mxc` change) là où une pièce jointe s'accumule.
public enum MatrixAvatarStore {
  public static var directory: URL {
    let dir = MatrixAttachmentStore.directory.appendingPathComponent("avatars", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  /// Nom stable dérivé du `mxc://` : une photo inchangée ne se retélécharge jamais,
  /// et une photo changée porte un autre `mxc`, donc un autre fichier.
  private static func fileName(forMXC mxc: String) -> String {
    (MatrixClient.parseMXC(mxc).map { "\($0.server)_\($0.mediaID)" } ?? mxc)
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: ":", with: "_")
  }

  public static func existingData(forMXC mxc: String) -> Data? {
    let url = directory.appendingPathComponent(fileName(forMXC: mxc))
    guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
    return data
  }

  public static func store(data: Data, forMXC mxc: String) {
    try? data.write(to: directory.appendingPathComponent(fileName(forMXC: mxc)), options: [.atomic])
  }
}
