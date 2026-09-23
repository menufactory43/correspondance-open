import Foundation

public struct Conversation: Identifiable, Hashable, Sendable {
  public let id: String
  public let network: MessageNetwork
  /// Identifiant réseau (handle, chat guid, group id…).
  public let address: String
  public var title: String
  public var preview: String
  public var lastMessageAt: Date
  public var unreadCount: Int
  public var isArchived: Bool
  /// Clé chat.db / bridge pour l’envoi. Room ID Matrix pour les réseaux bridgés.
  public var transportKey: String
  /// Groupe iMessage, ou salon Matrix à plus de 2 membres humains.
  public var isGroup: Bool
  /// Acheminement du dernier message *sortant*, si le réseau l'expose (iMessage).
  /// `nil` = information indisponible → aucune coche affichée.
  public var lastDelivery: MessageDelivery?
  /// Le dernier message de l'aperçu vient de moi. Seul un `false` déclenche une notification.
  public var lastMessageIsFromMe: Bool = false
  /// Participants du fil, côté réseau (`chat_handle_join` pour iMessage).
  /// Vide quand le réseau ne les expose pas.
  public var participantHandles: [String] = []
  /// Photo du groupe déjà résolue sur le disque, quand il y en a une.
  public var groupPhotoPath: String? = nil
  /// Photo du fil telle que le réseau distant l'expose, pas encore téléchargée :
  /// un `mxc://` pour les fils bridgés. Le carnet d'adresses reste prioritaire.
  public var remoteAvatarID: String? = nil
  /// Photos des membres d'un groupe **sans** photo à lui : de quoi composer une
  /// mosaïque, comme Messages et Instagram. Vide dès qu'il y a mieux à montrer.
  public var memberAvatarIDs: [String] = []
  /// L'algorithme de `m.room.encryption` du salon Matrix, s'il y en a un.
  /// Vide pour iMessage, qui a son propre chiffrement et sa propre histoire.
  public var encryptionAlgorithm: String? = nil
  /// Ce qui attend depuis mon accusé de lecture, compté localement.
  ///
  /// `unreadCount` vient du serveur, qui compte des NOTIFICATIONS : il vaut
  /// toujours zéro sur un fil muet, dont la push rule dit « ne notifie pas ».
  /// Celui-ci se dérive de mon propre accusé et vaut muet ou pas — c'est lui
  /// qu'une ligne muette affiche (cf. `MatrixRoomModel.unreadSinceMyReceipt`).
  public var unreadSinceReceipt: Int = 0
  /// Le dernier message me nomme, ou répond à un de mes messages. Un fil muet
  /// notifie quand même pour ça — et pour ça seulement.
  public var lastMessageIsPersonal: Bool = false
  /// Le dernier élément du fil est une ligne d'événement — « Alice a rejoint
  /// le groupe », « … a renommé le groupe » — et non un message. Il fait
  /// remonter le fil, il ne sonne pas.
  public var lastMessageIsSystemEvent: Bool = false
  /// La réaction la plus récente d'un autre que moi, de quoi l'annoncer
  /// (« Alice a réagi 👍 à « … » »). `nil` sans réaction datée.
  public var lastIncomingReaction: IncomingReaction? = nil

  public var hasUnread: Bool { unreadCount > 0 }

  /// Les trois états, et seulement ceux-là : « chiffré » (salon natif portant
  /// `m.room.encryption`), « chiffré par le pont » (un portail — le pont lit en
  /// clair pour traduire), « en clair ».
  ///
  /// **Un portail ne montre jamais le cadenas du bout en bout**, même quand
  /// l'installeur a posé `encryption.default: true` sur le pont : ce chiffrement
  /// protège la base du Relais, pas la conversation.
  public var privacy: ConversationPrivacy {
    ConversationPrivacy.of(
      isBridged: network.isMatrixBridged, encryptionAlgorithm: encryptionAlgorithm)
  }

  public var rowSystemImage: String {
    if isGroup && network != .iMessage { return "person.3.fill" }
    return network.systemImage
  }

  /// Preview « catalogue » sans vrai message reçu. Les libellés sont ceux que
  /// `MatrixRoomModel.conversation` et le catalogue Signal posent faute de message :
  /// on les dérive des réseaux plutôt que de les recopier réseau par réseau.
  ///
  /// L'ensemble porte les DEUX formes : le français, qui est la clé du
  /// catalogue de chaînes, et la forme traduite que `MatrixRoomModel` vient
  /// d'écrire. Un aperçu posé en anglais doit se reconnaître comme un
  /// placeholder tout autant qu'en français ; et garder le français dedans
  /// laisse intacte la lecture d'une base écrite avant la traduction.
  public static let catalogPlaceholderPreviews: Set<String> = Set(
    MessageNetwork.allCases.filter { $0 != .iMessage }.flatMap {
      [
        "Groupe \($0.labelFR)", "Écrire sur \($0.labelFR)…", $0.labelFR,
        String(localized: "Groupe \($0.labelFR)"),
        String(localized: "Écrire sur \($0.labelFR)…"),
      ]
    }
  )

