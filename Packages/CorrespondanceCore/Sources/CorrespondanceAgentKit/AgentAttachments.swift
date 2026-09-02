import CorrespondanceMatrixClient
import Foundation

/// Ce qu'un message apporte en plus de son texte : une photo, un vocal, un PDF.
///
/// Un agent est un utilisateur Matrix : il a le droit de télécharger le média
/// d'un salon où il est. Le tour reçoit donc des **fichiers sur le disque**, et
/// le prompt leur nomme un chemin — c'est la seule forme qu'un moteur sait lire,
/// qu'il parle ACP ou `claude -p`.
public struct AgentAttachment: Sendable, Equatable {
  /// L'URI du média, ou `nil` quand la pièce est chiffrée (`content.file`) :
  /// on sait alors qu'elle existe sans pouvoir la lire, et on le dit.
  public var mxc: String?
  public var filename: String
  public var mimeType: String
  /// La taille annoncée par l'expéditeur (`info.size`), quand elle est là.
  public var size: Int?

  public var isEncrypted: Bool { mxc == nil }

  public init(mxc: String?, filename: String, mimeType: String, size: Int? = nil) {
    self.mxc = mxc
    self.filename = filename
    self.mimeType = mimeType
    self.size = size
  }

  /// Lit la pièce jointe d'un `content` de `m.room.message`.
  ///
  /// MSC2530 : quand `filename` est là, il porte le nom et `body` devient la
  /// **légende** — c'est dans la légende que se trouve le déclencheur.
  public static func read(from content: MatrixJSON?, msgtype: String) -> AgentAttachment? {
    guard let content, Self.mediaTypes.contains(msgtype) else { return nil }
    let mxc = content.string(at: "url")
    // Chiffrée : `content.file.url` porte l'URI, mais la clé est dans `file`.
    // On la déclare sans la lire plutôt que de faire comme si de rien n'était.
    let encrypted = content.string(at: "file.url")
    guard mxc != nil || encrypted != nil else { return nil }
    let body = content.string(at: "body") ?? ""
    let name = content.string(at: "filename") ?? (body.isEmpty ? nil : body)
    return AgentAttachment(
      mxc: mxc,
      filename: sanitize(name ?? defaultName(for: msgtype)),
      mimeType: content.string(at: "info.mimetype") ?? fallbackMime(for: msgtype),
      size: content.int(at: "info.size")
    )
  }

  /// La légende d'un média, s'il en a une. Certains ponts recopient le nom du
  /// fichier dans `body` : ce n'est pas une légende.
  public static func caption(from content: MatrixJSON?, msgtype: String) -> String {
    guard let content, Self.mediaTypes.contains(msgtype) else { return "" }
    guard let filename = content.string(at: "filename"), !filename.isEmpty else { return "" }
    let body = content.string(at: "body") ?? ""
    return (body.isEmpty || body == filename) ? "" : body
  }

  public static let mediaTypes: Set<String> = ["m.image", "m.audio", "m.video", "m.file"]

  static func defaultName(for msgtype: String) -> String {
    switch msgtype {
    case "m.image": "image"
    case "m.audio": "audio"
    case "m.video": "video"
    default: "fichier"
    }
  }

  static func fallbackMime(for msgtype: String) -> String {
    switch msgtype {
    case "m.image": "image/jpeg"
    case "m.audio": "audio/ogg"
    case "m.video": "video/mp4"
    default: "application/octet-stream"
    }
  }

  /// Un nom de fichier venu du réseau ne touche jamais le disque tel quel :
  /// `../../.ssh/authorized_keys` est un nom de fichier valide pour Matrix.
  static func sanitize(_ name: String) -> String {
    let base = name.split(separator: "/").last.map(String.init) ?? name
    let cleaned = base.map { character -> Character in
      character.isLetter || character.isNumber || character == "." || character == "-" || character == "_"
        ? character : "-"
    }
    let trimmed = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
    return trimmed.isEmpty ? "piece-jointe" : String(trimmed.prefix(120))
  }
}

/// Pose les pièces jointes d'un tour sur le disque, et dit au moteur où elles
/// sont.
public enum AgentAttachmentDrop {
  /// Au-delà, on ne télécharge pas : un tour n'a pas à tirer une vidéo de
  /// 200 Mio dans le dossier d'une room, et aucun moteur ne la lirait.
  public static let tailleMax = 25 * 1024 * 1024

  /// Le sous-dossier du tour, sous le dossier de travail de la room. Nommé par
  /// l'event : deux photos du même nom dans deux messages ne s'écrasent pas.
  public static func directory(cwd: String, eventID: String) -> URL {
    URL(fileURLWithPath: cwd)
      .appending(path: "pieces-jointes")
      .appending(path: AgentAttachment.sanitize(eventID))
  }

  /// Ce que le prompt gagne. Vide s'il n'y a rien à dire.
  public static func promptSection(_ lines: [String]) -> String {
    guard !lines.isEmpty else { return "" }
    return """
      Pièces jointes du message, déjà téléchargées sur ce disque :
      \(lines.joined(separator: "\n"))

      """
  }

  /// Télécharge ce qui peut l'être et rend les lignes à mettre en tête du
  /// prompt. Ce qui ne peut pas être lu — chiffré, trop gros, en échec — est
  /// **dit** plutôt que tu : un moteur qui ignore une photo qu'on lui montre
  /// répond à côté sans que personne ne sache pourquoi. Ces mêmes lignes vont
  /// au journal : elles suffisent à comprendre après coup.
  public static func drop(
    _ attachments: [AgentAttachment],
    eventID: String,
    cwd: String,
    download: (String) async throws -> Data
  ) async -> [String] {
    guard !attachments.isEmpty else { return [] }
    let dir = directory(cwd: cwd, eventID: eventID)
    var lines: [String] = []
    for (index, piece) in attachments.enumerated() {
      if piece.isEncrypted {
        lines.append("- \(piece.filename) (\(piece.mimeType)) — chiffrée, illisible pour l'instant")
        continue
      }
      if let size = piece.size, size > tailleMax {
        lines.append("- \(piece.filename) (\(piece.mimeType)) — \(size / 1_048_576) Mio, trop lourde pour être ouverte")
        continue
      }
      guard let mxc = piece.mxc else { continue }
      do {
        let data = try await download(mxc)
        guard data.count <= tailleMax else {
          lines.append("- \(piece.filename) (\(piece.mimeType)) — \(data.count / 1_048_576) Mio, trop lourde pour être ouverte")
          continue
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Deux pièces du même nom dans un seul message : on numérote.
        let name = lines.contains(where: { $0.contains("/\(piece.filename) ") })
          ? "\(index)-\(piece.filename)" : piece.filename
        let url = dir.appending(path: name)
        try data.write(to: url, options: .atomic)
        lines.append("- \(url.path()) (\(piece.mimeType))")
      } catch {
        lines.append("- \(piece.filename) (\(piece.mimeType)) — téléchargement impossible : \(error.localizedDescription)")
      }
    }
    return lines
  }
}
