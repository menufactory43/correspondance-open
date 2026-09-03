import CorrespondanceCore
import OSLog
import UserNotifications

/// L'extension qui donne un visage aux notifications.
///
/// Le push ne porte que `room_id` et `event_id` (`format: event_id_only`) :
/// c'est voulu, le Relais n'a rien à raconter d'un message, il ne fait que
/// réveiller (décision 7 de PRODUCT.md, celle qui survivra à l'E2EE). Le texte,
/// c'est ici qu'on va le chercher — `GET /rooms/{r}/event/{e}`, avec la session
/// que l'app a laissée dans le Trousseau partagé.
///
/// Trois choses gouvernent ce code, et une seule les résume : **trente
/// secondes**. Passé ce délai, le système appelle `serviceExtensionTimeWillExpire`
/// et affiche ce qu'on lui a laissé. Donc : aucun `/sync`, aucun cache à tenir,
/// aucune reprise. Un seul appel, un repli honnête (« Nouveau message ») si le
/// Relais ne répond pas — Tailscale coupé, par exemple, ce qui arrive.
///
/// `@unchecked Sendable` : le système crée une instance PAR notification,
/// l'appelle une fois et attend une seule réponse. Rien d'autre ne touche cet
/// objet — mais ni `UNMutableNotificationContent` ni le gestionnaire ne sont
/// `Sendable`, et Swift 6 refuse sinon de les laisser franchir un `await`.
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
  private var handler: ((UNNotificationContent) -> Void)?
  private var content: UNMutableNotificationContent?

  override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    handler = contentHandler
    let mutable = request.content.mutableCopy() as? UNMutableNotificationContent
    content = mutable
    guard let mutable else { return contentHandler(request.content) }

    // Le repli, posé tout de suite : quoi qu'il arrive ensuite — panne, délai,
    // extension tuée — c'est cela qui s'affichera, jamais la clé de traduction
    // brute que Sygnal a mise dans `aps.alert`.
    mutable.title = PushNotification.fallbackTitle
    mutable.body = PushNotification.fallbackBody

    let payload = request.content.userInfo as? [String: Any] ?? [:]
    guard let reference = PushNotification.reference(in: payload) else {
      return contentHandler(mutable)
    }

    // Seconde garde du muet. La première est côté Relais (push rule vide), mais
    // une règle écrite à l'instant, ou depuis le Mac pendant que l'iPhone dort,
    // laisse passer un dernier push. C'est le dernier endroit où le taire.
    guard PushNotification.shouldPresent(
      roomID: reference.roomID,
      mutedRoomIDs: SharedRelayState.mutedRoomIDs()
    ) else {
      // On ne peut pas la taire : sans l'entitlement de filtrage
      // (`com.apple.developer.usernotifications.filtering`, accordé par Apple
      // sur demande), un contenu vide fait afficher le repli du push tel quel,
      // avec son son — vérifié le 3 sept. 2026. Alors on la rend discrète :
      // pas de son, niveau passif, l'écran ne s'allume pas, et le repli
      // générique plutôt que le texte d'un salon qu'on a voulu faire taire.
      mutable.sound = nil
      mutable.interruptionLevel = .passive
      return contentHandler(mutable)
    }

    MatrixCredentialStore.accessGroup = SharedRelayState.keychainAccessGroup
    guard let credentials = MatrixCredentialStore.load() else {
      return contentHandler(mutable)
    }

    Task { [self, reference, credentials] in
      let (shown, avatar) = await Self.presentation(for: reference, credentials: credentials)
      finish(with: shown, avatar: avatar, threadIdentifier: reference.roomID)
    }
  }

  /// Le passage du résultat au système, une fois et une seule.
  private func finish(
    with shown: PushNotification.Presentation,
    avatar: Data?,
    threadIdentifier: String
  ) {
    guard let handler, let content else { return }
    content.title = shown.title
    content.body = shown.body
    // Le fil d'où vient le message : deux notifications d'Alice se rangent
    // ensemble, comme dans Messages.
    content.threadIdentifier = threadIdentifier
    self.handler = nil
    // La photo de la personne à la place de l'icône de l'app, quand on sait
    // qui écrit. Le repli (« Correspondance · Nouveau message ») reste une
    // notification ordinaire : aucune personne à montrer.
    guard let sender = shown.senderName, !sender.isEmpty else { return handler(content) }
    let identity = CommunicationNotification.Identity(
      conversationID: threadIdentifier,
      senderName: sender,
      conversationTitle: shown.conversationTitle,
      network: shown.network,
      isGroup: shown.isGroup,
      avatar: avatar,
      memberNames: shown.memberNames
    )
    handler(CommunicationNotification.content(content, body: shown.body, identity: identity))
  }

  /// Trente secondes écoulées : on rend ce qu'on a. Le repli est déjà en place.
  override func serviceExtensionTimeWillExpire() {
    guard let handler, let content else { return }
    handler(content)
  }

  // MARK: - Lire l'événement

  /// Tout est dans Core (`PushNotification.resolve`) : l'extension n'est qu'un
  /// hôte. C'est ce qui permet d'exercer cette logique ailleurs — le simulateur
  /// ne sait pas réveiller une extension de service (`xcrun simctl push` la
  /// laisse dormir), et un code qu'on ne peut pas lancer est un code qu'on ne
  /// peut pas croire.
  private static func presentation(
    for reference: PushNotification.EventReference,
    credentials: MatrixCredentials
  ) async -> (PushNotification.Presentation, avatar: Data?) {
    let client = MatrixClient(credentials: credentials)
    // **La machine crypto, sur le magasin partagé.** L'extension est un autre
    // processus : elle n'a ni `/sync` ni modèle, et le magasin de clés de l'app
    // ne lui est visible que par le conteneur d'App Group
    // (`CorrespondanceHome.sharedDirectory`). Sans le groupe, ce branchement
    // échoue proprement et le déchiffrement rendra le repli « message
    // chiffré » — ce qui est la vérité, pas un silence.
    //
    // Le magasin est un SQLite ouvert par deux processus. Le WAL de SQLite le
    // supporte (verrous de fichier), mais deux écritures concurrentes se
    // bloquent : l'extension ne fait que **lire** des clés, jamais d'envoi,
    // c'est ce qui rend la cohabitation tenable.
    await MatrixChiffrement.brancher(sur: client)
    let shown = await PushNotification.resolve(reference, using: client)
    // La photo, dans le cache partagé de l'app si elle l'a déjà vue, sinon un
    // téléchargement de plus — le dernier, et le seul dont on peut se passer.
    var avatar: Data?
    if let mxc = shown.avatarMXC {
      avatar = await avatarData(mxc, client: client)
    } else if shown.memberAvatarMXCs.count >= 2 {
      // Un groupe sans photo : la mosaïque de ses membres, la même que
      // l'inbox (`ConversationAvatar`) — Instagram n'expose jamais de photo
      // de groupe, ce serait sinon l'icône de l'app à chaque fois.
      var faces: [PlatformImage] = []
      for mxc in shown.memberAvatarMXCs {
        guard let data = await avatarData(mxc, client: client),
              let face = PlatformImage(data: data)
        else { continue }
        faces.append(face)
      }
      if faces.count >= 2 {
        avatar = AvatarMosaic.compose(faces, size: 138, separator: .platformWindowBackground)
      }
    }
    log.notice(
      "notification : groupe=\(shown.isGroup) réseau=\(shown.network?.rawValue ?? "-", privacy: .public) photo=\(avatar?.count ?? 0) octets visages=\(shown.memberAvatarMXCs.count) auteur=\(shown.senderName != nil)"
    )
    return (shown, avatar)
  }

  private static let log = Logger(subsystem: "com.correspondance.ios", category: "notification")

  private static func avatarData(_ mxc: String, client: MatrixClient) async -> Data? {
    if let cached = MatrixAvatarStore.existingData(forMXC: mxc) { return cached }
    guard let data = try? await client.downloadMedia(mxcURI: mxc), !data.isEmpty else { return nil }
    MatrixAvatarStore.store(data: data, forMXC: mxc)
    return data
  }
}
