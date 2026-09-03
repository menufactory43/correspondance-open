import Foundation

/// Le push ne dit rien du message — c'est le contrat.
///
/// Avec `format: event_id_only`, Sygnal n'envoie que `room_id` et `event_id`.
/// L'appareil va chercher le reste lui-même. C'est ce qui permettra au Relais
/// de ne plus rien comprendre au contenu le jour de l'E2EE (décision 7) sans
/// que la notification y perde une ligne.
///
/// Tout ce fichier est pur : pas de `UserNotifications`, pas de réseau. C'est
/// l'extension qui appelle, les tests aussi.
public enum PushNotification {
  /// Ce qu'un push nomme : un salon, un événement.
  public struct EventReference: Sendable, Hashable {
    public var roomID: String
    public var eventID: String

    public init(roomID: String, eventID: String) {
      self.roomID = roomID
      self.eventID = eventID
    }
  }

  /// Lit la référence dans la charge utile APNs de Sygnal.
  ///
  /// Sygnal pose `room_id` et `event_id` à la racine, à côté de `aps`. Un push
  /// qui n'en porte pas (réveil de contenu, notification d'un autre pousseur)
  /// n'a rien à nous apprendre : `nil`, et le repli s'affiche.
  public static func reference(in payload: [String: Any]) -> EventReference? {
    guard let roomID = payload["room_id"] as? String, !roomID.isEmpty,
          let eventID = payload["event_id"] as? String, !eventID.isEmpty
    else { return nil }
    return EventReference(roomID: roomID, eventID: eventID)
  }

  // MARK: - Le texte affiché

  /// Ce qui s'affiche quand on n'a pas pu lire l'événement : Relais injoignable,
  /// Tailscale coupé, trente secondes écoulées. On ne ment pas, on ne devine pas.
  public static let fallbackTitle = "Correspondance"
  public static let fallbackBody = "Nouveau message"
  /// Le Relais a répondu, mais la clé manque à cet appareil. Ce n'est pas la
  /// même panne qu'un Relais injoignable, et le dire évite de chercher au
  /// mauvais endroit.
  public static let messageChiffreNonLu = "Message chiffré — ouvre Correspondance pour le lire"

  /// Ce qu'on montre : « Alice · WhatsApp » en titre, le message en dessous.
  ///
  /// Le réseau est dans le titre et pas ailleurs : sur l'écran verrouillé, deux
  /// notifications de la même personne sur deux réseaux différents seraient
  /// autrement impossibles à distinguer.
  public struct Presentation: Sendable, Hashable {
    public var title: String
    public var body: String
    /// Qui écrit, tel qu'on l'affiche — sans le réseau. C'est le nom que la
    /// notification de conversation (Intents) donne à la personne.
    public var senderName: String?
    /// Le fil, tel qu'on l'affiche — sans le réseau.
    public var conversationTitle: String?
    public var network: MessageNetwork?
    /// Un groupe : la photo est celle du groupe, et le nom de l'auteur passe en
    /// tête de la notification, comme dans WhatsApp.
    public var isGroup = false
    /// La photo à montrer à la place de l'icône de l'app : celle de l'auteur en
    /// tête-à-tête, celle du groupe sinon. Un `mxc://`, pas encore téléchargé.
    public var avatarMXC: String?
    /// Un groupe sans photo à lui — Instagram n'en donne jamais — se raconte
    /// par les visages de ses membres, en mosaïque comme sur le Mac et dans
    /// l'inbox. Jusqu'à quatre `mxc://`, dans l'ordre de l'inbox.
    public var memberAvatarMXCs: [String] = []
    /// Quelques membres du groupe, par leur nom — les « destinataires » de
    /// l'intention. C'est **là-dessus** qu'iOS décide qu'une notification est
    /// celle d'un groupe : sans destinataires, il la classe en tête-à-tête et
    /// ignore la photo du groupe (vu au journal le 3 sept. 2026 :
    /// `recipientsArrayCount: 0` → `MessagingDirect`).
    public var memberNames: [String] = []