  public var hasLivePreview: Bool {
    !Self.catalogPlaceholderPreviews.contains(preview)
  }

  /// Titre encore technique / placeholder — à remplacer dès qu’on a un vrai nom.
  public var hasPlaceholderTitle: Bool {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return true }
    if trimmed == id { return true }
    if trimmed == address { return true }
    if trimmed == transportKey { return true }
    if trimmed.hasPrefix("signal-group:") || trimmed.hasPrefix("signal:") || trimmed.hasPrefix("imessage:") {
      return true
    }
    // Room ID Matrix nu (`!abc:correspondance.local`) ou ghost de pont non résolu.
    if trimmed.hasPrefix("!") { return true }
    if MatrixBridgeDescriptor.all.contains(where: {
      trimmed.hasPrefix("@\($0.ghostPrefix)") || trimmed.hasPrefix("\($0.network.rawValue):")
    }) {
      return true
    }
    if trimmed.hasPrefix("Groupe")
      && (trimmed == "Groupe" || trimmed.hasPrefix("Groupe (")
        || Self.catalogPlaceholderPreviews.contains(trimmed))
    {
      return true
    }
    // UUID nu ou numéro seul : pas un libellé humain.
    if trimmed.range(of: #"^[0-9a-fA-F-]{36}$"#, options: .regularExpression) != nil {
      return true
    }
    let digitsOnly = trimmed.filter(\.isNumber)
    let nonDialable = trimmed.filter { !$0.isNumber && !$0.isWhitespace && $0 != "+" && $0 != "-" && $0 != "(" && $0 != ")" && $0 != "." }
    // « +33 6 12 34 56 78 », « 0612345678 » → placeholder à enrichir via Contacts.
    if nonDialable.isEmpty, digitsOnly.count >= 8, digitsOnly.count >= trimmed.filter({ !$0.isWhitespace }).count - 1 {
      return true
    }
    return false
  }

  /// Installe un titre humain si le courant est encore technique / placeholder.
  public mutating func preferTitle(_ candidate: String) {
    let next = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !next.isEmpty else { return }
    var probe = self
    probe.title = next
    // Ne jamais installer un titre technique.
    guard !probe.hasPlaceholderTitle else { return }
    // Ne remplacer que si l’existant est mauvais (évite d’écraser un bon nom).
    if hasPlaceholderTitle {
      title = next
    }
  }

  public init(id: String, network: MessageNetwork, address: String, title: String, preview: String, lastMessageAt: Date, unreadCount: Int, isArchived: Bool, transportKey: String, isGroup: Bool, lastDelivery: MessageDelivery? = nil, lastMessageIsFromMe: Bool = false, participantHandles: [String] = [], groupPhotoPath: String? = nil, remoteAvatarID: String? = nil, memberAvatarIDs: [String] = []) {
    self.id = id
    self.network = network
    self.address = address
    self.title = title
    self.preview = preview
    self.lastMessageAt = lastMessageAt
    self.unreadCount = unreadCount
    self.isArchived = isArchived
    self.transportKey = transportKey
    self.isGroup = isGroup
    self.lastDelivery = lastDelivery
    self.lastMessageIsFromMe = lastMessageIsFromMe
    self.participantHandles = participantHandles
    self.groupPhotoPath = groupPhotoPath
    self.remoteAvatarID = remoteAvatarID
    self.memberAvatarIDs = memberAvatarIDs
  }
}

/// Une réaction reçue, telle qu'une notification la raconte.
public struct IncomingReaction: Hashable, Sendable {
  /// L'event `m.reaction` : deux réactions ne se confondent jamais.
  public var id: String
  public var senderName: String
  public var emoji: String
  /// Le message visé, en une ligne (`sidebarPreviewText`) ; `nil` s'il n'est
  /// pas dans ce qu'on a chargé du fil.
  public var targetPreview: String?
  public var sentAt: Date

  public init(id: String, senderName: String, emoji: String, targetPreview: String?, sentAt: Date) {
    self.id = id
    self.senderName = senderName
    self.emoji = emoji
    self.targetPreview = targetPreview
    self.sentAt = sentAt
  }

  /// « Alice a réagi 👍 à « On se voit demain ? » ». Le message visé est
  /// coupé : sur l'écran verrouillé, c'est la réaction qui compte.
  public var bodyFR: String {
    Self.body(senderName: senderName, emoji: emoji, targetPreview: targetPreview)
  }

  public static func body(senderName: String?, emoji: String, targetPreview: String?) -> String {
    let who = senderName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let quoted = targetPreview?
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let short = quoted.count > 60 ? String(quoted.prefix(59)).trimmingCharacters(in: .whitespaces) + "…" : quoted
    switch (who.isEmpty, short.isEmpty) {
    case (false, false): return String(localized: "\(who) a réagi \(emoji) à « \(short) »")
    case (false, true): return String(localized: "\(who) a réagi \(emoji)")
    case (true, false): return String(localized: "A réagi \(emoji) à « \(short) »")
    case (true, true): return String(localized: "A réagi \(emoji)")
    }
  }
}
