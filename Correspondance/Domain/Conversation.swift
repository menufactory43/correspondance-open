import Foundation

struct Conversation: Identifiable, Hashable, Sendable {
  let id: String
  let network: MessageNetwork
  /// Identifiant réseau (handle, chat guid, group id…).
  let address: String
  var title: String
  var preview: String
  var lastMessageAt: Date
  var unreadCount: Int
  var isArchived: Bool
  /// Clé chat.db / bridge pour l’envoi. Room ID Matrix pour les réseaux bridgés.
  var transportKey: String
  /// Groupe Signal (envoi via `-g`) ou salon Matrix à plus de 2 membres humains.
  var isGroup: Bool
  /// Acheminement du dernier message *sortant*, si le réseau l'expose (iMessage).
  /// `nil` = information indisponible → aucune coche affichée.
  var lastDelivery: MessageDelivery?
  /// Le dernier message de l'aperçu vient de moi. Seul un `false` déclenche une notification.
  var lastMessageIsFromMe: Bool = false
  /// Participants du fil, côté réseau (`chat_handle_join` pour iMessage).
  /// Vide quand le réseau ne les expose pas.
  var participantHandles: [String] = []
  /// Photo du groupe déjà résolue sur le disque, quand il y en a une.
  var groupPhotoPath: String? = nil
  /// Photo du fil telle que le réseau distant l'expose, pas encore téléchargée :
  /// un `mxc://` pour les fils bridgés. Le carnet d'adresses reste prioritaire.
  var remoteAvatarID: String? = nil

  var hasUnread: Bool { unreadCount > 0 }

  var rowSystemImage: String {
    if isGroup && network != .iMessage { return "person.3.fill" }
    return network.systemImage
  }

  /// Preview « catalogue » sans vrai message reçu. Les libellés sont ceux que
  /// `MatrixRoomModel.conversation` et le catalogue Signal posent faute de message :
  /// on les dérive des réseaux plutôt que de les recopier réseau par réseau.
  static let catalogPlaceholderPreviews: Set<String> = Set(
    MessageNetwork.allCases.filter { $0 != .iMessage }.flatMap {
      ["Groupe \($0.labelFR)", "Écrire sur \($0.labelFR)…", $0.labelFR]
    }
  )

  var hasLivePreview: Bool {
    !Self.catalogPlaceholderPreviews.contains(preview)
  }

  /// Titre encore technique / placeholder — à remplacer dès qu’on a un vrai nom.
  var hasPlaceholderTitle: Bool {
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
  mutating func preferTitle(_ candidate: String) {
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
}
