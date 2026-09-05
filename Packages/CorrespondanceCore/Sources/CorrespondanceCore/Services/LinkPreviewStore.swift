// Sous Linux, pas de LinkPresentation : les aperçus de liens viennent des ponts seulement.
#if canImport(LinkPresentation)
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import CoreGraphics
import CryptoKit
import Foundation
import LinkPresentation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// LES APERÇUS DE LIENS, cherchés une fois et gardés.
///
/// Même maison que `MatrixAttachmentStore` : un dossier dans les caches, un nom
/// de fichier dérivé de la clé (ici le hachage de l'adresse), et rien qui ne se
/// retéléchargerait deux fois. Trois garde-fous, parce qu'une bulle se
/// redessine à chaque frappe dans le composer :
///
/// - la mémoire répond en premier, le disque ensuite, le réseau en dernier ;
/// - une adresse en cours de route se partage sa tâche (`inFlight`) : dix
///   bulles citant le même lien ne font qu'un appel ;
/// - un échec se retient POUR LA SESSION seulement, jamais sur le disque — une
///   coupure de wifi ne doit pas condamner un lien jusqu'à la fin des temps.
///
/// Échec silencieux : la bulle retombe sur son lien nu, souligné comme avant.
@MainActor
@Observable
public final class LinkPreviewStore {
  public static let shared = LinkPreviewStore()

  /// Ce que la page a une chance de nous répondre avant qu'on renonce.
  /// Court : un aperçu qui arrive après qu'on a fini de lire ne sert à rien.
  public nonisolated static let timeout: TimeInterval = 6

  private var memory: [String: LinkPreview] = [:]
  /// Adresses qu'on a déjà essayées sans succès — on ne réessaie pas.
  private var failed: Set<String> = []
  private var inFlight: [String: Task<LinkPreview?, Never>] = [:]
  /// Vignettes décodées, pour ne pas relire le fichier à chaque recomposition.
  private var thumbnails: [String: PlatformImage] = [:]

