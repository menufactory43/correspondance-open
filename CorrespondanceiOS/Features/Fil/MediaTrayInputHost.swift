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
    private lazy var tray: UIView = {
      let container = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 300))
      container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      container.backgroundColor = .clear
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
      if isFirstResponder { reloadInputViews() }
    }

    override func becomeFirstResponder() -> Bool {
      tray.frame.size.height = trayHeight
      let ok = super.becomeFirstResponder()
      if ok { onResponderChange?(true) }
      return ok
    }

    override func resignFirstResponder() -> Bool {
      let ok = super.resignFirstResponder()
      if ok { onResponderChange?(false) }
      return ok
    }
  }
}
