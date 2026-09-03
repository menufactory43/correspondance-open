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
    LaunchTrace.mark("main")
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
        // `correspondance://partage` : l'extension de partage vient de déposer.
        // L'app tourne déjà ou vient d'être lancée par l'adresse ; dans les
        // deux cas on vide la boîte (InboxStore+Partage).
        .onOpenURL { url in
          guard url.scheme == Partage.schemaURL else { return }
          Task { await store.viderLaBoiteDuPartage() }
        }
        .task {
          // Fenêtre visible → puis demande Contacts (sinon pas dans Confidentialité).
          // Visible pour de vrai, pas « après 500 ms » : sinon Contacts, la sonde
          // AX et la copie de chat.db partent avant la première frame et la retardent.
          await LaunchGate.firstWindowOnScreen()
          try? await Task.sleep(for: .milliseconds(500))
          await store.start()
          if let count = LaunchBench.switchCount {
            await LaunchGate.firstThreadOnScreen()
            try? await Task.sleep(for: .seconds(2))
            let current = store.selectedConversationID
            let ids = store.activeQueue.map(\.id).filter { $0 != current }.prefix(count)
            _ = await LaunchBench.run(select: { await store.select($0) }, ids: Array(ids))
          }
        }
    }
    .defaultSize(width: 1100, height: 760)
    // **C'est cette ligne qui règle la fenêtre géante**, et elle seule.
    //
    // Sans elle, SwiftUI dimensionne la fenêtre sur la hauteur *idéale* du
    // contenu au premier lancement — une liste de conversations n'en a pas de
    // raisonnable, d'où les 2142 pixels observés sur un écran de 869 — et
    // `.defaultSize` ne sert à rien. `contentMinSize` laisse la fenêtre libre
    // au-dessus du minimum de la vue, comme celle d'une conversation détachée.
    //
    // Il y a eu ici, pendant trois commits, une garde qui ramenait la fenêtre
    // dans l'écran à chaque redimensionnement. Elle est partie, et l'enquête
    // vaut d'être gardée :
    //
    // - elle a **tué l'app au lancement**, par intermittence : son `setFrame`
    //   tombait parfois pendant la passe de contraintes d'AppKit, qui lève
    //   alors `_postWindowNeedsUpdateConstraints` — une exception Objective-C
    //   qu'aucun `@try/@catch` posé autour de l'écriture ne peut rattraper,
    //   puisqu'elle survient plus tard, dans le cycle d'affichage ;
    // - et elle ne protégeait de rien de démontré : avec un cadre enregistré
    //   de 1100 × 2142 restauré sur un écran de 1440 × 869, l'app **sans**
    //   garde ouvre une fenêtre de 1100 × 790, mesurée. C'est `contentMinSize`
    //   qui fait le travail.
    //
    // Entre une protection non démontrée qui tue l'app et pas de protection,
    // on choisit pas de protection. Si le cas revient, la seule voie sûre est
    // de répondre à `windowWillResize(_:to:)` — AppKit *demande* une taille au
    // lieu qu'on lui en impose une — jamais un `setFrame` asynchrone.
    .windowResizability(.contentMinSize)
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

    // La connexion d'un pont : une vraie fenêtre, pas une feuille à l'étroit
    // dans Réglages — les formulaires de Meta et de X y respirent, et la
    // fenêtre se redimensionne. `Window` : une seule, rappelée devant.
    Window("Connexion", id: WindowOpener.bridgeLoginSceneID) {
      BridgeLoginWindow()
        .environment(store)
        .environment(themes)
    }
    .defaultSize(width: 960, height: 780)
    .windowResizability(.contentMinSize)

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
    // cc meurt avec l'app ; il renaît avec elle, si on l'a voulu et que son
    // amorce est là. Sans ça, chaque relance de l'app demandait de « ré-activer ».
    AgentLocalHost.resumeAll()
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

  /// cc s'arrête avec l'app. Un agent orphelin qui continuerait de répondre au
  /// nom de quelqu'un après la fermeture serait pire qu'un agent mort — et
  /// c'est le prix assumé de « Sur ce Mac » : pour un cc joignable jour et
  /// nuit, il faut une autre machine.
  func applicationWillTerminate(_ notification: Notification) {
    AgentProcessHost.shared.stopAll()
  }
}
