import AppKit
import SwiftUI

/// Une zone qui sait qu'on la survole, et qui n'attrape RIEN.
///
/// En Focus, la barre d'outils s'efface : il faut une lisière en haut de
/// fenêtre pour la rappeler. Un `onHover` SwiftUI exigerait une vue qui teste
/// les clics — elle volerait la sélection du texte de la page. Une zone de
/// suivi AppKit, elle, reçoit ses entrées/sorties de souris sans jamais entrer
/// dans la chaîne des événements : `hitTest` rend `nil`, la page reste à nu.
struct HoverZone: NSViewRepresentable {
  var onHoverChange: (Bool) -> Void

  func makeNSView(context: Context) -> TrackingView {
    let view = TrackingView()
    view.onHoverChange = onHoverChange
    return view
  }

  func updateNSView(_ nsView: TrackingView, context: Context) {
    nsView.onHoverChange = onHoverChange
  }

  final class TrackingView: NSView {
    var onHoverChange: ((Bool) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      trackingAreas.forEach(removeTrackingArea)
      addTrackingArea(
        // `activeAlways` : la lisière doit répondre même quand la fenêtre n'est
        // pas encore la fenêtre clé — sinon il faut cliquer avant de survoler.
        NSTrackingArea(
          rect: bounds,
          options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
          owner: self
        )
      )
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if window == nil { onHoverChange?(false) }
    }
  }
}
