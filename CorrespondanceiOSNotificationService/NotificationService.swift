import CorrespondanceCore
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
      // Un contenu vide : le système n'affiche rien. Il n'y a pas d'autre façon
      // d'annuler une notification déjà arrivée.
      return contentHandler(UNNotificationContent())
    }

    MatrixCredentialStore.accessGroup = SharedRelayState.keychainAccessGroup
    guard let credentials = MatrixCredentialStore.load() else {
      return contentHandler(mutable)
    }

    Task { [self, reference, credentials] in
      let shown = await Self.presentation(for: reference, credentials: credentials)
      finish(with: shown, threadIdentifier: reference.roomID)
    }
  }

  /// Le passage du résultat au système, une fois et une seule.
  private func finish(with shown: PushNotification.Presentation, threadIdentifier: String) {
    guard let handler, let content else { return }
    content.title = shown.title
    content.body = shown.body
    // Le fil d'où vient le message : deux notifications d'Alice se rangent
    // ensemble, comme dans Messages.
    content.threadIdentifier = threadIdentifier
    self.handler = nil
    handler(content)
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
  ) async -> PushNotification.Presentation {
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
    return await PushNotification.resolve(reference, using: client)
  }
}
