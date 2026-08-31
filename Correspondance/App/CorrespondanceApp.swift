import AppKit
import SwiftUI
import CorrespondanceCore
import CorrespondanceUI

@main
struct CorrespondanceApp: App {
  @State private var store = InboxStore()
  /// Une seule instance de préférences pour toute l'app : c'est ce qui fait
  /// qu'un changement de thème dans les Réglages repeint l'inbox ET les
  /// fenêtres détachées, au même instant.
  @State private var themes = ThemePreferences()
  @NSApplicationDelegateAdaptor(CorrespondanceAppDelegate.self) private var appDelegate

  init() {
    // Pas de restauration d'état AppKit au lancement : l'inbox passait par
    // `NSPersistentUIRestorer` (boucle imbriquée, décodage, seconde passe de
    // layout) pour ne restaurer… rien — il n'y a même pas d'état sauvegardé
    // sur disque. Le cadre de la fenêtre et les largeurs de colonnes vivent
    // dans les préférences (`NSWindow Frame inbox-AppWindow-1`,
    // `NSSplitView Subview Frames…`) et survivent à un quit sans lui — vérifié.
    // Mesuré : fenêtre à l'écran 53 ms plus tôt. Domaine volatil : rien n'est
    // écrit dans les préférences de l'utilisateur.
    UserDefaults.standard.setVolatileDomain(
      ["ApplePersistenceIgnoreState": true], forName: UserDefaults.argumentDomain
    )
    // Les cœurs libres préchauffent détecteur de liens et fonte pendant
    // qu'AppKit monte la fenêtre : la première bulle les trouve déjà prêts.
    LaunchWarmup.begin()
  }

  var body: some Scene {
    WindowGroup(id: WindowOpener.inboxSceneID) {
      ContentView()
        .environment(store)
        .environment(themes)
        .task {
          // Fenêtre visible → puis demande Contacts (sinon pas dans Confidentialité).
          // Visible pour de vrai, pas « après 500 ms » : sinon Contacts, la sonde
          // AX et la copie de chat.db partent avant la première frame et la retardent.
          await LaunchGate.firstWindowOnScreen()
          try? await Task.sleep(for: .milliseconds(500))
          await store.start()
        }
    }
    .defaultSize(width: 1100, height: 760)
    .commands { CorrespondanceCommands(store: store, themes: themes) }

    // Une conversation, sa fenêtre. Rappeler la même valeur ne crée pas une
    // seconde fenêtre : `WindowGroup(for:)` ramène celle qui existe au premier
    // plan. Elle ne s'ouvre jamais d'elle-même au lancement — cf. `claimDetachRequest`.
    WindowGroup(
      "Conversation",
      id: WindowOpener.conversationSceneID,
      for: String.self
    ) { $conversationID in
      DetachedConversationWindow(conversationID: conversationID)
        .environment(store)
        .environment(themes)
    }
    .defaultSize(width: 520, height: 640)
    // `contentMinSize` : la fenêtre peut descendre jusqu'au post-it que la vue
    // accepte (240 × 180) sans que rien ne se chevauche.
    .windowResizability(.contentMinSize)
    .windowStyle(.hiddenTitleBar)

    Settings {
      SettingsView()
        .environment(store)
        .environment(themes)
    }
  }
}

/// Fermer l'inbox n'est pas quitter : une fenêtre détachée peut rester seule à
/// l'écran, et le Dock sait rouvrir la liste.
final class CorrespondanceAppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    LaunchGate.noteDidFinishLaunching()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    guard !hasVisibleWindows else { return true }
    WindowOpener.shared.openInbox()
    return true
  }

  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    true
  }
}
