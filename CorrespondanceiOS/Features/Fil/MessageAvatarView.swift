import CorrespondanceCore
import CorrespondanceUI
import SwiftUI

/// La photo posée à gauche d'une prise de parole, comme sur le Mac — et comme
/// Beeper. Un tête-à-tête emprunte le visage du fil ; un groupe cherche celui
/// de l'auteur (`m.room.member`), faute de quoi il pose ses initiales sur une
/// couleur stable.
///
/// Ce qui change du Mac, c'est la source : pas de carnet d'adresses ici, tout
/// vient du Relais — la photo du portail pour le fil, celle du membre pour
/// l'auteur d'un groupe. Pas de pastille réseau non plus : le fil sait déjà
/// sur quel réseau il se lit.
struct MessageAvatarView: View {
  let message: ChatMessage
  let conversation: Conversation?
  var size: CGFloat = 26
  let theme: WritingTheme

  @Environment(RelayStore.self) private var store
  @State private var image: PlatformImage?

  init(message: ChatMessage, conversation: Conversation?, size: CGFloat = 26, theme: WritingTheme) {
    self.message = message
    self.conversation = conversation
    self.size = size
    self.theme = theme
    // Le fil recrée ses bulles au défilement : une photo déjà décodée revient
    // sans tâche ni décodage (cf. `ConversationAvatar`).
    _image = State(initialValue: Self.cachedImage(message: message, conversation: conversation, size: size))
  }

  private static func cachedImage(message: ChatMessage, conversation: Conversation?, size: CGFloat) -> PlatformImage? {
    let store = AttachmentThumbnailStore.shared
    if let conversation, !conversation.isGroup, let mxc = conversation.remoteAvatarID, !mxc.isEmpty {
      return store.cachedPortrait(key: "portrait|\(mxc)", maxPixel: size * 3)
    }
    let key = "\(conversation?.id ?? message.conversationID)|\(MessageGrouping.authorKey(message))"
    return store.cachedPortrait(key: "portrait|\(key)", maxPixel: size * 3)
  }

  var body: some View {
    ZStack {
      if let image {
        Image(platformImage: image)
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
    // La photo suit l'auteur, pas la bulle : deux prises de parole du même
    // expéditeur relancent la même tâche, servie par le cache des médias.
    .task(id: taskKey) { await load() }
    .accessibilityHidden(true)
  }

  private var authorKey: String { MessageGrouping.authorKey(message) }

  private var taskKey: String {
    "\(conversation?.id ?? message.conversationID)|\(authorKey)"
  }

  private func load() async {
    if let cached = Self.cachedImage(message: message, conversation: conversation, size: size) {
      image = cached
      return
    }
    image = nil
    // En tête-à-tête, l'auteur *est* le fil : on emprunte la photo du portail.
    // À la taille du disque (cf. `AttachmentThumbnailStore.portrait`).
    let maxPixel = size * 3
    if let conversation, !conversation.isGroup {
      if let mxc = conversation.remoteAvatarID, !mxc.isEmpty,
         let data = await store.matrix.avatarData(mxcURI: mxc),
         let loaded = await AttachmentThumbnailStore.shared.portrait(
           data: data, key: "portrait|\(mxc)", maxPixel: maxPixel)
      {
        image = loaded
        return
      }
    }
    guard let senderID = message.senderID, !senderID.isEmpty else { return }
    let data = await store.matrix.memberAvatarData(
      conversationID: conversation?.id ?? message.conversationID,
      userID: senderID
    )
    if let data,
       let loaded = await AttachmentThumbnailStore.shared.portrait(
         data: data, key: "portrait|\(taskKey)", maxPixel: maxPixel)
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

  /// La même palette que le Mac et la liste, tirée de l'auteur : un
  /// correspondant garde sa couleur d'une bulle à l'autre, et d'un appareil
  /// à l'autre.
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
