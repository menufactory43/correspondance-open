import Foundation

/// Modèle de salon reconstruit à partir de `/sync`. Pur, `Sendable`, sans réseau :
/// c'est cette couche que les tests exercent avec des fixtures.
struct MatrixRoomModel: Sendable {
  let roomID: String
  var network: MessageNetwork?
  /// `m.room.name` explicite (groupes, et DM si `private_chat_portal_meta`).
  var explicitName: String?
  /// Nom du chat distant annoncé par l'état de bridge.
  var bridgeChannelName: String?
  /// Numéro si — et seulement si — le bridge l'expose. Jamais déduit du MXID (ghosts LID).
  var bridgePhoneNumber: String?
  /// `com.beeper.room_type` de l'état de bridge : `dm` / `group`. Fait foi sur le comptage
  /// des membres (le bridge ajoute aussi notre propre ghost dans les DM).
  var bridgeRoomType: String?
  var members: [String: Member] = [:]
  var heroes: [String] = []
  var unreadCount: Int = 0
  var messagesByID: [String: ChatMessage] = [:]
  var lastEventAt: Date = .distantPast
  /// `channel.id` de l'état de bridge (`81540071608362@lid`, `33612345678@s.whatsapp.net`, `…@g.us`).
  /// Dans un DM, c'est la clé qui distingue le correspondant de notre propre ghost.
  var bridgeChannelID: String?

  struct Member: Sendable, Hashable {
    var displayName: String?
    var membership: String

    var isActive: Bool { membership == "join" || membership == "invite" }
  }

  init(roomID: String) {
    self.roomID = roomID
  }

  var conversationID: String {
    "\(network?.rawValue ?? "matrix"):\(roomID)"
  }

  /// Membres humains distants : ni moi, ni le bot de bridge, ni mon propre ghost.
  /// mautrix ajoute notre ghost dans chaque DM : on ne garde alors que le correspondant,
  /// reconnu par `channel.id` (`<id>@lid` ↔ `@whatsapp_lid-<id>`, `<num>@s.whatsapp.net` ↔ `@whatsapp_<num>`).
  func remoteMembers(selfUserID: String) -> [(userID: String, member: Member)] {
    let humans: [(userID: String, member: Member)] = members
      .filter { key, value in
        value.isActive
          && key != selfUserID
          && !MatrixIdentity.isBridgeBot(key)
      }
      .map { (userID: $0.key, member: $0.value) }
      .sorted { $0.userID < $1.userID }
    if bridgeRoomType == "dm",
       let channelLocal = bridgeChannelID?.split(separator: "@").first.map(String.init),
       !channelLocal.isEmpty,
       let peer = humans.first(where: { MatrixIdentity.localpart($0.userID).hasSuffix(channelLocal) })
    {
      return [peer]
    }
    return humans
  }

  func isGroup(selfUserID: String) -> Bool {
    switch bridgeRoomType {
    case "dm": return false
    case "group", "space": return true
    default: return remoteMembers(selfUserID: selfUserID).count > 1
    }
  }

  /// Titre humain : nom du salon, puis nom annoncé par le bridge, puis le correspondant.
  func title(selfUserID: String) -> String {
    if let explicitName, !explicitName.isEmpty { return explicitName }
    if let bridgeChannelName, !bridgeChannelName.isEmpty { return bridgeChannelName }
    let remotes = remoteMembers(selfUserID: selfUserID)
    if remotes.count == 1, let name = remotes[0].member.displayName, !name.isEmpty {
      return name
    }
    if !remotes.isEmpty {
      let names = remotes.compactMap { $0.member.displayName }.filter { !$0.isEmpty }
      if !names.isEmpty { return names.prefix(3).joined(separator: ", ") }
    }
    if let phone = bridgePhoneNumber { return phone }
    return roomID
  }

  var sortedMessages: [ChatMessage] {
    messagesByID.values.sorted { $0.sentAt < $1.sentAt }
  }

  /// `nil` tant que le salon n'est pas un portail de bridge reconnu (salon de gestion, espace…).
  func conversation(selfUserID: String) -> Conversation? {
    guard let network else { return nil }
    let group = isGroup(selfUserID: selfUserID)
    let last = sortedMessages.last
    let preview = last?.sidebarPreviewText
      ?? (group ? "Groupe \(network.labelFR)" : "Écrire sur \(network.labelFR)…")
    var conversation = Conversation(
      id: conversationID,
      network: network,
      // Le numéro s'il existe (matching Contacts), sinon le salon : jamais un MXID de ghost.
      address: bridgePhoneNumber ?? roomID,
      title: title(selfUserID: selfUserID),
      preview: preview,
      lastMessageAt: last?.sentAt ?? lastEventAt,
      unreadCount: unreadCount,
      isArchived: false,
      transportKey: roomID,
      isGroup: group
    )
    conversation.lastMessageIsFromMe = last?.isFromMe ?? false
    if conversation.lastMessageAt == .distantPast {
      conversation.lastMessageAt = Date(timeIntervalSince1970: 0)
    }
    return conversation
  }
}

/// Reconnaissance des identifiants mautrix. **Ne jamais** en extraire un numéro :
/// depuis v26.08 les ghosts WhatsApp sont des LID (`@whatsapp_lid-1234:serveur`).
enum MatrixIdentity {
  static func localpart(_ userID: String) -> String {
    let withoutSigil = userID.hasPrefix("@") ? String(userID.dropFirst()) : userID
    return String(withoutSigil.prefix { $0 != ":" })
  }

  static func isBridgeBot(_ userID: String) -> Bool {
    let local = localpart(userID)
    return local.hasSuffix("bot") && MessageNetwork.allCases.contains { local.hasPrefix($0.rawValue.lowercased()) }
  }

  /// « Malo (WA) » → « Malo » : mautrix suffixe les noms de ghosts avec le réseau.
  static func stripBridgeSuffix(_ name: String) -> String {
    var trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    for suffix in [" (WA)", " (WhatsApp)", " (IG)", " (Instagram)", " (FB)", " (Messenger)", " (Signal)"] {
      if trimmed.hasSuffix(suffix) {
        trimmed = String(trimmed.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        break
      }
    }
    return trimmed
  }

  static func isGhost(_ userID: String) -> Bool {
    let local = localpart(userID)
    return MessageNetwork.allCases.contains { local.hasPrefix("\($0.rawValue.lowercased())_") }
  }

  /// Un numéro exploitable pour `ContactDirectory` — sinon `nil`, sans jamais faire échouer l'appelant.
  static func phoneNumber(in candidate: String?) -> String? {
    guard let candidate else { return nil }
    let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let digits = trimmed.filter(\.isNumber)
    guard digits.count >= 8, digits.count <= 15 else { return nil }
    // Refuse tout ce qui contient des lettres : « lid-1234567890 » n'est pas un numéro.
    let allowed = CharacterSet(charactersIn: "+0123456789 -().")
    guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
    return trimmed.hasPrefix("+") ? trimmed : "+\(digits)"
  }
}
