import Foundation
import CorrespondanceCore

/// Une façon de joindre quelqu'un : un fil qui existe déjà sur un réseau, ou
/// un fil qu'on peut ouvrir avec un identifiant qu'on lui connaît.
struct Reach: Identifiable, Hashable {
  let network: MessageNetwork
  /// Le fil à sélectionner. `nil` : il n'existe pas encore, on l'ouvrira avec `handle`.
  let conversationID: String?
  /// L'identifiant sur ce réseau — numéro, e-mail, ou l'adresse du fil.
  let handle: String

  var isExisting: Bool { conversationID != nil }
  var id: String { "\(network.rawValue)|\(conversationID ?? "fresh:" + handle)" }
}

/// Une personne, avec tous les réseaux où on peut la joindre. C'est l'unité de
/// la feuille « Nouvelle conversation » : on choisit quelqu'un, puis par où.
struct ReachablePerson: Identifiable {
  let id: String
  var name: String
  /// Ce qui s'affiche sous le nom : le numéro ou l'adresse qu'on connaît.
  var detail: String
  /// Ce que la vue dessine comme portrait : un vrai fil quand il y en a un,
  /// sinon une fiche iMessage fictive que le carnet d'adresses sait illustrer.
  var avatar: Conversation
  /// Fils existants d'abord (du plus récent au plus ancien), puis les réseaux
  /// où un fil neuf peut s'ouvrir.
  var reaches: [Reach]
  /// Dernier échange, tous réseaux confondus. `nil` : on ne la connaît que du carnet.
  var lastMessageAt: Date?

  var isKnownOnRelay: Bool { lastMessageAt != nil }
  var primaryReach: Reach? { reaches.first }
  func reach(on network: MessageNetwork) -> Reach? { reaches.first { $0.network == network } }
}

/// Construit la liste des personnes joignables à partir de ce que l'app sait :
/// les fils en tête-à-tête (dont les lignes fusionnées), et le carnet d'adresses.
///
/// Une même personne reconnue par son numéro sur deux réseaux ne fait qu'une
/// ligne, avec deux réseaux. Un contact du carnet sans aucun fil n'apparaît
/// que sur les réseaux où son identifiant permet d'ouvrir un fil neuf — jamais
/// un « contact WhatsApp » proposé sous iMessage.
enum ReachablePeople {
  /// Les réseaux où l'on peut ouvrir un fil neuf à partir d'un numéro ou d'une
  /// adresse — iMessage toujours sur Mac ; WhatsApp et Signal quand leur pont
  /// est branché. Instagram et Messenger ne connaissent pas les numéros.
  static func freshNetworks(isMatrixConnected: Bool, inUse: (MessageNetwork) -> Bool) -> [MessageNetwork] {
    var networks: [MessageNetwork] = [.iMessage]
    if isMatrixConnected {
      for network in [MessageNetwork.whatsapp, .signal] where inUse(network) {
        networks.append(network)
      }
    }
    return networks
  }

