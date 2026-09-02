import CorrespondanceCore
import Foundation
import Observation
import OSLog
import UIKit
import UserNotifications

/// L'inscription au push, de bout en bout.
///
/// Le chemin, dans l'ordre : on demande l'autorisation au premier lancement
/// *connecté* (pas avant — un écran de connexion qui réclame les notifications
/// avant de savoir s'il y a un Relais est une impolitesse) → iOS rend un jeton
/// APNs → on le déclare au Relais (`setPusher`) → Synapse appellera Sygnal →
/// Sygnal appellera APNs.
///
/// Le jeton **tourne** : réinstallation, restauration, changement d'appareil.
/// C'est pourquoi `setPusher` part à chaque jeton reçu et non une seule fois ;
/// `append: false` fait que le nouveau remplace l'ancien plutôt que de s'y
/// ajouter. Et la déconnexion le retire (`kind: null`), sinon le Relais
/// continuerait de réveiller un téléphone qui n'a plus de session.
@MainActor
@Observable
final class PushRegistration {
  static let log = Logger(subsystem: "com.correspondance.ios", category: "push")

  /// L'URL de la passerelle push, **vue du Relais**. Ce n'est pas l'iPhone qui
  /// l'appelle : il la déclare, et c'est le Relais qui s'en sert.
  ///
  /// Elle est publique depuis le 2 sept. 2026 (décision du propriétaire). Avant,
  /// c'était `http://sygnal:5000/…` — un nom de service Docker qui ne résout que
  /// sur le réseau du NUC, donc une passerelle réservée au Relais du
  /// propriétaire. Un Relais Continuwuity posé chez quelqu'un d'autre par
  /// `infra/relais/install.sh` n'avait aucun moyen de la joindre, et son
  /// utilisateur n'avait pas de push. Une seule passerelle chez nous, pour tous
  /// les Relais : elle ne voit qu'un identifiant de salon et un compteur
  /// (`format: event_id_only`), jamais le texte d'un message.
  ///
  /// Le nom est une **valeur de configuration**, pas une constante du produit :
  /// `push.fauconnier.app` est un domaine que le propriétaire possède déjà, en
  /// attendant celui de Correspondance. `CORRESPONDANCE_PUSH_GATEWAY` le
  /// remplace sans recompiler — c'est ce qui permet d'essayer une passerelle à
  /// soi, et c'est ce que la ligne « Passerelle » des Réglages affiche.
  static let defaultGateway = "https://push.fauconnier.app/_matrix/push/v1/notify"

  static let sygnalURL: URL = {
    if let brut = ProcessInfo.processInfo.environment["CORRESPONDANCE_PUSH_GATEWAY"],
       !brut.isEmpty, let url = URL(string: brut), url.scheme != nil {
      return url
    }
    return URL(string: defaultGateway)!
  }()

  /// L'`app_id` du pusher — la clé qui choisit l'entrée d'`apps:` dans
  /// `sygnal.yaml`, donc **l'environnement APNs**. Il y en a deux, parce
  /// qu'APNs en a deux : un jeton de sandbox ne vaut rien en production et
  /// réciproquement, et l'erreur est silencieuse (`BadDeviceToken`).
  ///
  /// Le choix se fait sur `#if DEBUG` et non sur un réglage de build à part,
  /// parce que `DEBUG` est posé par la configuration **Debug** — exactement
  /// celle qu'Xcode lance sur un appareil, avec un profil de développement,
  /// donc `aps-environment: development`, donc un jeton de sandbox. Release
  /// (TestFlight, App Store) est signée à l'export `app-store-connect`, où
  /// Xcode réécrit `aps-environment` en `production`. Les deux bascules sont
  /// tirées par le même levier ; un réglage séparé pourrait dériver de la
  /// signature, `DEBUG` ne le peut pas.
  ///
  /// Le seul cas qui reste bancal est une build **Release** posée sur un
  /// appareil depuis Xcode (export `development`) : app_id de production,
  /// jeton de sandbox. Ce n'est pas un chemin qu'on emprunte.
  static let pusherAppID: String = {
    #if DEBUG
      "com.correspondance.ios.dev"
    #else
      MatrixClient.iOSPusherAppID
    #endif
  }()

  private static let lastPushkeyKey = "correspondance.ios.lastPushkey"

  private(set) var authorization: UNAuthorizationStatus = .notDetermined
  /// Le dernier jeton APNs reçu, en hexadécimal — c'est le `pushkey`.
  private(set) var pushkey: String?
  /// Ce que le Relais a accepté, s'il l'a accepté. Montré dans les Réglages.
  private(set) var lastError: String?
  private(set) var isRegistered = false

  private weak var store: RelayStore?

  func attach(to store: RelayStore) {
    self.store = store
  }

  // MARK: - Autorisation

  func refreshAuthorization() async {
    authorization = await UNUserNotificationCenter.current().notificationSettings()
      .authorizationStatus
  }

