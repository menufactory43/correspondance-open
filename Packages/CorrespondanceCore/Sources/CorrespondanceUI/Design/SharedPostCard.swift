import CorrespondanceCore
import SwiftUI

/// LA CARTE D'UN POST PARTAGÉ. Ce que le pont livre en Markdown — l'auteur, la
/// légende, l'adresse écrite deux fois, le reel en pièce jointe — tient ici en
/// une seule chose cliquable : la vignette, le compte, ce qu'il a écrit.
///
/// Deux gestes, pas un. Le pont livre la vidéo du reel avec le message : la
/// toucher la JOUE ici, dans la visionneuse du fil, sans passer par Instagram
/// — c'est `onPlayMedia`, que la bulle branche sur son lecteur. Le pied de la
/// carte (le compte, la légende, « Ouvrir dans Instagram ») mène au post là
/// où il vit, avec son son, ses commentaires et sa suite. Sans vidéo locale
/// ni lecteur branché, toute la carte ouvre Instagram, comme avant.
/// Mêmes jetons que `LinkPreviewCard` — papier, liseré, encres du thème.
public struct SharedPostCard: View {
  public let post: SharedPost
  public let theme: WritingTheme
  public var typeface: WritingTypeface = .quattro
  public var width: CGFloat = 300
  public var cornerRadius: CGFloat = 12
  /// Lire la vidéo du post en place. `nil` = pas de lecteur, la carte ouvre Instagram.
  public var onPlayMedia: (() -> Void)?

  @Environment(\.openURL) private var openURL
  /// La proportion réelle de l'affiche, apprise de la vignette. Le 4/5 n'est
  /// qu'une attente : un reel est debout en 9/16, et le cadrer carré coupait
  /// la moitié de ce qui y est écrit.
  @State private var aspect: CGFloat = 4 / 5

  public init(
    post: SharedPost,
    theme: WritingTheme,
    typeface: WritingTypeface = .quattro,
    width: CGFloat = 300,
    cornerRadius: CGFloat = 12,
    onPlayMedia: (() -> Void)? = nil
  ) {
    self.post = post
    self.theme = theme
    self.typeface = typeface
    self.width = width
    self.cornerRadius = cornerRadius
    self.onPlayMedia = onPlayMedia
  }

  /// La vidéo est là, sur le disque, et quelqu'un sait la jouer.
  private var playsInPlace: Bool {
    guard let media = post.media, media.isVideo, media.resolvedFileURL != nil else { return false }
    return onPlayMedia != nil
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let media = post.media {
        Button {
          if playsInPlace { onPlayMedia?() } else { openURL(post.url) }
        } label: {
          MediaTileImage(
            url: media.resolvedFileURL,
            isVideo: media.isVideo,
            // Trop haute pour la carte : on la montre entière plutôt que d'en
            // rogner le texte incrusté, qui EST souvent le propos du post.
            contentMode: width / aspect > Self.maxMediaHeight ? .fit : .fill,
            placeholder: theme.bubbleIn,
            accentInk: theme.inkTertiary
          )
          // Le format d'un reel, pas celui d'une vignette de lien : c'est
          // debout que se regarde ce qui a été filmé debout.
          .frame(width: width, height: min(width / aspect, Self.maxMediaHeight))
          .task(id: media.resolvedFileURL) {
            guard let url = media.resolvedFileURL,
                  let poster = await MediaThumbnails.thumbnail(for: url, isVideo: media.isVideo),
                  poster.size.height > 0
            else { return }
            aspect = poster.size.width / poster.size.height
          }
          .overlay(alignment: .bottom) {
            Rectangle().fill(theme.edge).frame(height: 1)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(playsInPlace ? "Vidéo du post" : accessibilityLabel)
        .accessibilityHint(playsInPlace ? "Lit la vidéo ici" : "Ouvre la publication dans Instagram")
      }

      Button {
        openURL(post.url)
      } label: {
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
          // Quand la vidéo se joue ici, le pied dit clairement ce qu'il
          // fait, lui : c'est le seul chemin vers Instagram qui reste.
          Text(playsInPlace ? "Ouvrir dans Instagram" : "instagram.com")
            .font(Typography.meta(typeface))
            .foregroundStyle(playsInPlace ? theme.accent : theme.inkTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(accessibilityLabel)
      .accessibilityHint("Ouvre la publication dans Instagram")
    }
    .frame(width: width, alignment: .leading)
    .background(theme.paper)
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .strokeBorder(theme.edge, lineWidth: 1)
    )
  }

  /// Une affiche ne mange pas tout le fil : au-delà, on la borne.
  private static let maxMediaHeight: CGFloat = 360

  private var accessibilityLabel: String {
    [post.previewText, post.caption].compactMap { $0 }.joined(separator: " : ")
  }
}
