import CorrespondanceCore
import CorrespondanceRelayStore
import CorrespondanceTerminal
import Foundation

/// Les images du fil, côté terminal.
///
/// Une pièce jointe passe par trois états : on ne sait pas la montrer, sa
/// vignette se fabrique, elle est prête. Prête, elle reçoit un identifiant
/// 24 bits (celui que portent les couleurs de ses placeholders) et une
/// placement virtuelle à la taille demandée ; changer de taille — un
/// redimensionnement — ne retransmet que la placement.
@MainActor
final class ImageManager {
  struct Ready: Hashable {
    let id: UInt32
    let pixelWidth: Int
    let pixelHeight: Int
  }

  enum State: Equatable {
    case unavailable
    case loading
    case ready(Ready)
  }

  var isEnabled = false {
    didSet { if isEnabled != oldValue { onChange?() } }
  }
  var onChange: (() -> Void)?

  private let thumbnailer: Thumbnailer
  private let transmission: KittyGraphics.Transmission
  private var thumbnails: [String: Thumbnailer.Thumbnail?] = [:]
  private var loading: Set<String> = []
  private var ids: [String: UInt32] = [:]
  private var paths: [UInt32: String] = [:]
  /// Ce que le terminal a reçu : identifiant → (fichier, colonnes, lignes).
  private var placed: [UInt32: (path: String, columns: Int, rows: Int)] = [:]
  private var pending: [UInt8] = []

  init(directory: URL, transmission: KittyGraphics.Transmission) {
    thumbnailer = Thumbnailer(directory: directory)
    self.transmission = transmission
  }

  /// L'état d'une pièce jointe ; lance la vignette si elle manque.
  func state(for attachment: MessageAttachment) -> State {
    guard isEnabled, attachment.isImage || attachment.isVideo,
          let source = attachment.resolvedFileURL?.path
    else { return .unavailable }
    if let known = thumbnails[source] {
      guard let thumbnail = known else { return .unavailable }
      return .ready(Ready(id: id(for: thumbnail.path), pixelWidth: thumbnail.pixelWidth, pixelHeight: thumbnail.pixelHeight))
    }
    if !loading.contains(source) {
      loading.insert(source)
      let isVideo = attachment.isVideo
      Task { @MainActor [weak self] in
        guard let self else { return }
        let result = await self.thumbnailer.thumbnail(for: source, isVideo: isVideo)
        self.loading.remove(source)
        self.thumbnails[source] = .some(result)
        self.onChange?()
      }
    }
    return .loading
  }

  /// La taille en cellules d'une image, dans une boîte d'au plus `maxColumns`×`maxRows`.
  static func cellSize(for ready: Ready, maxColumns: Int, maxRows: Int, cellWidth: Double, cellHeight: Double) -> (columns: Int, rows: Int) {
    let columns = Double(ready.pixelWidth) / cellWidth
    let rows = Double(ready.pixelHeight) / cellHeight
    let scale = min(1, Double(maxColumns) / max(columns, 1), Double(maxRows) / max(rows, 1))
    let limit = KittyGraphics.maxPlaceholderIndex + 1
    return (
      min(limit, max(1, Int((columns * scale).rounded()))),
      min(limit, max(1, Int((rows * scale).rounded())))
    )
  }

  /// S'assure que le terminal a l'image à cette taille ; la commande part
  /// avec la prochaine image de l'écran, avant ses cellules.
  func place(_ ready: Ready, columns: Int, rows: Int) {
    guard let path = paths[ready.id] else { return }
    if let existing = placed[ready.id], existing.columns == columns, existing.rows == rows { return }
    if placed[ready.id] != nil { pending += KittyGraphics.delete(id: ready.id) }
    pending += KittyGraphics.transmit(pngAt: path, id: ready.id, columns: columns, rows: rows, transmission: transmission)
    placed[ready.id] = (path, columns, rows)
  }

  func takePendingBytes() -> [UInt8] {
    defer { pending.removeAll(keepingCapacity: true) }
    return pending
  }

  /// Après un ^Z ou un changement de terminal : tout est à renvoyer.
  func retransmitAll() {
    let previous = placed
    placed.removeAll()
    for (id, placement) in previous {
      pending += KittyGraphics.transmit(pngAt: placement.path, id: id, columns: placement.columns, rows: placement.rows, transmission: transmission)
      placed[id] = placement
    }
  }

  func deleteAll() -> [UInt8] {
    var bytes: [UInt8] = []
    for id in placed.keys { bytes += KittyGraphics.delete(id: id) }
    placed.removeAll()
    return bytes
  }

  /// Un identifiant 24 bits stable par vignette, sans collision dans la session.
  private func id(for path: String) -> UInt32 {
    if let known = ids[path] { return known }
    var hash: UInt32 = 2166136261
    for byte in path.utf8 { hash = (hash ^ UInt32(byte)) &* 16777619 }
    var candidate = (hash & 0xFFFFFF) | 0x010000 // jamais un identifiant trop petit
    while paths[candidate] != nil { candidate = ((candidate + 1) & 0xFFFFFF) | 0x010000 }
    paths[candidate] = path
    ids[path] = candidate
    return candidate
  }
}
