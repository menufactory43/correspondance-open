import ImageIO
import SwiftUI
import CorrespondanceCore

/// Un GIF qui bouge — la seule image du fil qui ne soit pas figée.
///
/// SwiftUI ne sait pas animer un GIF : `Image` en montre la première trame et
/// s'arrête là. `CGAnimateImageAtURLWithBlock` (ImageIO), lui, existe des deux
/// côtés, respecte les cadences déclarées dans le fichier et le nombre de
/// boucles — c'est le décodeur du système, pas une boucle de `Timer` à nous.
///
/// L'animation s'arrête quand la bulle quitte l'écran, et quand le système
/// demande moins de mouvement (`Reduce Motion`) : le GIF reste alors sur sa
/// première trame, comme une photo.
public struct AnimatedImageView: View {
  public let url: URL
  public var cornerRadius: CGFloat = 12
  public var placeholder: Color
  public var label: String
  /// Taille d'affichage, lue dans l'en-tête du fichier avant tout décodage :
  /// la bulle a sa hauteur définitive dès sa construction, et le fil ancré en
  /// bas ne se replace pas quand la première trame arrive.
  private let fitted: CGSize

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var frame: PlatformImage?
  @State private var isAnimating = false

  public init(
    url: URL,
    maxWidth: CGFloat,
    maxHeight: CGFloat,
    cornerRadius: CGFloat = 12,
    placeholder: Color,
    label: String
  ) {
    self.url = url
    self.cornerRadius = cornerRadius
    self.placeholder = placeholder
    self.label = label
    let size = AttachmentThumbnailStore.shared.pixelSize(for: url) ?? CGSize(width: 4, height: 3)
    let scale = min(maxWidth / size.width, maxHeight / size.height, 1)
    fitted = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
  }

  public var body: some View {
    Group {
      if let frame {
        Image(platformImage: frame)
          .resizable()
          .frame(width: fitted.width, height: fitted.height)
          .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      } else {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .fill(placeholder)
          .frame(width: fitted.width, height: fitted.height)
      }
    }
    .overlay(alignment: .bottomLeading) { badge }
    .accessibilityLabel("GIF, \(label)")
    .onAppear { isAnimating = true }
    .onDisappear { isAnimating = false }
    .task(id: taskKey) { await animate() }
  }

  /// Recommencer l'animation quand la bulle revient, ou quand le réglage change.
  private var taskKey: String { "\(url.path)|\(isAnimating)|\(reduceMotion)" }

  /// Le repère qui dit « ça bouge » sans qu'on ait à le deviner — celui que
  /// Messages pose dans le coin.
  private var badge: some View {
    Text("GIF")
      .font(.system(size: 9, weight: .heavy))
      .foregroundStyle(.white)
      .padding(.horizontal, 4)
      .padding(.vertical, 2)
      .background(Capsule().fill(.black.opacity(0.55)))
      .padding(5)
      .accessibilityHidden(true)
  }

  private func animate() async {
    guard isAnimating, !reduceMotion else {
      // Mouvement réduit : la première trame, et rien d'autre.
      frame = await Self.firstFrame(of: url)
      return
    }
    let stream = AsyncStream<PlatformImage> { continuation in
      CGAnimateImageAtURLWithBlock(url as CFURL, nil) { _, image, stop in
        guard isAnimating else {
          stop.pointee = true
          continuation.finish()
          return
        }
        continuation.yield(PlatformImage.from(cgImage: image))
      }
      continuation.onTermination = { _ in }
    }
    for await image in stream {
      if Task.isCancelled { break }
      frame = image
    }
  }

  /// La première trame, hors du fil principal : c'est ce qu'on montre quand
  /// l'animation est refusée, ou avant qu'elle démarre.
  private static func firstFrame(of url: URL) async -> PlatformImage? {
    await Task.detached(priority: .utility) { () -> PlatformImage? in
      guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
      else { return nil }
      return PlatformImage.from(cgImage: image)
    }.value
  }
}
