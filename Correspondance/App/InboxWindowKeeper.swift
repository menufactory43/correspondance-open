import AppKit
import SwiftUI

/// Fermer l'inbox ne la détruit pas : elle se cache, et le Dock la remontre.
///
/// Mesuré sur la build du 9 septembre : fenêtre fermée puis Dock cliqué,
/// SwiftUI reconstruisait toute la scène — `NavigationSplitView`, la liste et
/// ses cent quatre-vingts lignes, le fil, la barre d'outils — soit le prix
/// d'un lancement à chaud, ~700 ms avant la fenêtre et le fil encore après.
/// Une fenêtre qu'on ordonne hors écran (`orderOut`) garde tout ça vivant et
/// revient en une frame. Deux gestes à intercepter : le bouton rouge (sa cible
/// est reprise ici) et ⌘W (`CorrespondanceCommands`, « Fermer »). Une fenêtre
/// détachée, elle, se ferme pour de bon — c'est son rôle.
@MainActor
final class InboxWindowHider: NSObject {
  static let shared = InboxWindowHider()

  static func isInbox(_ window: NSWindow) -> Bool {
    window.identifier?.rawValue.hasPrefix(WindowOpener.inboxSceneID) == true && window.level == .normal
  }

  /// La fenêtre s'en va, sans se fermer. Si elle était clé, AppKit en choisit
  /// une autre — ou aucune : l'app reste active, comme après une fermeture.
  static func hide(_ window: NSWindow) {
    window.orderOut(nil)
  }

  /// Ce que ⌘W fait de la fenêtre clé : l'inbox se cache, le reste se ferme.
  static func closeKeyWindow() {
    guard let window = NSApp.keyWindow else { return }
    if isInbox(window) { hide(window) } else { window.performClose(nil) }
  }

  /// Prend la place du bouton rouge de l'inbox, une fois par fenêtre.
  func adopt(_ window: NSWindow) {
    guard Self.isInbox(window), let button = window.standardWindowButton(.closeButton) else { return }
    guard button.target !== self else { return }
    button.target = self
    button.action = #selector(hideSender(_:))
  }

  @objc private func hideSender(_ sender: Any?) {
    guard let window = (sender as? NSView)?.window ?? NSApp.keyWindow else { return }
    Self.hide(window)
  }
}

/// Posé en fond de l'inbox : dès que la vue a sa fenêtre, le bouton rouge
/// apprend à cacher au lieu de fermer.
struct InboxWindowKeeper: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    view.postsFrameChangedNotifications = false
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    DispatchQueue.main.async {
      guard let window = nsView.window else { return }
      InboxWindowHider.shared.adopt(window)
    }
  }
}

extension View {
  /// L'inbox se cache au lieu de se fermer — cf. `InboxWindowHider`.
  func inboxHidesInsteadOfClosing() -> some View {
    background(InboxWindowKeeper())
  }
}
