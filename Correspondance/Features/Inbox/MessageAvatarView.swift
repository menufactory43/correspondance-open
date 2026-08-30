import AppKit
import SwiftUI
import CorrespondanceCore

/// La photo posée à gauche d'une prise de parole, comme Beeper — et comme tout
/// le monde. Un tête-à-tête emprunte le visage du fil ; un groupe cherche celui
/// de l'auteur, faute de quoi il pose ses initiales sur une couleur stable.
///
/// Pas de pastille réseau ici : le fil sait déjà sur quel réseau il se lit, et
/// une pastille par bulle ferait un chapelet de badges le long de la marge.
struct MessageAvatarView: View {
  let message: ChatMessage
  /// Le fil réel de la bulle — sur une ligne fusionnée, celui du réseau qui parle.
  let conversation: Conversation?
  var size: CGFloat = 26
  let theme: WritingTheme

  @State private var image: NSImage?

  var body: some View {
    ZStack {
      if let image {
        Image(nsImage: image)
          .resizable()
          .scaledToFill()
      } else {
        Circle().fill(fallbackColor)
        Text(initials)
          .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
          .foregroundStyle(.white.opacity(0.95))
      }
    }
    .frame(width: size, height: size)
    .clipShape(Circle())
    .overlay(Circle().strokeBorder(theme.edge.opacity(0.35), lineWidth: 0.5))
    // La photo suit l'auteur, pas la bulle : deux messages du même expéditeur
    // partagent la même tâche et donc la même image, déjà en cache.
    .task(id: taskKey) { await load() }
    .accessibilityHidden(true)
  }

  private var authorKey: String { MessageGrouping.authorKey(message) }

  private var taskKey: String {
    "\(conversation?.id ?? message.conversationID)|\(authorKey)"
  }

  private func load() async {
    image = nil
    // En tête-à-tête, l'auteur *est* le fil : on emprunte l'image déjà résolue
    // (carnet d'adresses, portail, mosaïque) plutôt que d'en chercher une autre.
    if let conversation, !conversation.isGroup {
      if let data = await ConversationAvatarStore.shared.imageData(for: conversation),
         let loaded = NSImage(data: data)
      {
        image = loaded
        return
      }
    }
    let data = await SenderAvatarStore.shared.imageData(
      conversationID: conversation?.id ?? message.conversationID,
      senderID: message.senderID,
      network: message.network
    )
    if let data, let loaded = NSImage(data: data) {
      image = loaded
    }
  }

  /// Le nom de l'auteur si le réseau l'a donné, celui du fil sinon.
  private var displayName: String {
    if let label = MessageGrouping.label(for: message), !label.isEmpty { return label }
    return conversation?.title ?? ""
  }

  private var initials: String {
    let parts = displayName
      .split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "·" })
      .filter { !$0.isEmpty }
    if parts.count >= 2 {
      return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
    }
    let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return "?" }
    return String(trimmed.prefix(2)).uppercased()
  }

  /// La même palette que la sidebar, tirée de l'auteur : un correspondant garde
  /// sa couleur d'une bulle à l'autre, et d'un lancement au suivant.
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
    let seed = authorKey.isEmpty ? (conversation?.id ?? message.conversationID) : authorKey
    var hash = 0
    for scalar in seed.unicodeScalars {
      hash = (hash &* 31) &+ Int(scalar.value)
    }
    return palette[abs(hash) % palette.count]
  }
}
