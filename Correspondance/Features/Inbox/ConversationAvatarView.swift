import AppKit
import SwiftUI
import CorrespondanceCore

struct ConversationAvatarView: View {
  let conversation: Conversation
  var size: CGFloat = 34
  var theme: WritingTheme
  /// Dans une liste de personnes d'un même fil, la pastille réseau ne dit plus rien.
  var showsNetworkBadge = true

  @State private var image: NSImage?

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
        Image(nsImage: image)
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
        Text(initials)
          .font(.system(size: size * 0.34, weight: .semibold, design: .rounded))
          .foregroundStyle(.white.opacity(0.95))
      }
    }
    .frame(width: size, height: size)
    .clipShape(Circle())
    .overlay(
      Circle()
        .strokeBorder(theme.edge.opacity(0.35), lineWidth: 0.5)
    )
    .overlay(alignment: .bottomTrailing) {
      if showsNetworkBadge {
        networkBadge
          .offset(x: 1, y: 1)
      }
    }
    // Une nouvelle photo côté réseau change le `mxc` : la tâche doit repartir,
    // sinon l'ancienne image resterait affichée jusqu'au prochain lancement.
    // Les photos des membres comptent autant : sans elles, une mosaïque figerait
    // le jour où quelqu'un rejoint le groupe ou change de portrait.
    .task(
      id: "\(conversation.id)|\(conversation.remoteAvatarID ?? "")|\(conversation.memberAvatarIDs.joined(separator: ","))"
    ) {
      image = nil
      if let data = await ConversationAvatarStore.shared.imageData(for: conversation),
         let loaded = NSImage(data: data)
      {
        image = loaded
      }
    }
  }

  /// Pastille réseau — la même partout (inbox, fil, Focus).
  private var badgeTint: Color {
    switch conversation.network {
    case .iMessage: Color(red: 0.25, green: 0.75, blue: 0.45)
    case .signal: theme.accent
    case .whatsapp: Color(red: 0.15, green: 0.72, blue: 0.42)
    // Le magenta d'Instagram, sans dégradé : une pastille de 8 points n'a pas la place.
    case .instagram: Color(red: 0.78, green: 0.23, blue: 0.55)
    }
  }

  private var networkBadge: some View {
    Image(systemName: conversation.network.systemImage)
      .font(.system(size: max(7, size * 0.22), weight: .bold))
      .foregroundStyle(theme.paper)
      .padding(2)
      .background(Circle().fill(badgeTint))
      .overlay(Circle().strokeBorder(theme.sidebar, lineWidth: 1))
      .accessibilityLabel(conversation.network.labelFR)
  }
}
