import AppKit
import SwiftUI

/// La scène `Settings` de SwiftUI n'expose ni sa taille (`.defaultSize` ne vaut
/// que pour `Window`/`WindowGroup`) ni son titre, et elle restaure sous un nom
/// d'autosave fixe le cadre d'une version précédente — une fenêtre étroite
/// héritée survit à la refonte, et SwiftUI se contente d'y rogner le contenu.
/// On descend donc jusqu'à la vraie `NSWindow` : plancher de taille, poussée
/// unique jusqu'à la taille naturelle, titre français, apparence du thème.
/// L'utilisateur reste libre de redimensionner ensuite : on ne repasse plus.
struct SettingsWindowSizer: NSViewRepresentable {
  let minSize: NSSize
  let idealSize: NSSize
  let title: String
  let isDark: Bool

  func makeCoordinator() -> Coordinator { Coordinator() }

  final class Coordinator {
    var hasSized = false
  }

  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    schedule(view, coordinator: context.coordinator)
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    schedule(nsView, coordinator: context.coordinator)
  }

  /// AppKit restaure le cadre sauvegardé APRÈS le premier passage de mise en
  /// page : on repasse quelques fois, et le dimensionnement ne joue qu'une fois.
  private func schedule(_ view: NSView, coordinator: Coordinator) {
    for delay in [0.0, 0.05, 0.2, 0.5] {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        apply(to: view.window, coordinator: coordinator)
      }
    }
  }

  private func apply(to window: NSWindow?, coordinator: Coordinator) {
    guard let window else { return }

    window.title = title
    window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)

    window.styleMask.insert(.resizable)
    // Le plancher est REPOSÉ à chaque passage : SwiftUI redimensionne la fenêtre
    // de Réglages sur la taille idéale de son contenu à chaque relayout (une
    // feuille qui s'ouvre, un volet qui change), et sans plancher elle rétrécit.
    window.contentMinSize = minSize

    // La poussée jusqu'à la taille naturelle, elle, ne joue qu'une fois : après,
    // la fenêtre appartient à l'utilisateur.
    let floor = coordinator.hasSized ? minSize : idealSize
    coordinator.hasSized = true

    let current = window.contentRect(forFrameRect: window.frame).size
    guard current.width < floor.width || current.height < floor.height else { return }

    let target = NSSize(
      width: max(current.width, floor.width),
      height: max(current.height, floor.height)
    )
    var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: target))
    // On grandit vers le bas et la droite : la barre de titre ne doit pas
    // plonger sous le bord haut de l'écran.
    frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
    // Et jamais plus grand que l'écran : cette fenêtre bornait sa position mais
    // pas sa taille, donc une taille idéale démesurée la faisait déborder —
    // le même défaut que celui de la fenêtre principale sur un profil neuf.
    if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
      frame = WindowFrameGuard.clamp(frame, visible: visible, minimum: minSize)
    }
    window.setFrame(frame, display: true)
  }
}