    public init(title: String, body: String) {
      self.title = title
      self.body = body
    }

    /// La même chose sur une ligne — « {expéditeur} · {réseau} : {texte} ».
    /// Sert aux tests et à l'accessibilité.
    public var line: String { "\(title) : \(body)" }
  }

  /// Compose le titre et le corps à partir de ce qu'on a réussi à lire.
  ///
  /// - `senderName` : nom d'affichage de l'auteur. Vide ou technique → le titre
  ///   du fil prend sa place (en tête-à-tête c'est la même personne) ; à défaut
  ///   encore, le seul nom du réseau.
  /// - `text` : le corps du message, déjà nettoyé de son repli de citation. Vide
  ///   → le repli, jamais une bulle blanche.
  public static func presentation(
    senderName: String?,
    conversationTitle: String?,
    network: MessageNetwork?,
    text: String?
  ) -> Presentation {
    let who = [senderName, conversationTitle]
      .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { !$0.isEmpty }
    let networkName = network?.labelFR
    let title = [who, networkName]
      .compactMap { $0 }
      .filter { !$0.isEmpty }
      .joined(separator: " · ")
    let body = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    var shown = Presentation(
      title: title.isEmpty ? fallbackTitle : title,
      body: body.isEmpty ? fallbackBody : body
    )
    shown.senderName = who
    shown.conversationTitle = conversationTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
    shown.network = network
    return shown
  }

  // MARK: - Aller lire l'événement

  /// Ce que le push ne dit pas, et qu'il faut donc demander au Relais.
  ///
  /// Vit ici plutôt que dans l'extension pour une raison simple : l'extension
  /// est un processus qu'on ne peut ni lancer à la main, ni instrumenter —
  /// `xcrun simctl push` ne la réveille même pas. Mise dans Core, la même
  /// fonction se laisse exercer depuis l'app et depuis les tests.
  ///
  /// Quatre lectures au plus, l'une après l'autre : l'événement, l'auteur, le
  /// nom du salon, le réseau. Elles pourraient partir ensemble ; elles ne le
  /// font pas, parce que trente secondes suffisent largement et qu'un `/state`
  /// en parallèle ne gagne rien face à la latence d'un tailnet.
  public static func resolve(
    _ reference: EventReference,
    using client: MatrixClient
  ) async -> Presentation {
    guard let brut = try? await client.roomEvent(
      roomID: reference.roomID,
      eventID: reference.eventID
    ) else {
      return presentation(senderName: nil, conversationTitle: nil, network: nil, text: nil)
    }

    // Le push ne porte qu'un identifiant ; ce que le Relais rend peut être un
    // `m.room.encrypted`. On le déchiffre ici, avec le magasin de clés partagé
    // par le conteneur d'App Group — c'est le seul endroit où l'extension et
    // l'app se rejoignent.
    let event: MatrixJSON
    var text: String
    if brut.string(at: "type") == "m.room.encrypted",
       let clair = await client.dechiffrerEvenement(brut, salon: reference.roomID) {
      event = clair
      text = event.string(at: "content.body") ?? ""
    } else if brut.string(at: "type") == "m.room.encrypted" {
      // **On le dit.** Un « Nouveau message » générique laisserait croire à
      // un Relais injoignable ; ici le Relais a répondu, c'est la clé qui
      // manque, et la seule chose à faire est d'ouvrir l'app.
      event = brut
      text = messageChiffreNonLu
    } else {
      event = brut
      text = event.string(at: "content.body") ?? ""
    }
    if event.string(at: "content.m.relates_to.m.in_reply_to.event_id") != nil {
      text = QuotedMessage.strippingReplyFallback(text)
    }

    let sender = event.string(at: "sender")
    let room = await RoomFacts.load(roomID: reference.roomID, sender: sender, client: client)

    var shown = presentation(
      senderName: room.senderName,
      conversationTitle: room.name,
      network: room.network,
      text: text
    )
    shown.isGroup = room.isGroup
    // En tête-à-tête, la photo de la personne ; en groupe, celle du groupe.
    // Un groupe sans photo montre ses membres en mosaïque, à défaut l'auteur.
    if room.isGroup {
      shown.avatarMXC = room.avatarMXC
      shown.memberAvatarMXCs = room.avatarMXC == nil ? room.memberAvatarMXCs : []
      shown.memberNames = room.memberNames
      if shown.avatarMXC == nil, shown.memberAvatarMXCs.count < 2 {
        shown.avatarMXC = room.senderAvatarMXC
      }
    } else {
      shown.avatarMXC = room.senderAvatarMXC ?? room.avatarMXC
    }
    return shown
  }

