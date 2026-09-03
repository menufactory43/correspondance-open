import Foundation

/// Une personne, plusieurs réseaux, une seule ligne.
///
/// Quand quelqu'un nous écrit sur iMessage et sur WhatsApp avec le même numéro,
/// l'inbox n'a aucune raison de montrer deux fils. Un `MergedContact` déclare
/// que ces conversations sont la même personne ; `apply(to:merged:)` remplace
/// alors les membres par une conversation **virtuelle** que le reste de l'app
/// manipule comme n'importe quelle autre.
///
/// Rien n'est envoyé nulle part pour établir ça : la détection est une passe
/// locale sur le catalogue déjà chargé (cf. `MergeCandidates`).
public struct MergedContact: Identifiable, Codable, Hashable, Sendable {
  /// Préfixe des identifiants virtuels — le reste de l'app reconnaît une ligne
  /// fusionnée à ça, sans avoir à consulter le store.
  public static let idPrefix = "merged:"

  public let id: String
  /// Nom affiché, choisi à la fusion (modifiable dans la feuille).
  public var title: String
  /// Identifiants des `Conversation` réunies, réseau par réseau.
  public var memberIDs: [String]
  /// Membre dont on emprunte l'avatar. `nil` = celui du chat par défaut.
  public var avatarConversationID: String?
  /// Réseau d'envoi quand rien n'a encore été choisi dans le fil.
  public var defaultConversationID: String
  /// Dernier réseau réellement utilisé pour écrire — il prime sur le défaut.
  public var lastUsedConversationID: String?

  public init(
    id: String = MergedContact.idPrefix + UUID().uuidString,
    title: String,
    memberIDs: [String],
    avatarConversationID: String? = nil,
    defaultConversationID: String,
    lastUsedConversationID: String? = nil
  ) {
    self.id = id
    self.title = title
    self.memberIDs = memberIDs
    self.avatarConversationID = avatarConversationID
    self.defaultConversationID = defaultConversationID
    self.lastUsedConversationID = lastUsedConversationID
  }

  /// Un identifiant désigne-t-il une ligne fusionnée ?
  public static func isMergedID(_ id: String) -> Bool { id.hasPrefix(idPrefix) }

  /// Cette ligne, agrandie d'autres fils. Un tête-à-tête entre tel quel ; une
  /// autre ligne fusionnée apporte ses membres, et disparaît (`absorbed`).
  /// Le nom, le visage et le chat par défaut restent ceux d'ici : c'est à
  /// cette ligne qu'on a demandé d'accueillir, pas l'inverse.
  public func absorbing(
    _ conversationIDs: [String],
    contacts: [MergedContact]
  ) -> (contact: MergedContact, absorbed: [MergedContact]) {
    var copy = self
    var absorbed: [MergedContact] = []
    for id in conversationIDs where id != self.id {
      if let other = contacts.first(where: { $0.id == id }) {
        absorbed.append(other)
        for member in other.memberIDs where !copy.memberIDs.contains(member) {
          copy.memberIDs.append(member)
        }
      } else if !copy.memberIDs.contains(id) {
        copy.memberIDs.append(id)
      }
    }
    return (copy, absorbed)
  }

  /// Le membre où écrire : le dernier utilisé s'il est toujours là, le défaut sinon.
  public func activeMemberID(among present: Set<String>) -> String? {
    if let last = lastUsedConversationID, present.contains(last) { return last }
    if present.contains(defaultConversationID) { return defaultConversationID }
    return memberIDs.first(where: present.contains)
  }

  /// La ligne virtuelle telle que l'inbox la montre. `nil` s'il ne reste pas
  /// de quoi fusionner (moins de deux membres réellement présents).
  public func row(from members: [Conversation]) -> Conversation? {
    guard members.count >= 2 else { return nil }
    // Le réseau, l'aperçu et l'accusé viennent du membre qui a parlé en dernier :
    // c'est lui que la ligne résume.
    guard let newest = members.max(by: { $0.lastMessageAt < $1.lastMessageAt }) else { return nil }
    // L'adresse et la clé de transport viennent du chat par défaut : c'est là
    // qu'on écrira si le fil ne dit rien d'autre.
    let base = members.first { $0.id == defaultConversationID } ?? newest

    return Conversation(
      id: id,
      network: newest.network,
      address: base.address,
      title: title,
      preview: newest.preview,
      lastMessageAt: newest.lastMessageAt,
      unreadCount: members.reduce(0) { $0 + $1.unreadCount },
      // Une ligne fusionnée ne quitte l'inbox que si tous ses fils sont rangés.
      isArchived: members.allSatisfy(\.isArchived),
      transportKey: base.transportKey,
      isGroup: false,
      lastDelivery: newest.lastDelivery,
      lastMessageIsFromMe: newest.lastMessageIsFromMe,
      // Les adresses des fils réunis entrent dans les participants : c'est par
      // là que la recherche retrouve la ligne quand on tape le numéro WhatsApp
      // d'un contact dont la ligne, elle, porte l'adresse iMessage.
      participantHandles: members.flatMap { [$0.address] + $0.participantHandles },
      // La photo : celle du chat par défaut, sinon la première qu'un membre
      // porte. Une ligne sans photo perdait celle de la personne dans l'inbox,
      // la notification et la rangée de partage, alors que Julie a la même
      // tête sur Signal et sur WhatsApp.
      groupPhotoPath: ([base] + members).first { $0.groupPhotoPath != nil }?.groupPhotoPath,
      remoteAvatarID: ([base] + members).first { $0.remoteAvatarID != nil }?.remoteAvatarID
    )
  }

