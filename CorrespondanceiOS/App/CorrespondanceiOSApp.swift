import CorrespondanceCore
import CorrespondanceUI
import SwiftUI

@main
struct CorrespondanceiOSApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @State private var store = RelayStore(demo: DemoRelay.isRequested)
  @State private var themes = ThemePreferences()
  @State private var push = PushRegistration()

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
          await store.start()
          // L'autorisation se demande une fois CONNECTÉ, jamais devant l'écran
          // de connexion : réclamer les notifications avant de savoir s'il y a
          // un Relais, c'est demander avant d'avoir quoi que ce soit à dire.
          if store.session == .connected, !store.isDemo {
            await push.requestAuthorizationIfNeeded()
          }
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