  /// Ce que l'état du salon dit, lu en **une** requête (`GET /state`) : le
  /// nom, la photo, le réseau, les membres. Avant, c'était cinq lectures
  /// ciblées, et la question « est-ce un groupe ? » n'avait pas de réponse
  /// sans les membres. La règle du groupe est celle de l'inbox
  /// (`MatrixRoomModel.isGroup`) : le type annoncé par le pont quand il y en a
  /// un — mautrix ne marque que les DM, un groupe Signal de trois cents
  /// personnes n'a aucun type, vérifié le 3 sept. 2026 —, sinon plus de deux
  /// humains dans le salon, bot du pont exclu.
  struct RoomFacts {
    var name: String?
    var avatarMXC: String?
    var network: MessageNetwork?
    var isGroup = false
    var senderName: String?
    var senderAvatarMXC: String?
    var memberAvatarMXCs: [String] = []
    var memberNames: [String] = []

    static func load(roomID: String, sender: String?, client: MatrixClient) async -> RoomFacts {
      guard let events = try? await client.roomStateEvents(roomID: roomID) else {
        return await fallback(roomID: roomID, sender: sender, client: client)
      }
      var facts = RoomFacts()
      var roomType: String?
      var humans: [(userID: String, name: String, avatar: String?)] = []
      for event in events {
        let content = event.content
        switch event.type {
        case "m.room.name":
          if let raw = content?.string(at: "name"), !raw.isEmpty {
            facts.name = MatrixIdentity.stripBridgeSuffix(raw)
          }
        case "m.room.avatar":
          facts.avatarMXC = mxc(content?.string(at: "url"))
        case "m.room.member":
          guard content?.string(at: "membership") == "join",
                let userID = event.stateKey, !MatrixIdentity.isBridgeBot(userID)
          else { continue }
          let name = content?.string(at: "displayname").map(MatrixIdentity.stripBridgeSuffix) ?? ""
          let avatar = mxc(content?.string(at: "avatar_url"))
          humans.append((userID, name, avatar))
          if userID == sender {
            facts.senderName = name.isEmpty ? nil : name
            facts.senderAvatarMXC = avatar
          }
        case let type where MatrixSyncParser.bridgeStateTypes.contains(type):
          if let id = content?.string(at: "protocol.id") {
            facts.network = MessageNetwork.fromBridgeProtocol(id)
          }
          roomType = content?.string(at: "com.beeper.room_type.v2") ?? content?.string(at: "com.beeper.room_type")
        default:
          continue
        }
      }
      switch roomType {
      case "dm": facts.isGroup = false
      case "group", "space": facts.isGroup = true
      default: facts.isGroup = humans.count > 2
      }
      // Trois noms suffisent à dire « groupe » ; l'auteur n'y figure pas, il
      // est déjà l'expéditeur.
      facts.memberNames = humans
        .filter { $0.userID != sender && !$0.name.isEmpty }
        .map(\.name)
        .sorted()
        .prefix(3)
        .map { $0 }
      // Les mêmes visages, dans le même ordre que l'inbox (`memberAvatarMXCs`).
      facts.memberAvatarMXCs = humans
        .compactMap { entry -> (name: String, userID: String, mxc: String)? in
          guard let mxc = entry.avatar else { return nil }
          return (entry.name, entry.userID, mxc)
        }
        .sorted { ($0.name, $0.userID) < ($1.name, $1.userID) }
        .prefix(4)
        .map(\.mxc)
      return facts
    }

