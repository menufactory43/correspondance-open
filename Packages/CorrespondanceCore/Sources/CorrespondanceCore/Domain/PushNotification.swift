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

  /// Ce qu'on montre : « Alice · WhatsApp » en titre, le message en dessous.
  ///
  /// Le réseau est dans le titre et pas ailleurs : sur l'écran verrouillé, deux
  /// notifications de la même personne sur deux réseaux différents seraient
  /// autrement impossibles à distinguer.
  public struct Presentation: Sendable, Hashable {
    public var title: String
    public var body: String

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
    return Presentation(
      title: title.isEmpty ? fallbackTitle : title,
      body: body.isEmpty ? fallbackBody : body
    )
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
