import AppKit
import SwiftUI

/// Une photo dans un fil. Le fichier n'est jamais décodé depuis le corps de la
/// vue : la vignette vient de `AttachmentThumbnailStore`, préparée hors du fil
/// principal et à la taille d'affichage.
///
/// Deux précautions, et ce sont elles qui font tenir le fil :
///
/// - la bulle prend sa **taille définitive dès sa construction**, lue dans
///   l'en-tête du fichier sans rien décoder. Le fil est ancré en bas : une
///   hauteur qui change en cours de route relance le placement de tout le
///   monde, ce qui découvre d'autres photos, sans fin ;
/// - si la vignette est déjà en mémoire, la vue naît avec. Le `LazyVStack`
///   détruit et reconstruit les bulles qui sortent de l'écran ; sans ça,
///   chacune repasserait par le rectangle d'attente à chaque recyclage.
struct AttachmentImageView<Unavailable: View>: View {
  let url: URL
  var maxWidth: CGFloat
  var maxHeight: CGFloat
  var cornerRadius: CGFloat = 12
  var placeholder: Color
  var border: Color?
  var label: String
  @ViewBuilder var unavailable: () -> Unavailable

  private enum Load {
    case loading
    case ready(NSImage)
    case failed
  }

  @State private var load: Load
  /// Taille d'affichage, connue avant la photo elle-même.
  private let fitted: CGSize

  init(
    url: URL,
    maxWidth: CGFloat,
    maxHeight: CGFloat,
    cornerRadius: CGFloat = 12,
    placeholder: Color,
    border: Color? = nil,
    label: String,
    @ViewBuilder unavailable: @escaping () -> Unavailable
  ) {
    self.url = url
    self.maxWidth = maxWidth
    self.maxHeight = maxHeight
    self.cornerRadius = cornerRadius
    self.placeholder = placeholder
    self.border = border
    self.label = label
    self.unavailable = unavailable
    let store = AttachmentThumbnailStore.shared
    let cached = store.cached(
      for: url,
      maxPixel: Self.maxPixel(maxWidth: maxWidth, maxHeight: maxHeight)
    )
    _load = State(initialValue: cached.map(Load.ready) ?? .loading)
    fitted = Self.fit(
      // Fichier illisible : la proportion d'attente est celle d'une photo de
      // téléphone tenue à l'horizontale.
      store.pixelSize(for: url) ?? CGSize(width: 4, height: 3),
      maxWidth: maxWidth,
      maxHeight: maxHeight
    )
  }

  /// La photo tient dans la boîte sans se déformer ni se rogner.
  private static func fit(_ size: CGSize, maxWidth: CGFloat, maxHeight: CGFloat) -> CGSize {
    let scale = min(maxWidth / size.width, maxHeight / size.height, 1000)
    return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
  }

  /// L'écran est en Retina : une bulle de 280 points demande 560 pixels. La
  /// valeur est figée plutôt que lue dans l'environnement, pour que la clé du
  /// cache soit la même à la construction de la vue et dans sa tâche.
  private static func maxPixel(maxWidth: CGFloat, maxHeight: CGFloat) -> CGFloat {
    max(maxWidth, maxHeight) * 2
  }

  var body: some View {
    content
      .task(id: url) {
        guard case .loading = load else { return }
        let image = await AttachmentThumbnailStore.shared.thumbnail(
          for: url,
          maxPixel: Self.maxPixel(maxWidth: maxWidth, maxHeight: maxHeight)
        )
        load = image.map(Load.ready) ?? .failed
      }
  }

  @ViewBuilder
  private var content: some View {
    switch load {
    case .ready(let image):
      Image(nsImage: image)
        .resizable()
        .frame(width: fitted.width, height: fitted.height)
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
        .frame(width: fitted.width, height: fitted.height)
        .accessibilityLabel("Photo en cours de chargement")
    case .failed:
      unavailable()
    }
  }
}
