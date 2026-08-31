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

  /// L'URL de Sygnal **vue de Synapse** : un nom de service Docker, sur le
  /// réseau `matrix` du NUC. L'iPhone ne la résout pas et n'a pas à le faire —
  /// c'est le Relais qui appelle Sygnal, jamais nous.
  static let sygnalURL = URL(string: "http://sygnal:5000/_matrix/push/v1/notify")!
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
        deviceDisplayName: UIDevice.current.name
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
    try? await store.matrix.removePusher(pushkey: key)
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
