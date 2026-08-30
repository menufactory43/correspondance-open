import AppKit
import Foundation
import ImageIO

/// Vignettes des photos d'un fil.
///
/// Une photo d'iPhone fait 12 Mpx : la décoder pleine résolution pour l'afficher
/// dans une bulle de 280 points coûte ~48 Mo de bitmap et plusieurs dizaines de
/// millisecondes. Fait sur le fil principal, à chaque recomposition et pour
/// chaque photo d'une conversation, c'est la roue multicolore.
///
/// Le store fait deux choses : il sous-échantillonne à la taille réellement
/// affichée (ImageIO lit l'en-tête et ne décode que ce qu'il faut), et il le
/// fait hors du fil principal. Le résultat est gardé en mémoire, donc une bulle
/// déjà vue se réaffiche sans rien relire.
@MainActor
final class AttachmentThumbnailStore {
  static let shared = AttachmentThumbnailStore()

  /// NSImage n'est pas `Sendable` : cette boîte la fait traverser le retour de
  /// tâche. La vignette est immuable une fois construite et n'est ensuite
  /// touchée que sur le fil principal.
  private struct Box: @unchecked Sendable {
    let image: NSImage
  }

  private let cache = NSCache<NSString, NSImage>()
  /// Deux bulles qui demandent la même photo en même temps ne la décodent
  /// qu'une fois (fil et fenêtre Focus affichent le même fichier).
  private var inflight: [String: Task<NSImage?, Never>] = [:]

  private init() {
    // Une vignette de 640 px ≈ 1,6 Mo : 240 vignettes ≈ 400 Mo au pire, et le
    // système vide le cache avant d'en arriver là.
    cache.countLimit = 240
  }

  /// Vignette prête à afficher, ou `nil` si le fichier n'est pas une image
  /// lisible (fichier absent, format inconnu, média encore en cours de
  /// téléchargement par un pont).
  ///
  /// - Parameter maxPixel: plus grand côté voulu, **en pixels** — donc la taille
  ///   d'affichage multipliée par l'échelle de l'écran.
  func thumbnail(for url: URL, maxPixel: CGFloat) async -> NSImage? {
    let key = Self.cacheKey(url: url, maxPixel: maxPixel)
    if let hit = cache.object(forKey: key as NSString) { return hit }
    if let running = inflight[key] { return await running.value }

    let task = Task<NSImage?, Never>.detached(priority: .userInitiated) {
      Self.downsample(url: url, maxPixel: maxPixel).map(Box.init(image:))?.image
    }
    inflight[key] = task
    let image = await task.value
    inflight[key] = nil
    if let image {
      cache.setObject(image, forKey: key as NSString)
    }
    return image
  }

  /// La clé porte la date de modification et la taille du fichier : un média
  /// remplacé sur disque (pont qui finit son téléchargement) ne ressort pas
  /// avec l'ancienne vignette.
  private static func cacheKey(url: URL, maxPixel: CGFloat) -> String {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
    return "\(url.path)|\(modified)|\(size)|\(Int(maxPixel))"
  }

  /// Décodage hors fil principal, borné à `maxPixel`. `ShouldCache: false` sur
  /// la source évite de garder l'image pleine résolution en mémoire ;
  /// `ShouldCacheImmediately` sur la vignette la décode ici plutôt qu'au premier
  /// affichage, c'est-à-dire hors du fil principal.
  private nonisolated static func downsample(url: URL, maxPixel: CGFloat) -> NSImage? {
    let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
    guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
      return nil
    }
    let thumbnailOptions: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      // Une photo prise à la verticale porte son orientation en métadonnée :
      // sans cette clé, elle s'affiche couchée.
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
      source, 0, thumbnailOptions as CFDictionary
    ) else {
      return nil
    }
    return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
  }
}
