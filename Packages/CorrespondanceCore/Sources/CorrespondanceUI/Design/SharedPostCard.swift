import CorrespondanceCore
import SwiftUI

/// LA CARTE D'UN POST PARTAGÉ. Ce que le pont livre en Markdown — l'auteur, la
/// légende, l'adresse écrite deux fois, le reel en pièce jointe — tient ici en
/// une seule chose cliquable : la vignette, le compte, ce qu'il a écrit.
///
/// Le reel ne se joue PAS ici : un reel vit sur Instagram, avec son son, ses
/// commentaires et sa suite. La carte y mène, elle ne le remplace pas.
/// Mêmes jetons que `LinkPreviewCard` — papier, liseré, encres du thème.
public struct SharedPostCard: View {
  public let post: SharedPost
  public let theme: WritingTheme
  public var typeface: WritingTypeface = .quattro
  public var width: CGFloat = 300
  public var cornerRadius: CGFloat = 12

  @Environment(\.openURL) private var openURL

  public init(
    post: SharedPost,
    theme: WritingTheme,
    typeface: WritingTypeface = .quattro,
    width: CGFloat = 300,
    cornerRadius: CGFloat = 12
  ) {
    self.post = post
    self.theme = theme
    self.typeface = typeface
    self.width = width
    self.cornerRadius = cornerRadius
  }

  public var body: some View {
    Button {
      openURL(post.url)
    } label: {
      VStack(alignment: .leading, spacing: 0) {
        if let media = post.media {
          MediaTileImage(
            url: media.resolvedFileURL,
            isVideo: media.isVideo,
            placeholder: theme.bubbleIn,
            accentInk: theme.inkTertiary
          )
          // Le format d'un reel, pas celui d'une vignette de lien : c'est
          // debout que se regarde ce qui a été filmé debout.
          .frame(width: width, height: width * 4 / 5)
          .overlay(alignment: .bottom) {
            Rectangle().fill(theme.edge).frame(height: 1)
          }
        }

        VStack(alignment: .leading, spacing: 2) {
          if let author = post.author {
            Text(author)
              .font(Typography.meta(typeface))
              .fontWeight(.semibold)
              .foregroundStyle(theme.ink)
              .lineLimit(1)
          }
          if let caption = post.caption {
            Text(caption)
              .font(Typography.meta(typeface))
              .foregroundStyle(theme.ink)
              .lineLimit(3)
              .multilineTextAlignment(.leading)
          }
          Text("instagram.com")
            .font(Typography.meta(typeface))
            .foregroundStyle(theme.inkTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, 7)
      }
      .frame(width: width, alignment: .leading)
      .background(theme.paper)
      .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .strokeBorder(theme.edge, lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityHint("Ouvre la publication dans Instagram")
  }

  private var accessibilityLabel: String {
    [post.previewText, post.caption].compactMap { $0 }.joined(separator: " : ")
  }
}
