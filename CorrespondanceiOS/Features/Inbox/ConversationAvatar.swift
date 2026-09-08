import CorrespondanceCore
import CorrespondanceUI
import SwiftUI

/// La photo d'un fil, avec sa pastille de réseau.
///
/// Reprise du rendu Mac (`ConversationAvatarView`) : mêmes initiales, même
/// palette de repli, même pastille. Ce qui change, c'est la source — le Mac
/// interroge son carnet d'adresses via `ConversationAvatarStore`, qui dépend de
/// Contacts et d'`InboxStore`. L'iPhone, lui, n'a que le Relais : la photo du
/// portail (`remoteAvatarID`), et à défaut la mosaïque des membres d'un groupe,
/// composée par `AvatarMosaic` (Core, CoreGraphics pur).
struct ConversationAvatar: View {
  let conversation: Conversation
  var size: CGFloat = 46
  var theme: WritingTheme
  var showsNetworkBadge = true

  @Environment(RelayStore.self) private var store
  @State private var image: PlatformImage?

  init(conversation: Conversation, size: CGFloat = 46, theme: WritingTheme, showsNetworkBadge: Bool = true) {
    self.conversation = conversation
    self.size = size
    self.theme = theme
    self.showsNetworkBadge = showsNetworkBadge
    // La liste recrée ses rangées à chaque défilement et à chaque `/sync` :
    // une photo déjà décodée se retrouve ici sans tâche, sans décodage, et
    // sans recomposer une mosaïque (mesuré sur l'iPhone : PNG réencodé à
    // chaque passage, un quart de cœur au repos).
    _image = State(initialValue: Self.cachedImage(for: conversation, size: size))
  }

  private static func cachedImage(for conversation: Conversation, size: CGFloat) -> PlatformImage? {
    let store = AttachmentThumbnailStore.shared
    if let mxc = conversation.remoteAvatarID, !mxc.isEmpty {
      return store.cachedPortrait(key: "portrait|\(mxc)", maxPixel: size * 3)
    }
    return store.cachedPortrait(key: "mosaic|\(Self.avatarKey(of: conversation))", maxPixel: size * 3)
  }

  private static func avatarKey(of conversation: Conversation) -> String {
    "\(conversation.id)|\(conversation.remoteAvatarID ?? "")|\(conversation.memberAvatarIDs.joined(separator: ","))"
  }

