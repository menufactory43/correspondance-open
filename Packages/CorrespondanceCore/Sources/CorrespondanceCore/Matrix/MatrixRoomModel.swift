import Foundation

/// Modèle de salon reconstruit à partir de `/sync`. Pur, `Sendable`, sans réseau :
/// c'est cette couche que les tests exercent avec des fixtures.
public struct MatrixRoomModel: Sendable {
  public let roomID: String
  public var network: MessageNetwork?
  /// `m.room.name` explicite (groupes, et DM si `private_chat_portal_meta`).
  public var explicitName: String?
  /// Nom du chat distant annoncé par l'état de bridge.
  public var bridgeChannelName: String?
  /// Numéro si — et seulement si — le bridge l'expose. Jamais déduit du MXID (ghosts LID).
  public var bridgePhoneNumber: String?
  /// `m.room.avatar` du portail : mautrix y pose la photo du chat distant (groupe,
  /// et DM quand `private_chat_portal_meta` est actif). C'est la seule image que
  /// le pont expose pour un fil sans numéro — Instagram n'en a jamais d'autre.
  public var avatarMXC: String?
  /// `com.beeper.room_type` de l'état de bridge : `dm` / `group`. Fait foi sur le comptage
  /// des membres (le bridge ajoute aussi notre propre ghost dans les DM).
  public var bridgeRoomType: String?
  public var members: [String: Member] = [:]
  public var heroes: [String] = []
  public var unreadCount: Int = 0
  public var messagesByID: [String: ChatMessage] = [:]
  /// Réactions indexées par **event de réaction**, pas par cible : c'est ce qui permet
  /// à une `m.room.redaction` d'en retirer une seule, précisément.
  public var reactionsByEventID: [String: ReactionEvent] = [:]
  /// Dernier event lu par chaque correspondant (`m.receipt` / `m.read` du `/sync`).
  /// mautrix-whatsapp pose un seul marqueur « jusqu'ici » par personne.
  public var readMarkerByUser: [String: String] = [:]
  /// Réponses dont la cible n'est pas encore en main (le pont Signal ne donne
  /// que l'`event_id` cité, sans texte). Elles se résolvent dès que la cible
  /// arrive — et disent au service ce qu'il reste à aller chercher.
  public var unresolvedQuoteMessageIDs: Set<String> = []
  public var lastEventAt: Date = .distantPast
  /// Les modifications reçues avant le message qu'elles corrigent — une page
  /// remontée à l'envers en livre. La dernière par cible seulement : c'est
  /// elle qui fait foi, les intermédiaires n'ont plus rien à dire.
  public var pendingEdits: [String: PendingEdit] = [:]

  /// Ce que le magasin local n'a pas encore vu : messages et réactions posés ou
  /// corrigés depuis la dernière écriture. C'est ce qui permet d'écrire un
  /// **lot** plutôt que de réécrire tout le fil à chaque passe de `/sync`.
  public var pendingWrites: Set<String> = []
  /// Ce que le magasin doit oublier : rédactions reçues depuis.
  public var pendingDeletions: Set<String> = []

  /// Après écriture : on repart d'une ardoise propre.
  public mutating func clearPendingWrites() {
    pendingWrites.removeAll()
    pendingDeletions.removeAll()
  }

  /// Un event qu'on vient de poser ou de corriger.
  mutating func markWritten(_ eventID: String) {
    pendingDeletions.remove(eventID)
    pendingWrites.insert(eventID)
  }

  /// Un event qui vient de disparaître.
  mutating func markDeleted(_ eventID: String) {
    pendingWrites.remove(eventID)
    pendingDeletions.insert(eventID)
  }

  /// Une modification en attente de sa cible.
  public struct PendingEdit: Sendable, Hashable, Codable {
    public var text: String
    public var at: Date
    /// Qui corrige : à la naissance de la cible, seule une correction de son
    /// auteur s'applique — comme quand la cible est déjà là.
    public var sender: String?

