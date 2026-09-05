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
///
/// Piège rencontré : un `.task` posé sur cette carte tant qu'elle est vide
/// (`Group { if let … }` sans rien dedans) ne se déclenche JAMAIS — la vue
/// n'existe pas, le modificateur non plus — et les aperçus n'arrivaient
/// jamais. La recherche part donc à la naissance de la carte (`warm`), et le
/// corps lit le magasin, observé : la carte paraît quand l'aperçu est là.
public struct LinkPreviewCard: View {
  public let url: URL
  public let theme: WritingTheme
  public var typeface: WritingTypeface = .quattro
  /// L'aperçu que le réseau a livré avec le message, quand il y en a un : on
  /// l'affiche tel quel, sans interroger la page — c'est celui que voient les
  /// autres membres, et bien des sites ne répondent pas à un robot.
  public var bridged: LinkPreview?

  @Environment(\.openURL) private var openURL

  /// Assez large pour qu'un titre tienne sur deux lignes, assez étroite pour
  /// rester une note en marge de la bulle plutôt qu'une seconde bulle.
  public static let maxWidth: CGFloat = 320
  private static let corner: CGFloat = 12
  private static let thumbnailHeight: CGFloat = 132

  public var body: some View {
    if let preview = bridged ?? LinkPreviewStore.shared.cached(for: url) {
      card(preview)
        .transition(.opacity)
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

  /// Sur le fil principal : c'est ici que la recherche part, et le magasin y
  /// vit. Idempotent — une bulle se reconstruit souvent, l'adresse ne se
  /// cherche qu'une fois.
  @MainActor
  public init(
    url: URL,
    theme: WritingTheme,
    typeface: WritingTypeface = .quattro,
    bridged: LinkPreview? = nil
  ) {
    self.url = url
    self.theme = theme
    self.typeface = typeface
    self.bridged = bridged
    if bridged == nil {
      LinkPreviewStore.shared.warm(url)
    }
  }
}
