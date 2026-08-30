import SwiftUI
import CorrespondanceCore

/// L'APERÇU D'UN LIEN, sous la bulle : une vignette, un titre, un domaine.
///
/// Carte maison, jamais `LPLinkView` : celui d'Apple impose ses couleurs, ses
/// coins et sa typo système, et jurerait sur les six papiers. Ici tout vient
/// des jetons du thème — papier, liseré, encres — et rien n'est posé en dur.
///
/// La carte n'existe que lorsque les métadonnées sont arrivées : tant qu'on
/// cherche, la bulle garde son lien nu et souligné, et le fil ne bouge pas.
struct LinkPreviewCard: View {
  let url: URL
  let theme: WritingTheme
  var typeface: WritingTypeface = .quattro

  @Environment(\.openURL) private var openURL
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var preview: LinkPreview?

  /// Assez large pour qu'un titre tienne sur deux lignes, assez étroite pour
  /// rester une note en marge de la bulle plutôt qu'une seconde bulle.
  static let maxWidth: CGFloat = 320
  private static let corner: CGFloat = 12
  private static let thumbnailHeight: CGFloat = 132

  var body: some View {
    Group {
      if let preview {
        card(preview)
          .transition(.opacity)
      }
    }
    .task(id: url) {
      let found = await LinkPreviewStore.shared.metadata(for: url)
      guard !Task.isCancelled else { return }
      // Le fil est ancré en bas : la carte pousse le contenu sans arracher la
      // lecture. Un fondu suffit à dire qu'elle vient d'arriver.
      withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
        preview = found
      }
    }
  }

  private func card(_ preview: LinkPreview) -> some View {
    Button {
      openURL(url)
    } label: {
      VStack(alignment: .leading, spacing: 0) {
        if let path = preview.imagePath,
           let image = LinkPreviewStore.shared.thumbnail(atPath: path)
        {
          Image(platformImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(height: Self.thumbnailHeight)
            .frame(maxWidth: .infinity)
            .clipped()
            .overlay(alignment: .bottom) {
              Rectangle().fill(theme.edge).frame(height: 1)
            }
        }

        VStack(alignment: .leading, spacing: 2) {
          if let title = preview.title, !title.isEmpty {
            Text(title)
              .font(Typography.meta(typeface))
              .foregroundStyle(theme.ink)
              .lineLimit(2)
              .multilineTextAlignment(.leading)
          }
          Text(preview.domain)
            .font(Typography.meta(typeface))
            .foregroundStyle(theme.inkTertiary)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, 7)
      }
      .frame(maxWidth: Self.maxWidth, alignment: .leading)
      .background(theme.paper)
      .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
          .strokeBorder(theme.edge, lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
    .help(url.absoluteString)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel(preview))
    .accessibilityHint("Ouvre le lien dans le navigateur")
  }

  private func accessibilityLabel(_ preview: LinkPreview) -> String {
    guard let title = preview.title, !title.isEmpty else {
      return "Aperçu du lien sur \(preview.domain)"
    }
    return "Aperçu du lien : \(title), sur \(preview.domain)"
  }
}