    public init(text: String, at: Date, sender: String? = nil) {
      self.text = text
      self.at = at
      self.sender = sender
    }
  }

  /// Qui est en train d'écrire, d'après la dernière EDU `m.typing`, et quand
  /// on l'a apprise. L'EDU n'est renvoyée qu'au **changement** : sans date, un
  /// « Alice écrit… » resterait à l'écran jusqu'au prochain message.
  public var typingUserIDs: Set<String> = []
  public var typingUpdatedAt: Date = .distantPast

  /// Au-delà, on considère que la personne a fini d'écrire. Le serveur donne
  /// aux clients un `timeout` de 20 à 30 s ; on prend la borne basse, quitte à
  /// faire clignoter l'indicateur plutôt qu'à le laisser mentir.
  public static let typingLifetime: TimeInterval = 20

  /// Les personnes qui écrivent VRAIMENT, maintenant — moi excepté.
  public func typingUserIDs(now: Date, selfUserID: String) -> [String] {
    guard now.timeIntervalSince(typingUpdatedAt) < Self.typingLifetime else { return [] }
    return typingUserIDs.filter { $0 != selfUserID }.sorted()
  }

  /// « Alice écrit… », « Alice et Bruno écrivent… », « 3 personnes écrivent… ».
  /// `nil` quand personne n'écrit : la vue n'a alors rien à réserver.
  public func typingLabelFR(now: Date, selfUserID: String) -> String? {
    let names = typingUserIDs(now: now, selfUserID: selfUserID)
      .map { members[$0]?.displayName ?? "" }
      .filter { !$0.isEmpty }
    let count = typingUserIDs(now: now, selfUserID: selfUserID).count
    guard count > 0 else { return nil }
    switch names.count {
    case 0: return count == 1 ? "Quelqu'un écrit…" : "\(count) personnes écrivent…"
    case 1: return "\(names[0]) écrit…"
    case 2: return "\(names[0]) et \(names[1]) écrivent…"
    default: return "\(names.count) personnes écrivent…"
    }
  }

  /// Les sondages du salon, par event de départ. Séparés des messages : trois
  /// events les composent, et une voix arrive souvent avant qu'on ait la
  /// question sous la main.
  public var pollsByEventID: [String: PollEvent] = [:]

  /// Un sondage en cours de dépouillement : la question, les voix reçues, la
  /// clôture. Le `Poll` du message s'en déduit à chaque lecture du fil.
  public struct PollEvent: Sendable, Hashable, Codable {
    public var poll: Poll
    /// La forme sous laquelle le sondage est arrivé — c'est celle sous
    /// laquelle il faudra répondre.
    public var startType: String
    /// La dernière voix de chaque personne, et quand elle l'a émise : une voix
    /// plus ancienne qui arrive après (page remontée) ne doit rien écraser.
    public var voteTimes: [String: Date] = [:]
    /// L'heure de clôture, s'il y en a une. Une voix postérieure ne compte pas.
    public var closedAt: Date?

    public init(poll: Poll, startType: String) {
      self.poll = poll
      self.startType = startType
    }
  }

  /// Le pont annonce-t-il un fil « en attente » — une demande côté réseau ?
  ///
  /// Instagram et Messenger ont bien une boîte de demandes, et Signal une
  /// « invitation de message ». Aucun pont mautrix v26.08 ne l'expose dans
  /// `m.bridge` à ce jour : on lit les clés que Beeper et mautrix emploieraient
  /// s'ils s'y mettaient, et en attendant ce drapeau reste faux — la demande se
  /// prouve alors autrement (`RequestPolicy`).
  public var isNetworkFlaggedRequest = false

  /// `channel.id` de l'état de bridge (`81540071608362@lid`, `33612345678@s.whatsapp.net`, `…@g.us`).
  /// Dans un DM, c'est la clé qui distingue le correspondant de notre propre ghost.
  public var bridgeChannelID: String?