  /// Dossier des aperçus. Calculé une fois : le chemin ne bouge pas.
  public nonisolated static let directory: URL = {
    let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    let dir = base
      .appendingPathComponent("Correspondance", isDirectory: true)
      .appendingPathComponent("links", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }()

  /// Nom de fichier stable dérivé de l'adresse. Une URL peut contenir n'importe
  /// quoi (accents, barres, requêtes de trois lignes) : on la hache.
  public nonisolated static func key(for url: URL) -> String {
    let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  /// L'aperçu déjà en mémoire, sans rien déclencher. C'est ce que lit la carte
  /// à chaque rendu : la lecture est observée, la carte se redessine quand
  /// l'aperçu arrive.
  public func cached(for url: URL) -> LinkPreview? {
    memory[Self.key(for: url)]
  }

  /// Lance la recherche sans l'attendre, si rien n'est encore su de l'adresse.
  /// Idempotent et bon marché : une adresse connue, ratée ou en route rend la
  /// main tout de suite. La carte l'appelle à sa naissance — un `.task` posé
  /// sur une carte encore vide ne se déclencherait jamais.
  public func warm(_ url: URL) {
    let key = Self.key(for: url)
    guard memory[key] == nil, !failed.contains(key), inFlight[key] == nil else { return }
    _ = startLoading(url: url, key: key)
  }

  /// L'aperçu de cette adresse, cherché au besoin. `nil` = on ne saura pas.
  public func metadata(for url: URL) async -> LinkPreview? {
    let key = Self.key(for: url)
    if let hit = memory[key] { return hit }
    if failed.contains(key) { return nil }
    if let running = inFlight[key] { return await running.value }
    return await startLoading(url: url, key: key).value
  }

  /// Le disque d'abord, le réseau ensuite ; le résultat se range en mémoire
  /// et la tâche se partage entre toutes les bulles qui citent l'adresse.
  private func startLoading(url: URL, key: String) -> Task<LinkPreview?, Never> {
    let task = Task<LinkPreview?, Never> { [weak self] in
      if let onDisk = Self.readFromDisk(key: key) {
        self?.remember(onDisk, key: key, animated: false)
        return onDisk
      }
      let result = await Self.fetch(url: url, key: key)
      if let result {
        Self.writeToDisk(result, key: key)
        // Le fil est ancré en bas : la carte pousse le contenu sans arracher
        // la lecture. Un fondu suffit à dire qu'elle vient d'arriver.
        self?.remember(result, key: key, animated: true)
      } else {
        self?.failed.insert(key)
      }
      self?.inFlight[key] = nil
      return result
    }
    inFlight[key] = task
    return task
  }

  private func remember(_ preview: LinkPreview, key: String, animated: Bool) {
    guard animated, !Self.reduceMotion else {
      memory[key] = preview
      return
    }
    withAnimation(.easeOut(duration: 0.18)) { memory[key] = preview }
  }

  private static var reduceMotion: Bool {
    #if canImport(AppKit)
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    #else
    UIAccessibility.isReduceMotionEnabled
    #endif
  }

  /// Côté maximal, en pixels, d'une vignette de carte : deux fois la largeur
  /// de la carte, pour un écran Retina. Une image livrée par le pont peut faire
  /// plusieurs mégapixels ; la carte n'en montre jamais plus que ça.
  public nonisolated static let thumbnailMaxPixel: CGFloat = 720

  /// La vignette, décodée une fois pour toutes — et réduite à la taille de la
  /// carte. Un fil de deux cents messages porte des dizaines d'aperçus : les
  /// garder en pleine résolution, c'est des dizaines de mégapixels que le
  /// compositeur remanie à chaque image, et un défilement qui s'alourdit.
  public func thumbnail(atPath path: String) -> PlatformImage? {
    if let hit = thumbnails[path] { return hit }
    let url = URL(fileURLWithPath: path)
    guard let image = AttachmentThumbnailStore.downsample(url: url, maxPixel: Self.thumbnailMaxPixel)
      ?? PlatformImage(contentsOfFile: path)
    else { return nil }
    thumbnails[path] = image
    return image
  }

  // MARK: - Disque

  private nonisolated static func jsonURL(key: String) -> URL {
    directory.appendingPathComponent("\(key).json")
  }

  private nonisolated static func imageURL(key: String) -> URL {
    directory.appendingPathComponent("\(key).png")
  }

  private nonisolated static func readFromDisk(key: String) -> LinkPreview? {
    guard let data = try? Data(contentsOf: jsonURL(key: key)),
          var preview = try? JSONDecoder().decode(LinkPreview.self, from: data)
    else { return nil }
    // Le dossier des caches peut avoir été vidé sous nos pieds : une fiche sans
    // sa vignette vaut mieux qu'une carte trouée.
    if let path = preview.imagePath, !FileManager.default.fileExists(atPath: path) {
      preview.imagePath = nil
    }
    return preview
  }

  private nonisolated static func writeToDisk(_ preview: LinkPreview, key: String) {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    guard let data = try? JSONEncoder().encode(preview) else { return }
    try? data.write(to: jsonURL(key: key), options: [.atomic])
  }

  // MARK: - Réseau

  /// Interroge la page via `LPMetadataProvider`, puis n'en fait traverser que
  /// des valeurs transportables : `LPLinkMetadata` et son fournisseur d'image
  /// ne sont pas `Sendable`, et n'ont aucune raison de quitter leur file.
  private nonisolated static func fetch(url: URL, key: String) async -> LinkPreview? {
    let domain = LinkPreview.domain(of: url)
    guard let raw = await rawMetadata(for: url) else { return nil }
    var preview = LinkPreview(title: raw.title, domain: domain, imagePath: nil)
    if let data = raw.imageData, let path = storeThumbnail(data, key: key) {
      preview.imagePath = path
    }
    guard preview.hasSomethingToShow else { return nil }
    return preview
  }

  /// Le titre et l'image, arrachés au `LPLinkMetadata` avant qu'il ne s'éteigne.
  private struct RawMetadata: Sendable {
    var title: String?
    var imageData: Data?
  }

  private nonisolated static func rawMetadata(for url: URL) async -> RawMetadata? {
    await withCheckedContinuation { (continuation: CheckedContinuation<RawMetadata?, Never>) in
      let once = ResumeOnce()
      let provider = LPMetadataProvider()
      provider.timeout = LinkPreviewStore.timeout
      provider.startFetchingMetadata(for: url) { metadata, _ in
        // `provider` reste vivant tant que ce bloc n'a pas rendu la main.
        withExtendedLifetime(provider) {}
        guard let metadata else {
          if once.claim() { continuation.resume(returning: nil) }
          return
        }
        let title = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let imageProvider = metadata.imageProvider else {
          if once.claim() { continuation.resume(returning: RawMetadata(title: title, imageData: nil)) }
          return
        }
        imageProvider.loadDataRepresentation(
          forTypeIdentifier: UTType.image.identifier
        ) { data, _ in
          if once.claim() {
            continuation.resume(returning: RawMetadata(title: title, imageData: data))
          }
        }
      }
    }
  }

  /// Une continuation ne se reprend qu'une fois — et `LPMetadataProvider` rend
  /// la main sur une file qu'on ne choisit pas, parfois deux fois plutôt qu'une.
  private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
      lock.lock()
      defer { lock.unlock() }
      if claimed { return false }
      claimed = true
      return true
    }
  }

  /// Réduit la vignette avant de la ranger : une image d'article pèse volontiers
  /// deux mégaoctets pour une carte de 320 points de large.
  private nonisolated static func storeThumbnail(_ data: Data, key: String) -> String? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: 720,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    else { return nil }
    guard let png = cg.pngData() else { return nil }
    let url = imageURL(key: key)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    do {
      try png.write(to: url, options: [.atomic])
      return url.path
    } catch {
      return nil
    }
  }
}

#endif
