import SwiftUI
import UIKit

/// Le plateau des médias comme `inputView` : une vue UIKit invisible qui
/// prend le focus à la place du champ, et dont la « touche » est le plateau.
///
/// C'est le mécanisme de Signal. Le système sait échanger un clavier et un
/// input view dans la même animation, sans que la barre au-dessus bouge ;
/// tout ce que l'app simulait — décalage, hauteur, courbes — disparaît.
/// Faire défiler le fil le range comme le clavier (`scrollDismissesKeyboard`).
struct MediaTrayInputHost<Content: View>: UIViewRepresentable {
  /// `true` : le plateau doit être là. Redevient `false` de lui-même quand
  /// le champ reprend le focus ou que le fil le range.
  @Binding var isActive: Bool
  /// La hauteur du clavier que le plateau remplace, bord d'écran compris.
  let height: CGFloat
  @ViewBuilder let content: () -> Content

  func makeUIView(context: Context) -> ResponderView {
    let view = ResponderView()
    view.onResponderChange = { active in
      if isActive != active { isActive = active }
    }
    let hosting = UIHostingController(rootView: AnyView(content()))
    hosting.view.backgroundColor = .clear
    view.hosting = hosting
    view.setTrayHeight(height)
    return view
  }

  func updateUIView(_ view: ResponderView, context: Context) {
    view.hosting?.rootView = AnyView(content())
    view.setTrayHeight(height)
    if isActive, !view.isFirstResponder {
      view.becomeFirstResponder()
    } else if !isActive, view.isFirstResponder {
      view.resignFirstResponder()
    }
  }

  func sizeThatFits(_ proposal: ProposedViewSize, uiView: ResponderView, context: Context) -> CGSize? {
    .zero
  }

  final class ResponderView: UIView {
    var hosting: UIHostingController<AnyView>?
    var onResponderChange: ((Bool) -> Void)?
    /// La hauteur du plateau, en contrainte : le système ignore le cadre
    /// d'un `inputView` posé en Auto Layout et le laisse se dimensionner
    /// d'après son contenu — mesuré sur l'iPhone : 233 points face à un
    /// clavier de 328, et le composer sautait à l'échange (16 sept. 2026).
    private var heightConstraint: NSLayoutConstraint?
    private lazy var tray: UIView = {
      // Une `UIInputView` qui se dimensionne par ses contraintes : c'est le
      // seul chemin que le système respecte pour la hauteur d'un input view
      // (le mécanisme de Signal). Une `UIView` ordinaire, cadre ou contrainte,
      // était posée à 233 points face à un clavier de 328 (iOS 27, 16 sept.).
      let container = TrayContainer(frame: CGRect(x: 0, y: 0, width: 320, height: trayHeight), inputViewStyle: .default)
      container.allowsSelfSizing = true
      container.translatesAutoresizingMaskIntoConstraints = false
      container.backgroundColor = .clear
      let height = container.heightAnchor.constraint(equalToConstant: trayHeight)
      height.priority = .required
      height.isActive = true
      heightConstraint = height
      if let hosted = hosting?.view {
        hosted.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hosted)
        NSLayoutConstraint.activate([
          hosted.leadingAnchor.constraint(equalTo: container.leadingAnchor),
          hosted.trailingAnchor.constraint(equalTo: container.trailingAnchor),
          hosted.topAnchor.constraint(equalTo: container.topAnchor),
          hosted.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
      }
      return container
    }()
    private var trayHeight: CGFloat = 300

    override var canBecomeFirstResponder: Bool { true }
    override var inputView: UIView? { tray }

    func setTrayHeight(_ height: CGFloat) {
      guard height > 0, height != trayHeight else { return }
      trayHeight = height
      tray.frame.size.height = height
      heightConstraint?.constant = height
      if isFirstResponder { reloadInputViews() }
    }

    override func becomeFirstResponder() -> Bool {
      tray.frame.size.height = trayHeight
      heightConstraint?.constant = trayHeight
      MediaTrayPresence.count += 1
      let ok = super.becomeFirstResponder()
      if ok { onResponderChange?(true) } else { MediaTrayPresence.count -= 1 }
      return ok
    }

    override func resignFirstResponder() -> Bool {
      let ok = super.resignFirstResponder()
      if ok {
        MediaTrayPresence.count = max(0, MediaTrayPresence.count - 1)
        onResponderChange?(false)
      }
      return ok
    }
  }
}

/// Un plateau est à l'écran, ou en train d'y monter. Compté AVANT que le
/// système annonce son « clavier », décompté APRÈS qu'il l'a rendu : c'est ce
/// qui permet à `KeyboardHeightMemory` de ne mesurer que les vrais claviers.
/// Hors du type générique, qui ne peut pas porter de stockage statique.
@MainActor
enum MediaTrayPresence {
  static var count = 0
  static var isPresentingTray: Bool { count > 0 }
}

/// Le conteneur du plateau : une `UIInputView` qui se dimensionne par ses
/// contraintes (`allowsSelfSizing`), la seule que le système laisse fixer
/// sa hauteur.
final class TrayContainer: UIInputView {}
