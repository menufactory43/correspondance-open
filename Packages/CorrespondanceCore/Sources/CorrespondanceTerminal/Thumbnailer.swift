import Foundation
#if canImport(ImageIO)
import ImageIO
import UniformTypeIdentifiers
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Fabrique les vignettes PNG que le protocole graphique sait montrer.
///
/// Kitty n'accepte que du PNG (ou des pixels bruts) : une photo JPEG ou HEIC
/// passe donc par ici. Et même un PNG y passe s'il est grand — transmettre une
/// photo de 12 Mpx pour l'afficher sur trente colonnes serait gaspiller la
/// mémoire du terminal et la bande passante d'un SSH.
///
/// - Sur Apple : ImageIO (orientation EXIF appliquée) et AVFoundation pour la
///   première image d'une vidéo, dans le processus.
/// - Ailleurs : `vipsthumbnail`, `magick`/`convert` ou `ffmpeg`, s'il y en a
///   un dans le `PATH` ; sinon, un PNG déjà petit passe tel quel, et le reste
///   se montre en texte.
///
/// Les vignettes vivent dans un cache disque, sous un nom dérivé du chemin, de
/// la date du fichier et de la taille demandée : on ne les refait jamais deux
/// fois, même d'un lancement à l'autre.
public actor Thumbnailer {
  public struct Thumbnail: Sendable, Hashable {
    public let path: String
    public let pixelWidth: Int
    public let pixelHeight: Int
  }

  private let directory: URL
  private let maxPixelSize: Int
  private var memory: [String: Thumbnail?] = [:]
  private var inFlight: [String: Task<Thumbnail?, Never>] = [:]
  /// Deux vignettes à la fois : le décodage est lourd, l'écran n'attend pas.
  private var running = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []

  public init(directory: URL, maxPixelSize: Int = 720) {
    self.directory = directory
    self.maxPixelSize = maxPixelSize
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  /// La vignette déjà prête, sans rien lancer.
  public func cached(for source: String) -> Thumbnail?? {
    memory[source]
  }

  /// Rend la vignette d'une image ou d'une vidéo ; `nil` si on ne sait pas la faire.
  public func thumbnail(for source: String, isVideo: Bool) async -> Thumbnail? {
    if let known = memory[source] { return known }
    if let task = inFlight[source] { return await task.value }
    let task = Task { await self.produce(source: source, isVideo: isVideo) }
    inFlight[source] = task
    let result = await task.value
    inFlight[source] = nil
    memory[source] = result
    return result
  }

  private func acquire() async {
    if running < 2 {
      running += 1
      return
    }
    await withCheckedContinuation { waiters.append($0) }
  }

  private func release() {
    if waiters.isEmpty {
      running -= 1
    } else {
      waiters.removeFirst().resume()
    }
  }

  private func produce(source: String, isVideo: Bool) async -> Thumbnail? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: source) else { return nil }
    let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    let key = Self.stableHash("\(source)|\(modified)|\(maxPixelSize)")
    let destination = directory.appendingPathComponent("\(key).png")
    if let existing = PNGSize.read(destination.path) {
      return Thumbnail(path: destination.path, pixelWidth: existing.width, pixelHeight: existing.height)
    }
    await acquire()
    defer { release() }
    let size = maxPixelSize
    let made: Bool = await Task.detached(priority: .utility) {
      Self.render(source: source, isVideo: isVideo, destination: destination, maxPixelSize: size)
    }.value
    if made, let dimensions = PNGSize.read(destination.path) {
      return Thumbnail(path: destination.path, pixelWidth: dimensions.width, pixelHeight: dimensions.height)
    }
    // Un PNG déjà raisonnable se montre tel quel.
    if !isVideo, let dimensions = PNGSize.read(source), max(dimensions.width, dimensions.height) <= size * 2 {
      return Thumbnail(path: source, pixelWidth: dimensions.width, pixelHeight: dimensions.height)
    }
    return nil
  }

  private nonisolated static func render(source: String, isVideo: Bool, destination: URL, maxPixelSize: Int) -> Bool {
    #if canImport(ImageIO)
    let url = URL(fileURLWithPath: source)
    var image: CGImage?
    #if canImport(AVFoundation)
    if isVideo {
      let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
      generator.appliesPreferredTrackTransform = true
      generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
      image = try? generator.copyCGImage(at: .zero, actualTime: nil)
    }
    #endif
    if !isVideo, let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) {
      let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        kCGImageSourceShouldCacheImmediately: false,
      ]
      image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary)
    }
    guard let image,
          let sink = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return false }
    CGImageDestinationAddImage(sink, image, nil)
    return CGImageDestinationFinalize(sink)
    #else
    let out = destination.path
    let box = "\(maxPixelSize)x\(maxPixelSize)"
    if isVideo {
      return run("ffmpeg", ["-v", "quiet", "-y", "-i", source, "-frames:v", "1", "-vf", "scale='min(\(maxPixelSize),iw)':-2", out])
    }
    if run("vipsthumbnail", [source, "--size", "\(maxPixelSize)>", "-o", out]) { return true }
    if run("magick", [source + "[0]", "-auto-orient", "-thumbnail", box + ">", "png:" + out]) { return true }
    if run("convert", [source + "[0]", "-auto-orient", "-thumbnail", box + ">", "png:" + out]) { return true }
    return run("ffmpeg", ["-v", "quiet", "-y", "-i", source, "-frames:v", "1", "-vf", "scale='min(\(maxPixelSize),iw)':-2", out])
    #endif
  }

  #if !canImport(ImageIO)
  private nonisolated static func run(_ tool: String, _ arguments: [String]) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [tool] + arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      process.waitUntilExit()
      return process.terminationStatus == 0
    } catch {
      return false
    }
  }
  #endif

  /// FNV-1a sur 64 bits : stable d'un lancement à l'autre, contrairement à `hashValue`.
  public nonisolated static func stableHash(_ text: String) -> String {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in text.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x100000001b3
    }
    return String(hash, radix: 16)
  }
}

/// Lit la taille d'un PNG dans son en-tête IHDR, sans le décoder.
public enum PNGSize {
  public static func read(_ path: String) -> (width: Int, height: Int)? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }
    guard let header = try? handle.read(upToCount: 24), header.count == 24 else { return nil }
    let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    guard Array(header.prefix(8)) == signature else { return nil }
    let bytes = [UInt8](header)
    let width = Int(bytes[16]) << 24 | Int(bytes[17]) << 16 | Int(bytes[18]) << 8 | Int(bytes[19])
    let height = Int(bytes[20]) << 24 | Int(bytes[21]) << 16 | Int(bytes[22]) << 8 | Int(bytes[23])
    guard width > 0, height > 0 else { return nil }
    return (width, height)
  }
}