  static func build(
    conversations: [Conversation],
    members: (String) -> [Conversation],
    book: [ContactDirectory.DirectoryHit],
    freshNetworks: [MessageNetwork]
  ) -> [ReachablePerson] {
    var people: [ReachablePerson] = []
    var indexByKey: [String: Int] = [:]

    func person(forKeys keys: [String], create: () -> ReachablePerson) -> Int {
      if let index = keys.lazy.compactMap({ indexByKey[$0] }).first {
        for key in keys { indexByKey[key] = index }
        return index
      }
      people.append(create())
      let index = people.count - 1
      for key in keys { indexByKey[key] = index }
      return index
    }

    // 1. Les fils : un tête-à-tête EST un contact. Les lignes fusionnées
    //    apportent un réseau par membre, mais s'ouvrent comme une seule ligne.
    //    Du plus récent au plus ancien : c'est l'ordre des pastilles d'une personne.
    for conversation in conversations.sorted(by: { $0.lastMessageAt > $1.lastMessageAt })
    where !conversation.isGroup && conversation.network != .selfNote && conversation.network != .agent {
      let parts = MergedContact.isMergedID(conversation.id) ? members(conversation.id) : [conversation]
      guard !parts.isEmpty else { continue }

      var keys = parts.flatMap(identityKeys)
      if keys.isEmpty { keys = ["conv:" + conversation.id] }

      let index = person(forKeys: keys) {
        ReachablePerson(
          id: conversation.id,
          name: conversation.title,
          detail: displayHandle(of: parts.first ?? conversation),
          avatar: conversation,
          reaches: [],
          lastMessageAt: conversation.lastMessageAt
        )
      }

      for part in parts.sorted(by: { $0.lastMessageAt > $1.lastMessageAt })
      where !people[index].reaches.contains(where: { $0.network == part.network && $0.isExisting }) {
        people[index].reaches.append(
          Reach(network: part.network, conversationID: conversation.id, handle: part.address)
        )
      }
      if let last = people[index].lastMessageAt, last < conversation.lastMessageAt {
        people[index].lastMessageAt = conversation.lastMessageAt
        people[index].avatar = conversation
      }
      if people[index].lastMessageAt == nil {
        people[index].lastMessageAt = conversation.lastMessageAt
      }
    }

    // 2. Le carnet d'adresses : son nom prime (c'est celui qu'on tape), et
    //    chaque identifiant ouvre les réseaux qui savent le composer.
    for hit in book {
      let handle = hit.handle.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !handle.isEmpty else { continue }
      let nameKey = "name:" + hit.name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
      var keys = [nameKey]
      if let identity = PhoneNormalizer.identityKey(for: handle) { keys.insert(identity, at: 0) }

      let index = person(forKeys: keys) {
        ReachablePerson(
          id: "book:" + (keys.first ?? handle),
          name: hit.name,
          detail: handle,
          avatar: bookAvatar(name: hit.name, handle: handle),
          reaches: [],
          lastMessageAt: nil
        )
      }
      // Le nom du carnet prime, et le portrait le suit : ses initiales ne
      // doivent pas être celles d'un numéro resté en titre de fil.
      people[index].name = hit.name
      people[index].avatar.title = hit.name

      let isEmail = handle.contains("@")
      for network in freshNetworks
      where !people[index].reaches.contains(where: { $0.network == network }) {
        // Un e-mail n'ouvre qu'iMessage ; un numéro, tout ce qui compose.
        if isEmail && network != .iMessage { continue }
        if !isEmail && PhoneNormalizer.e164(handle) == nil { continue }
        people[index].reaches.append(Reach(network: network, conversationID: nil, handle: handle))
      }
    }

    // Les fils existants d'abord, puis les réseaux à ouvrir — dans l'ordre de l'enum.
    for index in people.indices {
      let existing = people[index].reaches.filter(\.isExisting)
      let fresh = people[index].reaches.filter { !$0.isExisting }
        .sorted { rank($0.network) < rank($1.network) }
      people[index].reaches = existing + fresh
    }

    return people
      .filter { !$0.reaches.isEmpty }
      .sorted { lhs, rhs in
        switch (lhs.lastMessageAt, rhs.lastMessageAt) {
        case let (l?, r?): return l > r
        case (.some, .none): return true
        case (.none, .some): return false
        case (.none, .none):
          return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
      }
  }

  /// Ne garde que les personnes joignables sur ce réseau, et n'en montre que
  /// cette façon de les joindre. `nil` : tout le monde, tous les réseaux.
  static func filter(_ people: [ReachablePerson], network: MessageNetwork?) -> [ReachablePerson] {
    guard let network else { return people }
    return people.compactMap { person in
      let reaches = person.reaches.filter { $0.network == network }
      guard !reaches.isEmpty else { return nil }
      var copy = person
      copy.reaches = reaches
      // Connue du Relais sur un autre réseau seulement : ici, c'est un fil à ouvrir.
      if !reaches.contains(where: \.isExisting) { copy.lastMessageAt = nil }
      return copy
    }
  }

  /// Ce que tape l'utilisateur, contre le nom et les identifiants.
  static func matches(_ person: ReachablePerson, query: String) -> Bool {
    let needle = fold(query)
    guard !needle.isEmpty else { return true }
    if fold(person.name).contains(needle) { return true }
    if fold(person.detail).contains(needle) { return true }
    let digits = needle.filter(\.isNumber)
    return person.reaches.contains { reach in
      fold(reach.handle).contains(needle)
        || (!digits.isEmpty && digits.count >= 4 && reach.handle.filter(\.isNumber).contains(digits))
    }
  }

  // MARK: - Détails

  /// Un réseau qui n'identifie pas par numéro (Instagram, Messenger) ne se
  /// rapproche de rien : son identifiant numérique n'est pas un téléphone.
  private static func identifiesByPhone(_ network: MessageNetwork) -> Bool {
    network.bridge?.identifiersArePhoneNumbers ?? true
  }

  private static func identityKeys(_ conversation: Conversation) -> [String] {
    guard identifiesByPhone(conversation.network) else { return [] }
    return ([conversation.address] + conversation.participantHandles)
      .compactMap(PhoneNormalizer.identityKey)
  }

  /// L'adresse telle qu'on la montre : un numéro ou un e-mail, pas un identifiant de salon.
  private static func displayHandle(of conversation: Conversation) -> String {
    guard identifiesByPhone(conversation.network) else { return "" }
    let address = conversation.address
    if let e164 = PhoneNormalizer.e164(address) { return e164 }
    if address.contains("@"), !address.hasPrefix("@") { return address }
    if let key = PhoneNormalizer.identityKey(for: address) {
      if key.hasPrefix("tel:") { return "+" + key.dropFirst(4) }
      if key.hasPrefix("email:") { return String(key.dropFirst(6)) }
    }
    return ""
  }

  private static func bookAvatar(name: String, handle: String) -> Conversation {
    Conversation(
      id: "book:" + handle,
      network: .iMessage,
      address: handle,
      title: name,
      preview: "",
      lastMessageAt: .distantPast,
      unreadCount: 0,
      isArchived: false,
      transportKey: handle,
      isGroup: false
    )
  }

  private static func rank(_ network: MessageNetwork) -> Int {
    MessageNetwork.allCases.firstIndex(of: network) ?? .max
  }

  private static func fold(_ value: String) -> String {
    value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
  }
}