  /// Demande l'autorisation, puis inscrit l'appareil auprès d'APNs.
  ///
  /// `.provisional` n'est pas demandé : une notification livrée en silence dans
  /// le centre de notifications ne réveille personne, et c'est justement le
  /// réveil qu'on cherche.
  @discardableResult
  func requestAuthorizationIfNeeded() async -> Bool {
    await refreshAuthorization()
    switch authorization {
    case .notDetermined:
      let granted = (try? await UNUserNotificationCenter.current()
        .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
      await refreshAuthorization()
      if granted { registerWithAPNS() }
      return granted
    case .authorized, .provisional, .ephemeral:
      registerWithAPNS()
      return true
    default:
      // Refusé : on n'insiste pas. Les Réglages de l'app portent le lien vers
      // ceux du système, c'est le seul endroit où l'on peut revenir dessus.
      return false
    }
  }

  private func registerWithAPNS() {
    UIApplication.shared.registerForRemoteNotifications()
  }

  // MARK: - Le jeton

  /// Appelé par le délégué d'application à chaque jeton — donc à chaque
  /// rotation, pas seulement au premier lancement.
  func didReceive(deviceToken: Data) {
    let key = MatrixClient.pushkey(fromAPNSToken: deviceToken)
    pushkey = key
    UserDefaults.standard.set(key, forKey: Self.lastPushkeyKey)
    Task { await declareToRelay() }
  }

  func didFailToRegister(_ error: Error) {
    isRegistered = false
    lastError = "APNs n'a pas donné de jeton : \(error.localizedDescription)"
    Self.log.notice("APNs refuse l'inscription : \(error.localizedDescription, privacy: .public)")
  }

  /// Déclare le pusher au Relais. Sans jeton, ou hors session, on ne fait rien —
  /// l'inscription repartira à la prochaine occasion.
  func declareToRelay() async {
    guard let store, store.session == .connected, !store.isDemo else { return }
    guard let pushkey, !pushkey.isEmpty else { return }
    do {
      try await store.matrix.setPusher(
        pushkey: pushkey,
        sygnalURL: Self.sygnalURL,
        deviceDisplayName: UIDevice.current.name,
        appID: Self.pusherAppID
      )
      isRegistered = true
      lastError = nil
    } catch {
      isRegistered = false
      lastError = RelayStore.readable(error)
      Self.log.notice("pusher refusé : \(RelayStore.readable(error), privacy: .public)")
    }
  }

  /// Retire le pusher — à la déconnexion, avant que le jeton d'accès ne meure.
  /// L'ordre compte : après `logout`, le Relais ne nous écouterait plus.
  func removeFromRelay() async {
    guard let store, !store.isDemo else { return }
    let key = pushkey ?? UserDefaults.standard.string(forKey: Self.lastPushkeyKey)
    guard let key, !key.isEmpty else { return }
    // Le même `app_id` qu'à la déclaration : retirer un pusher, c'est nommer le
    // couple (app_id, pushkey) exact. Avec l'autre, on laisserait le vrai en place.
    try? await store.matrix.removePusher(pushkey: key, appID: Self.pusherAppID)
    isRegistered = false
  }

  // MARK: - Démonstration

  /// Rejoue, dans l'app, ce que l'extension fait dans son coin : lire
  /// l'événement que le push nomme, composer le titre et le corps, poser la
  /// notification. **La même fonction de Core** (`PushNotification.resolve`) —
  /// seul l'hôte change.
  ///
  /// Elle existe parce que le simulateur ne sait pas réveiller une extension de
  /// service : `xcrun simctl push` livre la notification telle quelle, sans
  /// jamais l'appeler. Sans ce détour, la seule chose qu'une capture pourrait
  /// montrer serait la clé de traduction brute de Sygnal.
  /// `after` diffère la remise : le temps de refermer l'app, pour que la
  /// notification s'affiche là où on la voit vraiment — sur l'écran d'accueil,
  /// pas par-dessus l'écran qui vient de la demander.
  func presentDemoNotification(
    reference: PushNotification.EventReference,
    after delay: TimeInterval = 0
  ) async {
    guard let credentials = MatrixCredentialStore.load() else { return }
    let shown = await PushNotification.resolve(
      reference,
      using: MatrixClient(credentials: credentials)
    )
    let content = UNMutableNotificationContent()
    content.title = shown.title
    content.body = shown.body
    content.threadIdentifier = reference.roomID
    content.sound = .default
    let trigger = delay > 0
      ? UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
      : nil
    try? await UNUserNotificationCenter.current().add(
      UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
    )
  }

  /// L'autorisation permet-elle un push ? (Refusée ou pas encore demandée : non.)
  var isAuthorizedForPush: Bool {
    switch authorization {
    case .authorized, .provisional, .ephemeral: true
    default: false
    }
  }

  var authorizationLabelFR: String {
    switch authorization {
    case .authorized: "Autorisées"
    case .provisional: "Silencieuses"
    case .denied: "Refusées"
    case .ephemeral: "Temporaires"
    case .notDetermined: "Pas encore demandées"
    @unknown default: "Inconnues"
    }
  }
}