  private var initials: String {
    let parts = conversation.title
      .split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "·" })
      .filter { !$0.isEmpty }
    if parts.count >= 2 {
      return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
    }
    let trimmed = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return "?" }
    return String(trimmed.prefix(2)).uppercased()
  }

  /// La même palette que sur le Mac : deux appareils qui montrent la même
  /// personne doivent lui donner la même couleur.
  private var fallbackColor: Color {
    let palette: [Color] = [
      Color(red: 0.35, green: 0.55, blue: 0.95),
      Color(red: 0.45, green: 0.72, blue: 0.55),
      Color(red: 0.92, green: 0.55, blue: 0.35),
      Color(red: 0.72, green: 0.45, blue: 0.85),
      Color(red: 0.95, green: 0.45, blue: 0.55),
      Color(red: 0.30, green: 0.70, blue: 0.80),
      Color(red: 0.85, green: 0.65, blue: 0.25),
    ]
    var hash = 0
    for scalar in conversation.id.unicodeScalars {
      hash = (hash &* 31) &+ Int(scalar.value)
    }
    return palette[abs(hash) % palette.count]
  }

  var body: some View {
    ZStack {
      if let image {
        Image(platformImage: image)
          .resizable()
          .scaledToFill()
      } else {
        Circle()
          .fill(
            LinearGradient(
              colors: [fallbackColor, fallbackColor.opacity(0.78)],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
          )
        if conversation.isGroup {
          Image(systemName: "person.2.fill")
            .font(.system(size: size * 0.36, weight: .semibold))
            .foregroundStyle(.white.opacity(0.92))
        } else {
          Text(initials)
            .font(.system(size: size * 0.34, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.95))
        }
      }
    }
    .frame(width: size, height: size)
    .clipShape(Circle())
    .overlay(Circle().strokeBorder(theme.edge.opacity(0.35), lineWidth: 0.5))
    .overlay(alignment: .bottomTrailing) {
      if showsNetworkBadge { networkBadge.offset(x: 1, y: 1) }
    }
    // Une nouvelle photo côté réseau change le `mxc` : la tâche doit repartir.
    .task(id: avatarKey) {
      if let cached = Self.cachedImage(for: conversation, size: size) {
        image = cached
        return
      }
      image = nil
      image = await resolve()
    }
  }

  private var avatarKey: String { Self.avatarKey(of: conversation) }

  private func resolve() async -> PlatformImage? {
    // Décodée à la taille du disque, pas à celle de la photo (cf. le Mac) :
    // une photo de profil de 1024 px pèse 4 Mo décodée, la liste en montre
    // des dizaines, et chaque décodage complet chauffe l'appareil pour rien.
    let maxPixel = size * 3
    if let mxc = conversation.remoteAvatarID, !mxc.isEmpty,
       let data = await store.matrix.avatarData(mxcURI: mxc),
       let loaded = await AttachmentThumbnailStore.shared.portrait(
         data: data, key: "portrait|\(mxc)", maxPixel: maxPixel)
    {
      return loaded
    }
    // Un groupe sans photo à lui : la mosaïque de ses membres, comme Messages.
    let ids = Array(conversation.memberAvatarIDs.prefix(4))
    guard conversation.isGroup, ids.count >= 2 else { return nil }
    var faces: [PlatformImage] = []
    for mxc in ids {
      guard let data = await store.matrix.avatarData(mxcURI: mxc),
            let face = AttachmentThumbnailStore.downsample(data: data, maxPixel: 128)
      else { continue }
      faces.append(face)
    }
    guard faces.count >= 2 else { return nil }
    // Composée en image, pas en PNG réencodé puis redécodé ; gardée sous la
    // clé de la mosaïque pour que les rangées suivantes la trouvent prête.
    guard let composed = AvatarMosaic.composeImage(
      faces,
      size: size * 1.5,
      separator: .platformWindowBackground
    ) else { return nil }
    let image = PlatformImage.from(cgImage: composed)
    AttachmentThumbnailStore.shared.remember(image, key: "mosaic|\(avatarKey)", maxPixel: maxPixel)
    return image
  }

  private var badgeTint: Color {
    switch conversation.network {
    case .selfNote: Color(red: 0.55, green: 0.52, blue: 0.48)
    case .agent: Color(red: 0.95, green: 0.60, blue: 0.15)
    case .iMessage: Color(red: 0.25, green: 0.75, blue: 0.45)
    case .signal: theme.accent
    case .whatsapp: Color(red: 0.15, green: 0.72, blue: 0.42)
    case .instagram: Color(red: 0.78, green: 0.23, blue: 0.55)
    // Mêmes teintes que sur le Mac : la pastille d'un réseau ne change pas d'appareil.
    case .messenger: Color(red: 0.35, green: 0.40, blue: 0.95)
    // X est noir : l'encre du thème, noire sur papier, claire sur fond sombre.
    case .twitter: theme.ink
    // L'aubergine de Slack.
    case .slack: Color(red: 0.29, green: 0.12, blue: 0.35)
    }
  }

  private var networkBadge: some View {
    Image(systemName: conversation.network.systemImage)
      .font(.system(size: max(7, size * 0.22), weight: .bold))
      .foregroundStyle(theme.paper)
      .padding(2.5)
      .background(Circle().fill(badgeTint))
      .overlay(Circle().strokeBorder(theme.paper, lineWidth: 1.5))
      .accessibilityLabel(conversation.network.labelFR)
  }
}
