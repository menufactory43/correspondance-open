// Sous Linux, pas de CoreGraphics : la mosaïque des visages est dessinée par l'interface web.
#if canImport(CoreGraphics)
import CoreGraphics
import Foundation

/// Compose une mosaïque de visages, comme Messages, WhatsApp ou Instagram le font
/// pour un groupe sans photo à lui.
///
/// Le résultat est un PNG : le store d'avatars ne manipule que des `Data`, et une
/// vignette composée doit pouvoir passer par les mêmes caches qu'une photo reçue.
/// Struct pure, sans réseau ni disque — c'est ce qui la rend testable telle quelle.
public struct AvatarMosaic {
  /// Rendu à 2× : une liste affiche ces disques en 34–44 pt sur un écran Retina,
  /// et une mosaïque rendue à 1× y baverait.
  private static let scale: CGFloat = 2

  /// `nil` quand il n'y a rien à montrer — l'appelant retombe alors sur les initiales.
  /// Une seule image donne le disque seul : c'est déjà la bonne réponse.
  public static func compose(_ images: [PlatformImage], size: CGFloat, separator: PlatformColor) -> Data? {
    composeImage(images, size: size, separator: separator)?.pngData()
  }

  /// La même mosaïque, sans passer par un PNG : ce qu'une vue affiche tout de
  /// suite. L'aller-retour PNG (encoder, puis redécoder) coûtait un tiers du
  /// temps de défilement sur l'iPhone.
  public static func composeImage(_ images: [PlatformImage], size: CGFloat, separator: PlatformColor) -> CGImage? {
    guard !images.isEmpty, size > 0 else { return nil }
    let tiles = Array(images.prefix(4))
    let side = Int((size * Self.scale).rounded())
    guard side > 0,
          let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
    else { return nil }

    let edge = CGFloat(side)
    let strokeWidth = 1.5 * Self.scale
    let frames = layout(count: tiles.count).map { frame in
      // Les gabarits sont écrits en repère écran (origine en haut à gauche) ;
      // CoreGraphics compte de bas en haut.
      CGRect(
        x: frame.minX * edge,
        y: (1 - frame.maxY) * edge,
        width: frame.width * edge,
        height: frame.height * edge
      )
    }

    for (index, frame) in frames.enumerated() {
      // Les disques qui viennent par-dessus portent un liseré couleur papier :
      // sans lui deux photos sombres se fondent l'une dans l'autre.
      if index > 0 {
        context.setFillColor(separator.deviceRGBCGColor)
        context.fillEllipse(in: frame.insetBy(dx: -strokeWidth, dy: -strokeWidth))
      }
      draw(tiles[index], in: frame, context: context)
    }

    return context.makeImage()
  }

  /// Gabarits en carré unité, repère écran. Les tailles suivent Messages :
  /// deux disques se chevauchent en diagonale, trois font une pyramide,
  /// quatre une grille bien rangée.
  private static func layout(count: Int) -> [CGRect] {
    switch count {
    case 1:
      return [CGRect(x: 0, y: 0, width: 1, height: 1)]
    case 2:
      let d: CGFloat = 0.62
      return [
        CGRect(x: 0, y: 0, width: d, height: d),
        CGRect(x: 1 - d, y: 1 - d, width: d, height: d),
      ]
    case 3:
      let d: CGFloat = 0.54
      return [
        CGRect(x: (1 - d) / 2, y: 0, width: d, height: d),
        CGRect(x: 0, y: 1 - d, width: d, height: d),
        CGRect(x: 1 - d, y: 1 - d, width: d, height: d),
      ]
    default:
      let d: CGFloat = 0.48
      let far = 1 - d
      return [
        CGRect(x: 0, y: 0, width: d, height: d),
        CGRect(x: far, y: 0, width: d, height: d),
        CGRect(x: 0, y: far, width: d, height: d),
        CGRect(x: far, y: far, width: d, height: d),
      ]
    }
  }

  /// Une tuile : disque plein, image recadrée au centre sans jamais l'étirer.
  private static func draw(_ image: PlatformImage, in frame: CGRect, context: CGContext) {
    guard let cgImage = image.cgImage(fitting: frame) else { return }
    let width = CGFloat(cgImage.width)
    let height = CGFloat(cgImage.height)
    guard width > 0, height > 0 else { return }
    // `scaledToFill` : on couvre le disque, quitte à perdre les bords du plus grand côté.
    let ratio = max(frame.width / width, frame.height / height)
    let drawn = CGSize(width: width * ratio, height: height * ratio)

    context.saveGState()
    context.addEllipse(in: frame)
    context.clip()
    context.draw(
      cgImage,
      in: CGRect(
        x: frame.midX - drawn.width / 2,
        y: frame.midY - drawn.height / 2,
        width: drawn.width,
        height: drawn.height
      )
    )
    context.restoreGState()
  }
}

#endif
