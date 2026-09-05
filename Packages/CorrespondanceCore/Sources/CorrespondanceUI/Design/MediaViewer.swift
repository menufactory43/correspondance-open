#if os(iOS)
import AVKit
import CorrespondanceCore
import QuickLook
import SwiftUI

/// Le rang du média sur lequel la visionneuse s'ouvre — de quoi la présenter
/// par `fullScreenCover(item:)`.
public struct OpenedMedia: Identifiable {
  public let id: Int

  public init(_ id: Int) { self.id = id }
}

/// LA VISIONNEUSE : un média plein écran sur fond noir, et tous ses voisins au
/// bout d'un balayage. Pincer agrandit, taper deux fois aussi, tirer vers le bas
/// referme — et le fond s'efface à mesure qu'on tire, pour que le geste se voie
/// avant d'aboutir.
public struct MediaViewer: View {
  public let media: [MessageAttachment]

  @State private var index: Int
  @State private var scale: CGFloat = 1
  @State private var drop: CGFloat = 0
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  public init(media: [MessageAttachment], startAt: Int = 0) {
    self.media = media
    _index = State(initialValue: max(0, min(startAt, media.count - 1)))
  }

  /// Le fond s'éclaircit avec la chute : à deux cents points, la visionneuse est
  /// déjà presque partie.
  private var backdrop: Double { max(0, 1 - Double(abs(drop)) / 260) }

  public var body: some View {
    ZStack(alignment: .topTrailing) {
      Color.black.opacity(backdrop).ignoresSafeArea()

      TabView(selection: $index) {
        ForEach(Array(media.enumerated()), id: \.offset) { rank, attachment in
          page(attachment).tag(rank)
        }
      }
      .tabViewStyle(.page(indexDisplayMode: media.count > 1 ? .automatic : .never))
      .offset(y: drop)
      // Le geste vit sur les PAGES, pas sur la pile : posé plus haut, il
      // passait devant les deux boutons de la barre, qui ne répondaient plus.
      .gesture(dismissDrag)

      bar
    }
    .statusBarHidden()
    .onChange(of: index) { _, _ in scale = 1 }
  }

  @ViewBuilder
  private func page(_ attachment: MessageAttachment) -> some View {
    if let url = attachment.resolvedFileURL, attachment.isVideo {
      // On a tapé pour la voir : elle part sans qu'on ait à retaper.
      StableVideoPlayer(url: url, autoplays: true)
    } else if let url = attachment.resolvedFileURL {
      ZoomableImage(url: url, scale: $scale)
        .accessibilityLabel(attachment.filename ?? "Photo")
    } else {
      Label("Média indisponible", systemImage: "photo")
        .foregroundStyle(.white)
    }
  }

  private var bar: some View {
    HStack(spacing: Spacing.md) {
      if let url = media.indices.contains(index) ? media[index].resolvedFileURL : nil {
        ShareLink(item: url) {
          glyph("square.and.arrow.up")
        }
        .accessibilityLabel("Partager")
      }
      Button {
        dismiss()
      } label: {
        glyph("xmark")
      }
      .accessibilityLabel("Fermer")
    }
    .buttonStyle(.plain)
    .padding(.horizontal, Spacing.xs)
    .padding(.top, Spacing.xs)
    .opacity(backdrop)
  }

  /// Une croix fait dix-huit points de côté ; la cible d'un pouce en fait
  /// quarante-quatre.
  private func glyph(_ name: String) -> some View {
    Image(systemName: name)
      .font(.system(size: 17, weight: .semibold))
      .foregroundStyle(.white)
      .frame(width: 44, height: 44)
      .contentShape(Rectangle())
  }

  /// Tirer vers le bas referme. Le geste ne prend la main qu'à taille normale :
  /// une fois la photo agrandie, c'est elle qu'on déplace.
  private var dismissDrag: some Gesture {
    DragGesture(minimumDistance: 12)
      .onChanged { value in
        guard scale <= 1.01, abs(value.translation.height) > abs(value.translation.width) else { return }
        drop = value.translation.height
      }
      .onEnded { _ in
        if drop > 120 {
          dismiss()
        } else if reduceMotion {
          drop = 0
        } else {
          withAnimation(.spring(duration: 0.25)) { drop = 0 }
        }
      }
  }
}

/// Une photo qu'on peut agrandir : au pincement, ou d'une double tape.
private struct ZoomableImage: View {
  let url: URL
  @Binding var scale: CGFloat

  @State private var image: PlatformImage?
  @State private var pinch: CGFloat = 1
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Group {
      if let image {
        Image(platformImage: image)
          .resizable()
          .aspectRatio(contentMode: .fit)
      } else {
        ProgressView().tint(.white)
      }
    }
    .scaleEffect(scale * pinch)
    .gesture(
      MagnifyGesture()
        .onChanged { pinch = $0.magnification }
        .onEnded { _ in
          scale = min(max(scale * pinch, 1), 6)
          pinch = 1
        }
    )
    .onTapGesture(count: 2) {
      let target: CGFloat = scale > 1.01 ? 1 : 2.5
      if reduceMotion { scale = target }
      else { withAnimation(.easeOut(duration: 0.2)) { scale = target } }
    }
    .task(id: url) {
      // Plein écran : la vignette du fil serait floue, on redécode plus large.
      image = await AttachmentThumbnailStore.shared.thumbnail(for: url, maxPixel: 2_400)
    }
  }
}

/// Un lecteur dont le `AVPlayer` ne renaît pas à chaque recomposition. Construit
/// dans le corps de la vue, il en créait un par passage — chacun ouvrant le
/// fichier et son décodeur.
public struct StableVideoPlayer: View {
  public let url: URL
  /// Démarre seul en paraissant — pour la visionneuse, où l'on vient de taper.
  public var autoplays: Bool = false
  @State private var player: AVPlayer?

  public init(url: URL, autoplays: Bool = false) {
    self.url = url
    self.autoplays = autoplays
  }

  public var body: some View {
    VideoPlayer(player: player)
      .task(id: url) {
        if player == nil {
          player = AVPlayer(url: url)
          if autoplays { player?.play() }
        }
      }
  }
}

/// Quick Look pour un fichier qui n'est ni photo ni vidéo : un PDF, une archive,
/// un document. Le système sait tous les montrer, nous non.
public struct FilePreview: UIViewControllerRepresentable {
  public let url: URL

  public init(url: URL) { self.url = url }

  public func makeUIViewController(context: Context) -> QLPreviewController {
    let controller = QLPreviewController()
    controller.dataSource = context.coordinator
    return controller
  }

  public func updateUIViewController(_ controller: QLPreviewController, context: Context) {
    context.coordinator.url = url as NSURL
    controller.reloadData()
  }

  public func makeCoordinator() -> Coordinator { Coordinator(url: url as NSURL) }

  public final class Coordinator: NSObject, QLPreviewControllerDataSource {
    var url: NSURL

    init(url: NSURL) { self.url = url }

    public func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

    public func previewController(
      _ controller: QLPreviewController,
      previewItemAt index: Int
    ) -> QLPreviewItem { url }
  }
}
#endif
