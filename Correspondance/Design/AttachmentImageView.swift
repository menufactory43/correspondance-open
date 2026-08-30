import AppKit
import SwiftUI

/// Une photo dans un fil. Le fichier n'est jamais lu depuis le corps de la vue :
/// la vignette arrive de `AttachmentThumbnailStore`, décodée hors du fil
/// principal et à la taille d'affichage. Le temps qu'elle arrive, la place est
/// tenue par un rectangle de la couleur du papier — le fil ne saute pas.
struct AttachmentImageView<Unavailable: View>: View {
  let url: URL
  var maxWidth: CGFloat
  var maxHeight: CGFloat
  var cornerRadius: CGFloat = 12
  var placeholder: Color
  var border: Color?
  var label: String
  @ViewBuilder var unavailable: () -> Unavailable

  @Environment(\.displayScale) private var displayScale

  private enum Load: Equatable {
    case loading
    case ready(NSImage)
    case failed
  }

  @State private var load: Load = .loading

  var body: some View {
    Group {
      switch load {
      case .ready(let image):
        Image(nsImage: image)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(maxWidth: maxWidth, maxHeight: maxHeight)
          .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
          .overlay {
            if let border {
              RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(border, lineWidth: 1)
            }
          }
          .accessibilityLabel(label)
      case .loading:
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .fill(placeholder)
          // Proportion d'attente : celle d'une photo de téléphone tenue à
          // l'horizontale. La vignette reprend sa vraie forme en arrivant.
          .frame(width: maxWidth, height: min(maxWidth * 0.75, maxHeight))
          .accessibilityLabel("Photo en cours de chargement")
      case .failed:
        unavailable()
      }
    }
    .task(id: url) {
      let maxPixel = max(maxWidth, maxHeight) * max(displayScale, 1)
      let image = await AttachmentThumbnailStore.shared.thumbnail(for: url, maxPixel: maxPixel)
      guard !Task.isCancelled else { return }
      load = image.map(Load.ready) ?? .failed
    }
  }
}