    /// Le Relais n'a pas rendu l'état complet : on lit au moins le nom de
    /// l'auteur, celui du salon et le réseau, comme avant.
    private static func fallback(roomID: String, sender: String?, client: MatrixClient) async -> RoomFacts {
      var facts = RoomFacts()
      if let sender,
         let member = try? await client.roomState(roomID: roomID, type: "m.room.member", stateKey: sender) {
        if let raw = member.string(at: "displayname"), !raw.isEmpty {
          facts.senderName = MatrixIdentity.stripBridgeSuffix(raw)
        }
        facts.senderAvatarMXC = mxc(member.string(at: "avatar_url"))
      }
      if let name = try? await client.roomState(roomID: roomID, type: "m.room.name"),
         let raw = name.string(at: "name"), !raw.isEmpty {
        facts.name = MatrixIdentity.stripBridgeSuffix(raw)
      }
      for type in MatrixSyncParser.bridgeStateTypes {
        guard let state = try? await client.roomState(roomID: roomID, type: type),
              let id = state.string(at: "protocol.id"),
              let network = MessageNetwork.fromBridgeProtocol(id)
        else { continue }
        facts.network = network
        break
      }
      return facts
    }

    private static func mxc(_ value: String?) -> String? {
      guard let value, value.hasPrefix("mxc://") else { return nil }
      return value
    }
  }

  // MARK: - Le muet, deux fois plutôt qu'une

  /// Le muet est appliqué par le Relais : un salon muet porte une push rule
  /// `actions: []`, et Synapse n'appelle même pas Sygnal. Cette fonction est la
  /// **seconde** garde, côté appareil.
  ///
  /// Elle n'est pas de la ceinture et des bretelles. Une push rule écrite il y a
  /// dix secondes met un instant à s'appliquer ; une notification déjà partie ne
  /// se rattrape pas ; et un salon mis en muet depuis le Mac pendant que
  /// l'iPhone dort arrive ici avant le `/sync` qui l'apprendrait. Dans ces
  /// trois cas, la notification est déjà sur l'appareil — c'est le dernier
  /// endroit où l'on peut encore la taire.
  public static func shouldPresent(roomID: String, mutedRoomIDs: Set<String>) -> Bool {
    !mutedRoomIDs.contains(roomID)
  }
}

/// Ce que l'app laisse à son extension, dans le conteneur du groupe d'app.
///
/// L'extension ne tient pas de `/sync` : elle vit trente secondes et n'a pas de
/// modèle. Elle a pourtant besoin de savoir quels salons sont muets. L'app
/// dépose donc cet extrait de `ConversationStateSnapshot` après chaque sync ;
/// l'extension le relit. Rien d'autre ne transite : ni message, ni brouillon.
public enum SharedRelayState {
  public static let appGroup = "group.com.correspondance"

  /// Le groupe d'accès du Trousseau partagé, préfixé du Team ID — c'est le
  /// format qu'exige `kSecAttrAccessGroup`, et `$(AppIdentifierPrefix)` des
  /// entitlements n'est développé qu'à la signature, pas à l'exécution.
  /// Le même littéral que `DEVELOPMENT_TEAM` dans project.yml.
  public static let keychainAccessGroup = "AKMNXGVVGX.com.correspondance.shared"
  private static let mutedKey = "correspondance.shared.mutedRoomIDs"

  public static func defaults(suiteName: String = appGroup) -> UserDefaults? {
    UserDefaults(suiteName: suiteName)
  }

  public static func saveMutedRoomIDs(_ ids: Set<String>, suiteName: String = appGroup) {
    defaults(suiteName: suiteName)?.set(Array(ids).sorted(), forKey: mutedKey)
  }

  public static func mutedRoomIDs(suiteName: String = appGroup) -> Set<String> {
    let stored = defaults(suiteName: suiteName)?.stringArray(forKey: mutedKey) ?? []
    return Set(stored)
  }

  /// L'extrait qu'on partage, tiré de l'instantané complet.
  public static func mutedRoomIDs(in snapshot: ConversationStateSnapshot) -> Set<String> {
    snapshot.muted
  }
}
