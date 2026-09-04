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
    private var monitors: [Any] = []

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

    override func mouseEntered(with event: NSEvent) {
      onHoverChange?(true)
      startWatching()
    }

    /// La sortie de la lisière n'est pas la sortie du haut de la fenêtre.
    ///
    /// En Focus, la barre d'outils qu'on vient de rappeler POUSSE le contenu
    /// vers le bas : la lisière glisse sous la souris, AppKit signale une
    /// sortie, la barre se cache, le contenu remonte, la lisière revient sous
    /// la souris — et la barre clignotait à chaque passage. Tant que la souris
    /// reste dans la bande entre la lisière et le bord haut de la fenêtre
    /// (la barre, donc), on ne dit rien ; c'est le moniteur qui tranchera.
    override func mouseExited(with event: NSEvent) {
      if isPointerInTopBand { return }
      stopWatching()
      onHoverChange?(false)
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if window == nil {
        stopWatching()
        onHoverChange?(false)
      }
    }

    deinit { stopWatching() }

    /// La souris est-elle encore entre la lisière et le haut de la fenêtre ?
    private var isPointerInTopBand: Bool {
      guard let window else { return false }
      let zone = window.convertToScreen(convert(bounds, to: nil))
      let top = window.frame.maxY
      guard top > zone.minY else { return false }
      let band = NSRect(x: zone.minX, y: zone.minY, width: zone.width, height: top - zone.minY)
      return band.contains(NSEvent.mouseLocation)
    }

    /// Le moniteur ne vit que pendant le survol : il suit la souris jusqu'à ce
    /// qu'elle quitte la bande, puis se retire. Local pour notre app, global
    /// pour le cas où une autre est devant — la fenêtre reste survolable.
    private func startWatching() {
      guard monitors.isEmpty else { return }
      let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
      if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
        self?.settle()
        return event
      }) {
        monitors.append(local)
      }
      if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] _ in
        self?.settle()
      }) {
        monitors.append(global)
      }
      window?.acceptsMouseMovedEvents = true
    }

    private func stopWatching() {
      monitors.forEach(NSEvent.removeMonitor)
      monitors.removeAll()
    }

    private func settle() {
      guard !isPointerInTopBand else { return }
      stopWatching()
      onHoverChange?(false)
    }
  }
}
