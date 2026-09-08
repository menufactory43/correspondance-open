import SwiftUI
#if canImport(AppKit)
import AppKit

  /// Les jetons d'observation, désinscrits avec la sentinelle. À part, parce
  /// qu'un `deinit` de vue n'est pas isolé au fil principal et ne peut pas
  /// toucher un tableau de jetons non `Sendable`.
  private final class ObserverBag: @unchecked Sendable {
    private var tokens: [NSObjectProtocol] = []
    private let lock = NSLock()

    func add(_ token: NSObjectProtocol) {
      lock.lock(); tokens.append(token); lock.unlock()
    }

    func removeAll() {
      lock.lock(); let removed = tokens; tokens = []; lock.unlock()
      for token in removed { NotificationCenter.default.removeObserver(token) }
    }

    deinit { removeAll() }
  }
#endif

extension View {
  /// Dit à la vue si elle est près de la partie visible de son défilement —
  /// à moins de `margin` hauteurs d'écran — et le redit à chaque fois que ça
  /// change. C'est ce qui permet à une photo de lâcher sa vignette décodée
  /// quand elle est loin hors champ, et de la reprendre avant d'y revenir.
  ///
  /// La pile du fil n'est pas paresseuse (cf. `ThreadView`) : sans ça, chaque
  /// photo d'un fil de cent cinquante messages garde ses ~1,5 Mo décodés à
  /// demeure, visible ou non — mesuré à 166 Mo d'IOSurface sur un vrai fil.
  ///
  /// Sur Mac, c'est une vue AppKit posée en fond, sans taille propre ni
  /// clic, qui écoute les bornes du `NSClipView` de son `NSScrollView`. Hors
  /// de tout défilement (une fiche, un panneau), elle répond « près ». Sur les
  /// autres plateformes, elle répond « près » une fois pour toutes.
  public func viewportProximity(
    margin: CGFloat = 2,
    _ onChange: @escaping @MainActor (Bool) -> Void
  ) -> some View {
    #if canImport(AppKit)
      background(ViewportProximity(margin: margin, onChange: onChange))
    #else
      onAppear { onChange(true) }
    #endif
  }
}

#if canImport(AppKit)
  private struct ViewportProximity: NSViewRepresentable {
    let margin: CGFloat
    let onChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> ProximitySentinel {
      let view = ProximitySentinel()
      view.margin = margin
      view.onChange = onChange
      return view
    }

    func updateNSView(_ view: ProximitySentinel, context: Context) {
      view.margin = margin
      view.onChange = onChange
      view.scheduleEvaluation()
    }
  }

  /// La sentinelle. Elle ne dessine rien, n'attrape aucun clic, et ne parle
  /// que quand la réponse change — jamais pendant une passe de mise en page
  /// (SwiftUI n'aime pas qu'on touche à un état pendant qu'il place).
  final class ProximitySentinel: NSView {
    var margin: CGFloat = 2
    var onChange: (@MainActor (Bool) -> Void)?

    private var isNear: Bool?
    private var observers = ObserverBag()
    private var evaluationScheduled = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      rewire()
      scheduleEvaluation()
    }

    override func viewDidMoveToSuperview() {
      super.viewDidMoveToSuperview()
      rewire()
      scheduleEvaluation()
    }

    override func layout() {
      super.layout()
      scheduleEvaluation()
    }

    /// Les bornes du clip changent à chaque frame d'un défilement, son cadre
    /// à chaque redimensionnement : les deux déplacent la fenêtre visible.
    private func rewire() {
      observers.removeAll()
      guard let scroll = enclosingScrollView else { return }
      let clip = scroll.contentView
      clip.postsBoundsChangedNotifications = true
      clip.postsFrameChangedNotifications = true
      let center = NotificationCenter.default
      for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
        observers.add(center.addObserver(forName: name, object: clip, queue: nil) { [weak self] _ in
          MainActor.assumeIsolated { self?.scheduleEvaluation() }
        })
      }
    }

    func scheduleEvaluation() {
      guard !evaluationScheduled else { return }
      evaluationScheduled = true
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.evaluationScheduled = false
        self.evaluate()
      }
    }

    private func evaluate() {
      guard window != nil else { return }
      let near: Bool
      if let scroll = enclosingScrollView, let document = scroll.documentView {
        let visible = scroll.documentVisibleRect
        let mine = convert(bounds, to: document)
        let zone = visible.insetBy(dx: 0, dy: -visible.height * margin)
        near = visible.isEmpty || zone.intersects(mine)
      } else {
        near = true
      }
      guard near != isNear else { return }
      isNear = near
      onChange?(near)
    }
  }
#endif
