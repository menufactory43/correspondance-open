import AppKit

/// Le point de départ de ce qui n'a rien à faire avant la première frame :
/// le fil de la conversation ouverte, la demande Contacts, la sonde AX de
/// Messages, la copie de chat.db, la boucle `/sync`.
///
/// Un simple délai ne suffit pas : selon la machine la fenêtre met 300 ms ou
/// 1,5 s à paraître, et tout ce qui se construit avant la retarde d'autant —
/// c'est le « rebond et demi » du Dock. On attend donc que l'inbox soit
/// réellement peinte à l'écran, avec un plafond pour ne jamais bloquer un
/// lancement sans fenêtre (ouverture en arrière-plan, agent de session).
@MainActor
enum LaunchGate {
  /// Vrai dès que l'inbox a été peinte une fois — ou que le plafond est passé.
  /// Une vue née après n'a plus rien à différer. Lu depuis l'init des vues
  /// (hors isolation formelle, mais toujours sur le fil principal), écrit ici.
  nonisolated(unsafe) private(set) static var didPaintFirstWindow = false
  /// `applicationDidFinishLaunching` est passé : la restauration de fenêtre —
  /// et sa boucle imbriquée, pendant laquelle la fenêtre est déjà « visible »
  /// sans avoir été peinte — est terminée.
  nonisolated(unsafe) private(set) static var didFinishLaunching = false

  static func noteDidFinishLaunching() {
    didFinishLaunching = true
    LaunchTrace.mark("didFinish")
    DispatchQueue.main.async { LaunchTrace.mark("frame1") }
  }

  static func firstWindowOnScreen(timeout: Duration = .seconds(3)) async {
    if didPaintFirstWindow { return }
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline, !didPaintFirstWindow {
      let painted = NSApp.windows.contains { window in
        // Pas n'importe quelle fenêtre : l'icône de barre de menus et les
        // panneaux comptent comme « à l'écran » bien avant l'inbox. SwiftUI
        // nomme les siennes « <scène>-AppWindow-N ».
        window.level == .normal
          && window.identifier?.rawValue.hasPrefix(WindowOpener.inboxSceneID) == true
          && window.isVisible
          && window.occlusionState.contains(.visible)
      }
      if painted { break }
      try? await Task.sleep(for: .milliseconds(30))
    }
    didPaintFirstWindow = true
    LaunchTrace.mark("window")
  }

  /// Vrai dès que le fil de la conversation ouverte a été peint une fois — ou
  /// qu'aucun fil n'est venu dans le délai (pas de conversation, agent).
  /// C'est le second palier : ce qui peut attendre le fil (les photos de la
  /// barre latérale) attend ici, pour ne pas lui voler ses passes de layout.
  nonisolated(unsafe) private(set) static var didPaintFirstThread = false

  static func markThreadPainted() {
    didPaintFirstThread = true
  }

  static func firstThreadOnScreen(timeout: Duration = .seconds(2)) async {
    await firstWindowOnScreen()
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline, !didPaintFirstThread {
      try? await Task.sleep(for: .milliseconds(30))
    }
    didPaintFirstThread = true
  }
}
