import AVFoundation
import CorrespondanceCore
import SwiftUI

/// LA MOSAÏQUE d'un message à plusieurs photos. Le découpage vient de
/// `MediaAlbumLayout` — règle pure, testée ; ici il ne reste que de la
/// géométrie : des colonnes de largeurs inégales, deux points de gouttière, et
/// les coins de la bulle sur l'ensemble.
public struct MediaAlbumView: View {
  /// Les images et vidéos du message, dans leur ordre d'envoi.
  public let media: [MessageAttachment]
  public let layout: MediaAlbumLayout
  public var width: CGFloat
  /// Les coins de la bulle, enchaînement compris : une mosaïque au milieu d'une
  /// prise de parole se resserre du même côté que les bulles de texte.
  public var corners: BubbleCorners
  public let theme: WritingTheme
  /// Ouvrir la visionneuse sur la tuile touchée. `nil` = mosaïque inerte.
  public var onOpen: ((Int) -> Void)?

  /// Assez pour séparer deux photos, trop peu pour faire une grille.
  private static let gutter: CGFloat = 2

  public init(
    media: [MessageAttachment],
    layout: MediaAlbumLayout,
    width: CGFloat,
    corners: BubbleCorners,
    theme: WritingTheme,
    onOpen: ((Int) -> Void)? = nil
  ) {
    self.media = media
    self.layout = layout
    self.width = width
    self.corners = corners
    self.theme = theme
    self.onOpen = onOpen
  }

  public var body: some View {
    let content = width - Self.gutter * CGFloat(layout.columns.count - 1)
    HStack(spacing: Self.gutter) {
      ForEach(Array(layout.columns.enumerated()), id: \.offset) { _, column in
        VStack(spacing: Self.gutter) {
          ForEach(column.tiles, id: \.index) { tile in
            self.tile(tile)
          }
        }
        .frame(width: content * column.widthFraction)
      }
    }
    .frame(width: width, height: width / layout.aspectRatio)
    .clipShape(corners.shape)
    .overlay(corners.shape.strokeBorder(theme.edge.opacity(0.5), lineWidth: 1))
  }

  @ViewBuilder
  private func tile(_ tile: MediaAlbumLayout.Tile) -> some View {
    let attachment = media.indices.contains(tile.index) ? media[tile.index] : nil
    MediaTileImage(
      url: attachment?.resolvedFileURL,
      isVideo: attachment?.isVideo == true,
      showsPlayGlyph: tile.hiddenCount == 0,
      placeholder: theme.bubbleIn,
      accentInk: theme.inkTertiary
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .overlay {
      if tile.hiddenCount > 0 {
        // « +3 » : le reste de l'album est derrière, la visionneuse le donnera.
        ZStack {
          Rectangle().fill(.black.opacity(0.45))
          Text("+\(tile.hiddenCount)")
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(.white)
        }
      }
    }
    .contentShape(Rectangle())
    .onTapGesture { onOpen?(tile.index) }
    .accessibilityAddTraits(onOpen == nil ? [] : .isButton)
    .accessibilityLabel(label(attachment, tile: tile))
  }

  private func label(_ attachment: MessageAttachment?, tile: MediaAlbumLayout.Tile) -> String {
    let kind = attachment?.isVideo == true ? "Vidéo" : "Photo"
    let rank = "\(kind) \(tile.index + 1) sur \(media.count)"
    return tile.hiddenCount > 0 ? "\(rank), et \(tile.hiddenCount) de plus" : rank
  }
}

/// UNE TUILE : la vignette cadrée au remplissage, rognée sur ses bords. La
/// même sert à la mosaïque, à la carte de partage et aux médias de la fiche —
/// c'est le seul endroit qui sait tirer une image d'une photo comme d'une vidéo.
public struct MediaTileImage: View {
  public let url: URL?
  public var isVideo: Bool = false
  public var showsPlayGlyph: Bool = true
  /// `.fill` rogne pour remplir — c'est ce que veut une tuile. `.fit` montre
  /// l'image entière : une affiche debout garde alors son texte incrusté.
  public var contentMode: ContentMode = .fill
  public var placeholder: Color
  public var accentInk: Color

  @State private var image: PlatformImage?
  /// Près du visible, dit par `viewportProximity` — cf. `AttachmentImageView`.
  @State private var isNear = false

  private struct LoadKey: Hashable {
    let url: URL?
    let isNear: Bool
  }

  public init(
    url: URL?,
    isVideo: Bool = false,
    showsPlayGlyph: Bool = true,
    contentMode: ContentMode = .fill,
    placeholder: Color,
    accentInk: Color
  ) {
    self.url = url
    self.isVideo = isVideo
    self.showsPlayGlyph = showsPlayGlyph
    self.contentMode = contentMode
    self.placeholder = placeholder
    self.accentInk = accentInk
    // Déjà décodée : la tuile naît avec, sans passer par le rectangle d'attente.
    _image = State(initialValue: url.flatMap { MediaThumbnails.cached(for: $0, isVideo: isVideo) })
  }

  public var body: some View {
    Rectangle()
      .fill(placeholder)
      .overlay {
        if let image {
          Image(platformImage: image)
            .resizable()
            .aspectRatio(contentMode: contentMode)
        } else {
          Image(systemName: isVideo ? "video" : "photo")
            .font(.system(size: 16))
            .foregroundStyle(accentInk)
        }
      }
      .clipped()
      .overlay {
        if isVideo, showsPlayGlyph {
          Image(systemName: "play.fill")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .padding(10)
            .background(.black.opacity(0.45), in: Circle())
        }
      }
      .viewportProximity { near in
        isNear = near
        if !near { image = nil }
      }
      .task(id: LoadKey(url: url, isNear: isNear)) {
        guard isNear, image == nil, let url else { return }
        let loaded = await MediaThumbnails.thumbnail(for: url, isVideo: isVideo)
        guard !Task.isCancelled else { return }
        image = loaded
      }
  }
}

/// Les vignettes des tuiles : les photos passent par le décodeur borné du fil,
/// les vidéos par leur première image, gardée une fois pour toutes.
@MainActor
public enum MediaThumbnails {
  /// Une tuile fait au plus 300 points de côté, sur un écran Retina.
  private static let maxPixel: CGFloat = 600
  private static var posters: [String: PlatformImage] = [:]

  public static func cached(for url: URL, isVideo: Bool) -> PlatformImage? {
    isVideo
      ? posters[url.path]
      : AttachmentThumbnailStore.shared.cached(for: url, maxPixel: maxPixel)
  }

  public static func thumbnail(for url: URL, isVideo: Bool) async -> PlatformImage? {
    guard isVideo else {
      return await AttachmentThumbnailStore.shared.thumbnail(for: url, maxPixel: maxPixel)
    }
    if let hit = posters[url.path] { return hit }
    let side = maxPixel
    let poster = await Task.detached(priority: .utility) { () -> PlatformImage? in
      let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
      generator.appliesPreferredTrackTransform = true
      generator.maximumSize = CGSize(width: side, height: side)
      guard let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
      return PlatformImage.from(cgImage: cgImage)
    }.value
    if let poster { posters[url.path] = poster }
    return poster
  }
}
