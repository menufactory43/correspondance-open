import AppKit
import SwiftUI

/// **Une fenêtre ne s'ouvre jamais plus grande que l'écran qui l'accueille, ni
/// hors de ses limites.**
///
/// Ça paraît évident et pourtant : sur un profil neuf, la fenêtre principale
/// s'est ouverte en 1440 × 2142 sur un écran de 1440 × 869, posée à
/// `y = -1273`. Le champ de saisie était hors de l'écran — on ne pouvait
/// littéralement pas envoyer de message. Deux causes possibles, et la borne les
/// couvre toutes les deux :
///
/// - **au premier lancement**, sans cadre enregistré, SwiftUI peut dimensionner
///   la fenêtre sur la hauteur *idéale* du contenu, et une liste de
///   conversations sans hauteur bornée donne exactement ce genre de nombre ;
/// - **à un lancement suivant**, un cadre enregistré sur un écran plus grand
///   (un profil migré, un moniteur débranché) raconte une taille qui n'existe
///   plus.
///
/// Le défaut n'était invisible que par chance : tout le monde ici a un cadre
/// sain enregistré depuis des mois. Il a fallu un profil vierge pour le voir.
enum WindowFrameGuard {

  /// Le cadre qu'on accepte, à partir de celui qu'on nous propose.
  ///
  /// Pure, et c'est le point : la règle s'éprouve avec un écran de 1440 × 869
  /// et un cadre de 1440 × 2142, sans ouvrir la moindre fenêtre.
  ///
  /// - `frame` : ce que la fenêtre voudrait (contenu idéal, ou cadre restauré) ;
  /// - `visible` : `visibleFrame` de l'écran — déjà amputé du Dock et de la
  ///   barre de menus, c'est bien lui qu'il faut, pas `frame` ;
  /// - `minimum` : ce en dessous de quoi la fenêtre devient inutilisable.
  static func clamp(_ frame: CGRect, visible: CGRect, minimum: CGSize) -> CGRect {
    // La taille d'abord : jamais plus que l'écran, jamais moins que le
    // minimum — et si l'écran est plus petit que le minimum, l'écran gagne,
    // sinon on repousserait la fenêtre hors de ses bords pour rien.
    let largeur = max(min(frame.width, visible.width), min(minimum.width, visible.width))
    let hauteur = max(min(frame.height, visible.height), min(minimum.height, visible.height))

    // Puis la position : le cadre tient dans l'écran, sans déborder d'un côté
    // ni de l'autre. `max(visible.minX, …)` passe en second pour qu'un écran
    // plus petit que la fenêtre colle au bord haut-gauche plutôt qu'au bas.
    let x = max(visible.minX, min(frame.origin.x, visible.maxX - largeur))
    let y = max(visible.minY, min(frame.origin.y, visible.maxY - hauteur))

    return CGRect(x: x, y: y, width: largeur, height: hauteur)
  }

  /// Le cadre proposé tient-il déjà ? Sert à ne pas bouger une fenêtre saine —
  /// on ne repositionne que ce qui déborde.
  static func fits(_ frame: CGRect, visible: CGRect) -> Bool {
    frame.width <= visible.width && frame.height <= visible.height
      && visible.contains(CGPoint(x: frame.minX, y: frame.minY))
      && visible.contains(CGPoint(x: frame.maxX - 1, y: frame.maxY - 1))
  }
}

/// Pose la borne sur la vraie `NSWindow`.
///
/// AppKit restaure le cadre enregistré **après** le premier passage de mise en
/// page, et SwiftUI peut le redimensionner encore après : on repasse donc
/// quelques fois, comme `SettingsWindowSizer`. Une fois la fenêtre saine, on ne
/// touche plus à rien — elle appartient à l'utilisateur.
struct WindowFrameGuardView: NSViewRepresentable {
  var minimum: NSSize = NSSize(width: 720, height: 480)

  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    schedule(view)
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {}

  private func schedule(_ view: NSView) {
    for delay in [0.0, 0.05, 0.2, 0.5, 1.0] {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        apply(to: view.window)
      }
    }
  }

  private func apply(to window: NSWindow?) {
    guard let window, let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
    let actuel = window.frame
    guard !WindowFrameGuard.fits(actuel, visible: visible) else { return }
    let borne = WindowFrameGuard.clamp(actuel, visible: visible, minimum: minimum)
    guard borne != actuel else { return }
    window.setFrame(borne, display: true)
  }
}
