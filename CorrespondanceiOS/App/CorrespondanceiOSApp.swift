import CorrespondanceCore
import CorrespondanceUI
import SwiftUI
import UserNotifications

@main
struct CorrespondanceiOSApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @State private var store = RelayStore(demo: DemoRelay.isRequested)
  @State private var themes = ThemePreferences()
  @State private var push = PushRegistration()
  @Environment(\.scenePhase) private var scenePhase

  init() {
    // Avant tout appel Matrix : la session s'écrit dans le Trousseau PARTAGÉ,
    // sinon l'extension de notification ne saurait pas la lire.
    MatrixCredentialStore.accessGroup = SharedRelayState.keychainAccessGroup
  }

  var body: some Scene {
    WindowGroup {
      RootView()
        .environment(store)
        .environment(themes)
        .environment(push)
        // Le chrome du système suit le thème : un thème sombre sur une barre
        // d'état claire, c'est la moitié de l'écran qui jure.
        .preferredColorScheme(themes.theme.isDark ? .dark : .light)
        .tint(themes.theme.accent)
        .task {
          push.attach(to: store)
          AppDelegate.push = push
          AppDelegate.store = store
        }
        .task {
          await store.start()
          // L'autorisation se demande une fois CONNECTÉ, jamais devant l'écran
          // de connexion : réclamer les notifications avant de savoir s'il y a
          // un Relais, c'est demander avant d'avoir quoi que ce soit à dire.
          if store.session == .connected, !store.isDemo {
            await push.requestAuthorizationIfNeeded()
          }
        }
        // Ce que l'extension de partage n'a pas pu envoyer elle-même (Relais
        // muet, salon chiffré) part au réveil de l'app — et une extension
        // iPhone ne peut pas nous réveiller, c'est donc ici que ça se joue.
        .onChange(of: scenePhase) { _, phase in
          // En arrière-plan, le push prend le relais des notifications locales ;
          // le rattrapage du retour ne doit pas les rejouer.
          if phase == .background {
            store.notificationsWillResumeFromBackground()
            // La boucle `/sync` s'arrête : un long-poll laissé en vol échoue au
            // retour et affiche « Relais injoignable » pour rien.
            store.pauseSync()
          }
          guard phase == .active else { return }
          // Et repart tout de suite au retour, sans attendre le souffle d'attente.
          store.resumeSync()
          Task { await store.viderLaBoiteDuPartage() }
        }
        .onChange(of: store.session) { _, session in
          guard session == .connected else { return }
          Task { await store.viderLaBoiteDuPartage() }
        }
        .onOpenURL { url in
          guard url.scheme == Partage.schemaURL else { return }
          Task { await store.viderLaBoiteDuPartage() }
        }
        .onChange(of: store.session) { _, session in
          guard session == .connected, !store.isDemo else { return }
          Task { await push.requestAuthorizationIfNeeded() }
        }
        // « Envoyer plus tard » ne part que si l'app est là (voir
        // `RelayStore+Scheduled`). Une passe au lancement, puis une par
        // minute : la minute est la précision qu'on promet, pas la seconde.
        .task {
          while !Task.isCancelled {
            await store.flushDueScheduledMessages()
            try? await Task.sleep(for: .seconds(60))
          }
        }
    }
  }
}

/// Le seul rôle du délégué : APNs ne parle qu'à lui.
///
/// `didRegisterForRemoteNotificationsWithDeviceToken` n'a pas d'équivalent
/// SwiftUI, et le jeton **tourne** — réinstallation, restauration, nouvel
/// appareil. On le repasse donc à `PushRegistration` chaque fois, qui redéclare
/// le pusher au Relais.
final class AppDelegate: NSObject, UIApplicationDelegate {
  /// Posée au lancement de la scène. Le délégué naît avant elle : sans ce
  /// détour, le premier jeton arriverait à personne.
  @MainActor static var push: PushRegistration?
  @MainActor static var store: RelayStore?
  /// Le destinataire des notifications touchées. Un objet à part : le délégué
  /// d'application naît avant la scène, et `UNUserNotificationCenterDelegate`
  /// n'est pas isolé au processus principal.
  static let notificationHandler = NotificationHandler()

  /// Le délégué de notifications se pose AVANT la fin du lancement : une
  /// notification touchée alors que l'app est morte n'est remise qu'à ce
  /// prix. Posé plus tard, dans la scène, le système ne la livrait jamais —
  /// l'app s'ouvrait sur rien.
  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = Self.notificationHandler
    return true
  }

  func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    Task { @MainActor in Self.push?.didReceive(deviceToken: deviceToken) }
  }

  func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    Task { @MainActor in Self.push?.didFailToRegister(error) }
  }
}

/// Ce qu'on fait d'une notification : la montrer même au premier plan (sauf
/// sur le fil qu'on lit — la politique l'a déjà écartée), et ouvrir le fil
/// qu'elle désigne quand on la touche.
///
/// Le push distant et la notification locale portent la même clé : l'un vient
/// de l'extension (`room_id`), l'autre du magasin (`conversationID`). On lit
/// les deux, faute de quoi la moitié des notifications n'ouvriraient rien.
///
/// **Les complétions se rendent sur le thread principal, et ce n'est pas un
/// détail.** Le système appelle ce délégué hors du thread principal, et la
/// variante `async` de `didReceive` rendait sa complétion sur la file
/// coopérative ; UIKit, qui enchaîne dans le même appel sur la sauvegarde
/// d'état de la scène, lève alors une assertion et tue le processus. C'était
/// l'écran noir au tap sur une notification, app fermée (rapport de crash de
/// l'iPhone, 3 sept. 2026 : `_updateSnapshotAndStateRestorationWithAction`
/// sous `didReceive`). D'où les variantes à complétion, rappelées depuis le
/// thread principal. La classe reste non isolée : le protocole passe des
/// objets non `Sendable`, et une implémentation `@MainActor` ne compile pas.
final class NotificationHandler: NSObject, UNUserNotificationCenterDelegate {
  /// Le salon d'une notification touchée avant que le magasin ne le connaisse.
  @MainActor static var pendingRoomID: String?

  /// Une complétion du système, que l'on promet de n'appeler qu'une fois, sur
  /// le thread principal. Le SDK ne la déclare pas `@Sendable` ; la boîte est
  /// ce qui la fait traverser vers le processus principal.
  private struct Completion<Value>: @unchecked Sendable {
    let run: (Value) -> Void
  }

  /// App active, le push se tait : la notification locale, elle, sait quel
  /// fil est à l'écran, quel salon est muet, et regroupe les rafales. Le push
  /// n'a de raison d'être que quand l'app ne tourne pas.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    let isRemote = notification.request.content.userInfo["room_id"] != nil
    let completion = Completion(run: completionHandler)
    Task { @MainActor in
      completion.run(isRemote ? [] : [.banner, .sound, .list])
    }
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let info = response.notification.request.content.userInfo
    let direct = info[RelayStore.notificationConversationKey] as? String
    // Le push ne nomme qu'un salon ; le magasin, lui, parle en fils.
    let roomID = info["room_id"] as? String
    let completion = Completion<Void>(run: completionHandler)
    Task { @MainActor in
      defer { completion.run(()) }
      if let direct { AppDelegate.store?.openConversationFromNotification(direct); return }
      Self.pendingRoomID = roomID
      AppDelegate.store?.openPendingNotificationIfPossible()
    }
  }
}