  /// Une `m.reaction` reçue. `isMine` est figé à l'analyse : le modèle n'a pas
  /// besoin de reconnaître notre identité pour rendre les pastilles.
  public struct ReactionEvent: Sendable, Hashable, Codable {
    public var targetEventID: String
    public var emoji: String
    public var senderID: String
    public var senderName: String
    public var isMine: Bool
  }

  public struct Member: Sendable, Hashable, Codable {
    public var displayName: String?
    public var membership: String
    /// `content.avatar_url` du `m.room.member` : la photo du ghost. C'est la seule
    /// image qu'on ait des participants d'un groupe sans photo de groupe.
    public var avatarMXC: String?

    public var isActive: Bool { membership == "join" || membership == "invite" }
  }

  public init(roomID: String) {
    self.roomID = roomID
  }

  public var conversationID: String {
    "\(network?.rawValue ?? "matrix"):\(roomID)"
  }

  /// Membres humains distants : ni moi, ni le bot de bridge, ni mon propre ghost.
  /// mautrix ajoute notre ghost dans chaque DM : on ne garde alors que le correspondant,
  /// reconnu par `channel.id` (`<id>@lid` ↔ `@whatsapp_lid-<id>`, `<num>@s.whatsapp.net` ↔
  /// `@whatsapp_<num>`, et côté Instagram un identifiant Meta nu ↔ `@instagram_<id>`).
  public func remoteMembers(selfUserID: String) -> [(userID: String, member: Member)] {
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

  /// Photos des membres distants, pour la mosaïque d'un groupe sans photo à lui.
  /// Ordre stable — nom puis MXID — pour que la vignette ne se recompose pas
  /// différemment d'une passe de `/sync` à l'autre. Quatre au plus, comme Messages.
  public func memberAvatarMXCs(selfUserID: String) -> [String] {
    remoteMembers(selfUserID: selfUserID)
      .compactMap { entry -> (name: String, userID: String, mxc: String)? in
        guard let mxc = entry.member.avatarMXC, !mxc.isEmpty else { return nil }
        return (entry.member.displayName ?? "", entry.userID, mxc)
      }
      .sorted { ($0.name, $0.userID) < ($1.name, $1.userID) }
      .prefix(4)
      .map(\.mxc)
  }

  public func isGroup(selfUserID: String) -> Bool {
    switch bridgeRoomType {
    case "dm": return false
    case "group", "space": return true
    default: return remoteMembers(selfUserID: selfUserID).count > 1
    }
  }

  /// Titre humain : nom du salon, puis nom annoncé par le bridge, puis le correspondant.
  public func title(selfUserID: String) -> String {
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

  /// Messages du salon, réactions déjà rattachées et agrégées.
  /// Mon dernier message sortant — celui qui porte la coche.
  public var lastOutgoingMessage: ChatMessage? {
    messagesByID.values.filter(\.isFromMe).max { $0.sentAt < $1.sentAt }
  }

  /// Acheminement de mon dernier message, d'après les accusés reçus.
  ///
  /// WhatsApp ne bridge que la **lecture** : mautrix mappe bien `ReceiptTypeDelivered`,
  /// mais rien n'en ressort côté Matrix pour un client tiers. On n'affiche donc jamais
  /// « Livré » ici — seulement « Envoyé » ou « Vu ».
  public func delivery(selfUserID: String) -> MessageDelivery? {
    guard lastOutgoingMessage != nil else { return nil }
    return readersOfLastOutgoingMessage(selfUserID: selfUserID).isEmpty ? .sent : .read
  }

  /// Qui a lu mon dernier message sortant — moi, les bots et l'agent « cc »
  /// exclus. La lecture de l'agent est celle d'un robot : elle ne vaut pas
  /// un « Vu » de quelqu'un.
  public func readersOfLastOutgoingMessage(selfUserID: String) -> [String] {
    guard let mine = lastOutgoingMessage else { return [] }
    let agentID = MatrixIdentity.agentUserID(sameServerAs: selfUserID)
    return readMarkerByUser.compactMap { userID, eventID in
      guard userID != selfUserID, userID != agentID,
            !MatrixIdentity.isBridgeBot(userID),
            // Le marqueur vaut « lu jusqu'ici » : il suffit qu'il ait atteint mon message.
            let marker = messagesByID[eventID],
            marker.sentAt >= mine.sentAt
      else { return nil }
      return userID
    }
  }

  /// « Vu par Alice et Bruno » : le détail des lecteurs de mon dernier message,
  /// dans un groupe seulement — en DM, le « Vu » simple dit déjà tout.
  /// `nil` tant que personne n'a lu : la vue n'a alors rien à réserver.
  public func seenByLabelFR(selfUserID: String) -> String? {
    guard isGroup(selfUserID: selfUserID) else { return nil }
    let readers = readersOfLastOutgoingMessage(selfUserID: selfUserID)
    guard !readers.isEmpty else { return nil }
    let remoteCount = remoteMembers(selfUserID: selfUserID).count
    if remoteCount > 1, readers.count >= remoteCount { return "Vu par tout le monde" }
    let names = readers
      .compactMap { members[$0]?.displayName }
      .filter { !$0.isEmpty }
      .sorted()
    switch (names.count, readers.count) {
    case (0, 1): return "Vu par 1 personne"
    case (0, let count): return "Vu par \(count) personnes"
    case (1, 1): return "Vu par \(names[0])"
    case (2, 2): return "Vu par \(names[0]) et \(names[1])"
    case (3, 3): return "Vu par \(names[0]), \(names[1]) et \(names[2])"
    default:
      // Des lecteurs sans nom, ou trop de noms : deux noms puis le reste en nombre.
      let rest = readers.count - 2
      guard names.count >= 2 else { return "Vu par \(readers.count) personnes" }
      return "Vu par \(names[0]), \(names[1]) et \(rest) autre\(rest > 1 ? "s" : "")"
    }
  }

  public var sortedMessages: [ChatMessage] {
    var byTarget: [String: [(emoji: String, sender: String, isMine: Bool)]] = [:]
    for reaction in reactionsByEventID.values {
      byTarget[reaction.targetEventID, default: []]
        .append((emoji: reaction.emoji, sender: reaction.senderName, isMine: reaction.isMine))
    }
    return messagesByID.values
      .map { message in
        var updated = message
        if let raw = byTarget[message.id] {
          updated.reactions = MessageReaction.aggregate(raw)
        }
        // Le sondage est dépouillé au moment de rendre le fil : les voix ont
        // pu arriver bien après la question.
        if let poll = pollsByEventID[message.id]?.poll { updated.poll = poll }
        return updated
      }
      .sorted { $0.sentAt < $1.sentAt }
  }

  /// Le dernier message qui a le droit de représenter le fil dans la file.
  ///
  /// Une proposition de l'agent n'a été dite à personne : elle ne devient ni
  /// l'aperçu de la ligne d'inbox, ni la date qui fait remonter le fil.
  public var lastListedMessage: ChatMessage? {
    sortedMessages.last { !$0.isAgentProposal }
  }

  /// La note à soi : un salon sans pont dont je suis le seul habitant.
  ///
  /// La reconnaissance ne se devine pas — c'est l'account data global
  /// `fr.correspondance.self_note` qui désigne le salon, et l'appelant qui le
  /// passe ici. Un salon vide ou un salon de gestion abandonné ne deviendra
  /// jamais une note à soi par accident.
  public func selfNoteConversation(selfUserID: String) -> Conversation {
    let last = lastListedMessage
    var conversation = Conversation(
      id: "\(MessageNetwork.selfNote.rawValue):\(roomID)",
      network: .selfNote,
      address: roomID,
      title: explicitName?.isEmpty == false ? explicitName! : MessageNetwork.selfNote.labelFR,
      preview: last?.sidebarPreviewText ?? "Se laisser un mot…",
      lastMessageAt: last?.sentAt ?? lastEventAt,
      unreadCount: 0,
      isArchived: false,
      transportKey: roomID,
      isGroup: false
    )
    conversation.lastMessageIsFromMe = true
    if conversation.lastMessageAt == .distantPast {
      conversation.lastMessageAt = Date(timeIntervalSince1970: 0)
    }
    return conversation
  }

  /// `nil` tant que le salon n'est pas un portail de bridge reconnu (salon de gestion, espace…).
  public func conversation(selfUserID: String) -> Conversation? {
    guard let network else { return nil }
    let group = isGroup(selfUserID: selfUserID)
    let last = lastListedMessage
    let preview = last?.listPreview(isGroup: group)
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
    conversation.remoteAvatarID = avatarMXC
    // Un groupe sans photo se raconte par ses visages ; un DM, lui, a déjà le sien.
    conversation.memberAvatarIDs = (group && avatarMXC == nil)
      ? memberAvatarMXCs(selfUserID: selfUserID)
      : []
    conversation.lastMessageIsFromMe = last?.isFromMe ?? false
    conversation.lastDelivery = (last?.isFromMe == true) ? delivery(selfUserID: selfUserID) : nil
    if conversation.lastMessageAt == .distantPast {
      conversation.lastMessageAt = Date(timeIntervalSince1970: 0)
    }
    return conversation
  }
}

/// Reconnaissance des identifiants mautrix, à partir des descripteurs de ponts.
/// **Ne jamais** en extraire un numéro : depuis v26.08 les ghosts WhatsApp sont des LID
/// (`@whatsapp_lid-1234:serveur`), et un ghost Instagram est un identifiant Meta.
public enum MatrixIdentity {
  public static func localpart(_ userID: String) -> String {
    let withoutSigil = userID.hasPrefix("@") ? String(userID.dropFirst()) : userID
    return String(withoutSigil.prefix { $0 != ":" })
  }

  public static func isBridgeBot(_ userID: String) -> Bool {
    network(ofBot: userID) != nil
  }

  /// Le nom sous lequel on appelle l'agent : « @cc » réveille le bot, c'est
  /// donc une mention comme une autre — et elle doit se voir comme telle.
  public static let agentName = "cc"

  /// Le MXID de l'agent « cc » : il vit sur le même Relais que soi.
  public static func agentUserID(sameServerAs selfUserID: String) -> String {
    "@\(agentName):\(String(selfUserID.split(separator: ":").last ?? ""))"
  }

  /// Réseau du bot de gestion, quand ce MXID en est un.
  public static func network(ofBot userID: String) -> MessageNetwork? {
    MatrixBridgeDescriptor.network(ofBot: userID)
  }

  /// « Malo (WA) » → « Malo » : mautrix suffixe les noms de ghosts avec le réseau.
  /// La liste vient des descripteurs, plus quelques ponts qu'on ne gère pas encore
  /// mais dont les noms peuvent traverser un groupe.
  public static let foreignBridgeSuffixes = [" (FB)", " (Messenger)"]

  public static func stripBridgeSuffix(_ name: String) -> String {
    var trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let suffixes = MatrixBridgeDescriptor.all.flatMap(\.displayNameSuffixes) + foreignBridgeSuffixes
    for suffix in suffixes where trimmed.hasSuffix(suffix) {
      trimmed = String(trimmed.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
      break
    }
    return trimmed
  }

  /// `@cc:correspondance.local` → `cc`.
  public static func localpart(of userID: String) -> String {
    let withoutSigil = userID.hasPrefix("@") ? String(userID.dropFirst()) : userID
    return String(withoutSigil.prefix { $0 != ":" })
  }

  public static func isGhost(_ userID: String) -> Bool {
    network(ofGhost: userID) != nil
  }

  /// Réseau du ghost, quand ce MXID en est un.
  public static func network(ofGhost userID: String) -> MessageNetwork? {
    MatrixBridgeDescriptor.network(ofGhost: userID)
  }

  /// Un numéro exploitable pour `ContactDirectory` — sinon `nil`, sans jamais faire échouer l'appelant.
  public static func phoneNumber(in candidate: String?) -> String? {
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
