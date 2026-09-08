import SwiftUI
import CorrespondanceCore
import CorrespondanceUI

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

  @State private var image: PlatformImage?

  var body: some View {
    ZStack {
      if let image {
        // Bornée ICI, pas seulement par le cadre de la pile : une image
        // `scaledToFill` garde sa taille native comme taille idéale, et un hôte
        // qui la lui accorde — l'étiquette d'un `Menu` sans bordure — la
        // dessinait en grand par-dessus le composer (vu avec la photo de profil
        // Signal d'un fil fusionné).
        Image(platformImage: image)
          .resizable()
          .scaledToFill()
          .frame(width: size, height: size)
          .clipped()
      } else if let glyph = agentGlyph {
        // Un agent ou le bot du pont a sa propre tête : jamais celle de la
        // personne à qui l'on écrit, même en tête-à-tête — vu en vrai, cc et
        // l'avertissement du pont portaient le visage de la correspondante.
        Circle().fill(glyph.color)
        Image(systemName: glyph.symbol)
          .font(.system(size: size * 0.46, weight: .semibold))
          .foregroundStyle(.white.opacity(0.95))
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

  /// Le glyphe d'un expéditeur qui n'est ni moi ni un humain du réseau : un
  /// agent (chacun le sien), ou le bot de gestion d'un pont.
  private var agentGlyph: (symbol: String, color: Color)? {
    guard let sender = message.senderID else { return nil }
    if MatrixIdentity.isAgent(sender) {
      let localpart = sender.dropFirst().prefix { $0 != ":" }
      switch localpart {
      case "cc": return ("sparkles", Color(red: 0.30, green: 0.62, blue: 0.72))
      case "hermes": return ("wind", Color(red: 0.72, green: 0.45, blue: 0.85))
      default: return ("cpu", Color(red: 0.45, green: 0.50, blue: 0.60))
      }
    }
    if MatrixIdentity.isBridgeBot(sender) {
      return ("arrow.left.arrow.right", Color(red: 0.55, green: 0.58, blue: 0.62))
    }
    return nil
  }

  private func load() async {
    image = nil
    // Un agent ou un bot ne porte jamais l'image du fil.
    if agentGlyph != nil { return }
    // En tête-à-tête, l'auteur *est* le fil : on emprunte l'image déjà résolue
    // (carnet d'adresses, portail, mosaïque) plutôt que d'en chercher une autre.
    // Décodé à la taille du disque, pas à celle de la photo : une photo de
    // profil de 1024 px pèse 4 Mo décodée, et le fil en montre des dizaines.
    let maxPixel = size * 3
    if let conversation, !conversation.isGroup {
      if let data = await ConversationAvatarStore.shared.imageData(for: conversation),
         let loaded = await AttachmentThumbnailStore.shared.portrait(
           data: data, key: "portrait|\(conversation.id)|\(data.count)|\(data.hashValue)", maxPixel: maxPixel)
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
    if let data,
       let loaded = await AttachmentThumbnailStore.shared.portrait(
         data: data, key: "portrait|\(taskKey)|\(data.count)|\(data.hashValue)", maxPixel: maxPixel)
    {
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