  /// Remplace les membres par leur ligne virtuelle. Fonction pure : c'est elle
  /// qu'on rejoue après chaque fusion de catalogue, comme `ArchiveState.normalized`,
  /// pour qu'un rafraîchissement réseau ne rouvre jamais deux lignes.
  public static func apply(to conversations: [Conversation], merged: [MergedContact]) -> [Conversation] {
    guard !merged.isEmpty else { return conversations }
    var list = conversations

    for contact in merged {
      let memberIDs = Set(contact.memberIDs)
      let found = list.indices.filter { memberIDs.contains(list[$0].id) }
      // Aucun membre à replier : la ligne virtuelle déjà posée reste telle quelle.
      // C'est ce qui rend la passe rejouable après chaque fusion de catalogue.
      guard found.count >= 2, let row = contact.row(from: found.map { list[$0] }) else { continue }

      // Une ligne virtuelle déjà posée est recalculée, jamais dupliquée.
      list.removeAll { $0.id == contact.id }
      let indices = list.indices.filter { memberIDs.contains(list[$0].id) }
      // La virtuelle prend la place du premier membre ; les autres s'effacent.
      list[indices[0]] = row
      for index in indices.dropFirst().reversed() { list.remove(at: index) }
    }
    return list
  }
}

/// Ce qui *pourrait* être fusionné — la proposition discrète sous la pilule.
public enum MergeCandidates {
  /// Regroupe les tête-à-tête de réseaux différents dont l'adresse se ramène au
  /// même numéro (ou à la même adresse e-mail).
  ///
  /// - Parameter dismissedPairs: paires déjà écartées (`pairKey`), qui ne
  ///   reviennent plus proposer la même fusion à chaque lancement.
  public static func detect(in conversations: [Conversation], dismissedPairs: Set<String>) -> [[Conversation]] {
    let candidates = conversations.filter { !$0.isGroup && !MergedContact.isMergedID($0.id) }

    // Deux façons de se reconnaître : le même numéro (ou e-mail), ou le même
    // nom, mot pour mot. Le nom seul est faible — mais la fusion n'est jamais
    // automatique, et c'est la seule prise qu'on ait sur un Signal qui cache
    // son numéro ou un Messenger, qui n'en a pas. Un fil peut porter les deux
    // clés : les groupes qu'elles forment se réunissent (union-find).
    var parent: [Int] = Array(candidates.indices)
    func root(_ i: Int) -> Int {
      var i = i
      while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
      return i
    }
    var firstByKey: [String: Int] = [:]
    for (index, conversation) in candidates.enumerated() {
      var keys: [String] = []
      if let identity = PhoneNormalizer.identityKey(for: conversation.address) { keys.append(identity) }
      if let name = nameKey(conversation) { keys.append(name) }
      for key in keys {
        if let first = firstByKey[key] {
          parent[root(index)] = root(first)
        } else {
          firstByKey[key] = index
        }
      }
    }
    var buckets: [String: [Conversation]] = [:]
    for (index, conversation) in candidates.enumerated() {
      buckets[candidates[root(index)].id, default: []].append(conversation)
    }

    var groups: [[Conversation]] = []
    for key in buckets.keys.sorted() {
      guard let bucket = buckets[key] else { continue }
      // Un réseau ne se fusionne pas avec lui-même : on ne garde qu'un fil par
      // réseau, le plus récent, et il en faut au moins deux différents.
      var byNetwork: [MessageNetwork: Conversation] = [:]
      for conversation in bucket.sorted(by: { $0.lastMessageAt > $1.lastMessageAt })
      where byNetwork[conversation.network] == nil {
        byNetwork[conversation.network] = conversation
      }
      guard byNetwork.count >= 2 else { continue }

      let members = byNetwork.values.sorted { $0.lastMessageAt > $1.lastMessageAt }
      guard !isDismissed(members.map(\.id), dismissedPairs: dismissedPairs) else { continue }
      groups.append(members)
    }
    return groups
  }

  /// Le nom, ramené à ce qui se compare : sans accents, sans casse, sans
  /// espaces superflus. `nil` si le fil n'a pas de vrai nom (un numéro, un
  /// identifiant de salon) ou un nom trop court pour dire quoi que ce soit.
  static func nameKey(_ conversation: Conversation) -> String? {
    guard !conversation.hasPlaceholderTitle else { return nil }
    let folded = conversation.title
      .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
    // Un titre qui est un numéro n'est pas un nom : c'est l'identité qui le rapproche.
    guard folded.count >= 3, PhoneNormalizer.identityKey(for: folded) == nil else { return nil }
    return "name:" + folded
  }

  /// Clé stable d'une paire (ou d'un groupe) : les identifiants triés, joints par `|`.
  public static func pairKey(_ ids: [String]) -> String {
    ids.sorted().joined(separator: "|")
  }

  /// Écartée si le groupe entier l'a été, ou si l'une de ses paires l'a été.
  public static func isDismissed(_ ids: [String], dismissedPairs: Set<String>) -> Bool {
    if dismissedPairs.contains(pairKey(ids)) { return true }
    for (index, left) in ids.enumerated() {
      for right in ids.dropFirst(index + 1) where dismissedPairs.contains(pairKey([left, right])) {
        return true
      }
    }
    return false
  }
}
