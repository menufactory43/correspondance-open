import AppKit
import Foundation
import ImageIO

/// Vignettes des photos d'un fil.
///
/// Une photo d'iPhone fait 12 Mpx : la décoder pleine résolution pour l'afficher
/// dans une bulle de 280 points coûte ~48 Mo de bitmap et une centaine de
/// millisecondes. Fait sur le fil principal, à chaque recomposition et pour
/// chaque photo d'une conversation, c'est la roue multicolore.
///
/// Le store sous-échantillonne à la taille réellement affichée (ImageIO lit
/// l'en-tête et ne décode que ce qu'il faut), le fait hors du fil principal, et
/// garde le résultat. Le cache se lit aussi **de façon synchrone** : une bulle
/// que le `LazyVStack` recycle retrouve sa vignette dès sa construction, donc
/// sans repasser par la case « rectangle gris » — sinon sa hauteur change à
/// chaque recyclage et la mise en page se met à osciller sans fin.
final class AttachmentThumbnailStore: @unchecked Sendable {
  static let shared = AttachmentThumbnailStore()

  /// `NSCache` est sûr entre fils d'exécution : pas de verrou à poser autour.
  private let cache = NSCache<NSString, NSImage>()
  private let sizes = NSCache<NSString, NSValue>()
  private let worker = ThumbnailWorker()

  private init() {
    // Une vignette de 640 px ≈ 1,6 Mo : 240 vignettes ≈ 400 Mo au pire, et le
    // système vide le cache avant d'en arriver là.
    cache.countLimit = 240
    // Une taille pèse seize octets : on peut en garder beaucoup.
    sizes.countLimit = 4_000
  }

  /// Dimensions de la photo, **sans la décoder** : ImageIO lit l'en-tête du
  /// fichier, quelques dizaines de microsecondes, et le résultat est gardé.
  ///
  /// C'est ce qui permet à la bulle de connaître sa hauteur définitive dès sa
  /// construction. Le fil est ancré en bas : toute hauteur qui change en cours
  /// de route oblige SwiftUI à retraduire l'ancre et à replacer tout le monde,
  /// ce qui découvre d'autres photos, qui changent de hauteur à leur tour. Une
  /// conversation chargée de photos n'en sortait jamais.
  func pixelSize(for url: URL) -> CGSize? {
    let key = Self.cacheKey(url: url, maxPixel: 0) as NSString
    if let known = sizes.object(forKey: key) { return known.sizeValue }
    guard let size = Self.readPixelSize(url: url) else { return nil }
    sizes.setObject(NSValue(size: size), forKey: key)
    return size
  }

  /// L'en-tête donne les dimensions du capteur ; l'orientation EXIF dit s'il
  /// faut les échanger. Une photo verticale est stockée couchée.
  private static func readPixelSize(url: URL) -> CGSize? {
    let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
    guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
          let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
          width > 0, height > 0
    else { return nil }
    let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    let quarterTurned = (5...8).contains(orientation)
    return quarterTurned
      ? CGSize(width: height, height: width)
      : CGSize(width: width, height: height)
  }

  /// Vignette déjà en mémoire, sans rien décoder. Sert à construire la vue dans
  /// son état final du premier coup.
  func cached(for url: URL, maxPixel: CGFloat) -> NSImage? {
    cache.object(forKey: Self.cacheKey(url: url, maxPixel: maxPixel) as NSString)
  }

  /// Vignette prête à afficher, ou `nil` si le fichier n'est pas une image
  /// lisible (fichier absent, format inconnu, média encore en cours de
  /// téléchargement par un pont).
  ///
  /// - Parameter maxPixel: plus grand côté voulu, **en pixels** — donc la taille
  ///   d'affichage multipliée par l'échelle de l'écran.
  func thumbnail(for url: URL, maxPixel: CGFloat) async -> NSImage? {
    let key = Self.cacheKey(url: url, maxPixel: maxPixel) as NSString
    if let hit = cache.object(forKey: key) { return hit }
    let image = await worker.decode(url: url, maxPixel: maxPixel) { [self] in
      // Deux vues peuvent demander le même fichier (le fil et la fenêtre
      // Focus) : celle qui passe en second récupère ce que la première a
      // décodé plutôt que de recommencer.
      cached(for: url, maxPixel: maxPixel)
    }
    if let image {
      cache.setObject(image, forKey: key)
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

  /// Décodage borné à `maxPixel`. `ShouldCache: false` sur la source évite de
  /// garder l'image pleine résolution en mémoire ; `ShouldCacheImmediately` sur
  /// la vignette la décode ici plutôt qu'au premier affichage, c'est-à-dire hors
  /// du fil principal.
  fileprivate static func downsample(url: URL, maxPixel: CGFloat) -> NSImage? {
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

/// Le décodeur des vignettes : **un seul fichier à la fois**, et en pile plutôt
/// qu'en file.
///
/// Un seul à la fois parce qu'une photo HEIC se décode par le décodeur vidéo du
/// système : lancer cinquante décodages de front épuise le pool de sessions de
/// VideoToolbox, qui se bloque alors sur un XPC synchrone — plus aucune vignette
/// ne revient jamais. Le goulot est voulu.
///
/// En pile parce que SwiftUI construit le fil du haut vers le bas alors que le
/// regard est en bas : la dernière vignette demandée est celle qu'on est en
/// train de regarder, elle passe donc devant.
private final class ThumbnailWorker: @unchecked Sendable {
  private struct Job {
    let url: URL
    let maxPixel: CGFloat
    let alreadyDone: @Sendable () -> NSImage?
    let resume: @Sendable (NSImage?) -> Void
  }

  private let queue = DispatchQueue(label: "app.correspondance.thumbnails", qos: .userInitiated)
  private let lock = NSLock()
  private var pending: [Job] = []
  private var draining = false

  func decode(
    url: URL,
    maxPixel: CGFloat,
    alreadyDone: @escaping @Sendable () -> NSImage?
  ) async -> NSImage? {
    await withCheckedContinuation { continuation in
      let job = Job(url: url, maxPixel: maxPixel, alreadyDone: alreadyDone) {
        continuation.resume(returning: $0)
      }
      lock.lock()
      pending.append(job)
      let shouldStart = !draining
      draining = true
      lock.unlock()
      if shouldStart {
        queue.async { [weak self] in self?.drain() }
      }
    }
  }

  private func drain() {
    while true {
      lock.lock()
      guard let job = pending.popLast() else {
        draining = false
        lock.unlock()
        return
      }
      lock.unlock()
      if let done = job.alreadyDone() {
        job.resume(done)
      } else {
        job.resume(AttachmentThumbnailStore.downsample(url: job.url, maxPixel: job.maxPixel))
      }
    }
  }
}
