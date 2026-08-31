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
      image = nil
      image = await resolve()
    }
  }

  private var avatarKey: String {
    "\(conversation.id)|\(conversation.remoteAvatarID ?? "")|\(conversation.memberAvatarIDs.joined(separator: ","))"
  }

  private func resolve() async -> PlatformImage? {
    if let mxc = conversation.remoteAvatarID, !mxc.isEmpty,
       let data = await store.matrix.avatarData(mxcURI: mxc),
       let loaded = PlatformImage(data: data)
    {
      return loaded
    }
    // Un groupe sans photo à lui : la mosaïque de ses membres, comme Messages.
    let ids = Array(conversation.memberAvatarIDs.prefix(4))
    guard conversation.isGroup, ids.count >= 2 else { return nil }
    var faces: [PlatformImage] = []
    for mxc in ids {
      guard let data = await store.matrix.avatarData(mxcURI: mxc),
            let face = PlatformImage(data: data)
      else { continue }
      faces.append(face)
    }
    guard faces.count >= 2 else { return nil }
    guard let composed = AvatarMosaic.compose(
      faces,
      size: size * 3,
      separator: .platformWindowBackground
    ) else { return nil }
    return PlatformImage(data: composed)
  }

  private var badgeTint: Color {
    switch conversation.network {
    case .iMessage: Color(red: 0.25, green: 0.75, blue: 0.45)
    case .signal: theme.accent
    case .whatsapp: Color(red: 0.15, green: 0.72, blue: 0.42)
    case .instagram: Color(red: 0.78, green: 0.23, blue: 0.55)
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
