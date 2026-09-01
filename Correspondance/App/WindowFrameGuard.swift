import AppKit
import CorrespondanceObjC
import OSLog
import SwiftUI

/// **Une fenêtre ne s'ouvre jamais plus grande que l'écran qui l'accueille, ni
/// hors de ses limites — et elle ne le devient pas non plus.**
///
/// Sur un profil neuf, la fenêtre principale s'ouvrait à une taille normale
/// puis **devenait géante une fois le contenu chargé** : 1100 × 2142 sur un
/// écran de 1440 × 869, posée à `y = -1273`, champ de saisie hors de l'écran.
/// Personne ne pouvait envoyer de message.
///
/// Ce détail — « puis » — est toute l'affaire. Une garde qui s'exécute au
/// montage borne une fenêtre vide, et SwiftUI la redimensionne ensuite sur la
/// hauteur *idéale* du contenu dès que les conversations arrivent. La règle
/// était juste ; c'est le moment qui ne l'était pas.
///
/// D'où trois défenses, et il en faut trois :
///
/// 1. `contentMaxSize` : **AppKit lui-même** refuse de dépasser l'écran, sans
///    qu'on ait à courir après un redimensionnement ;
/// 2. l'observation de `didResize` / `didMove` / `didChangeScreen` : ce qui
///    déborde quand même est ramené, à chaque fois, pas une fois ;
/// 3. la borne sur le cadre restauré, pour un profil migré depuis un écran plus
///    grand.
enum WindowFrameGuard {

  /// Le cadre qu'on accepte, à partir de celui qu'on nous propose. Pure : la
  /// règle s'éprouve sans ouvrir la moindre fenêtre.
  ///
  /// - `frame` : ce que la fenêtre voudrait (contenu idéal, ou cadre restauré) ;
  /// - `visible` : `visibleFrame` de l'écran — déjà amputé du Dock et de la
  ///   barre de menus, c'est bien lui qu'il faut ;
  /// - `minimum` : ce en dessous de quoi la fenêtre devient inutilisable.
  static func clamp(_ frame: CGRect, visible: CGRect, minimum: CGSize) -> CGRect {
    // La taille d'abord : jamais plus que l'écran, jamais moins que le
    // minimum — et si l'écran est plus petit que le minimum, l'écran gagne,
    // sinon on repousserait la fenêtre hors de ses bords pour rien.
    let largeur = max(min(frame.width, visible.width), min(minimum.width, visible.width))
    let hauteur = max(min(frame.height, visible.height), min(minimum.height, visible.height))

    // Puis la position : le cadre tient dans l'écran, sans déborder d'un côté
    // ni de l'autre.
    let x = max(visible.minX, min(frame.origin.x, visible.maxX - largeur))
    let y = max(visible.minY, min(frame.origin.y, visible.maxY - hauteur))

    return CGRect(x: x, y: y, width: largeur, height: hauteur)
  }

  /// Le cadre tient-il déjà ? Sert à ne pas bouger une fenêtre saine.
  static func fits(_ frame: CGRect, visible: CGRect) -> Bool {
    frame.width <= visible.width && frame.height <= visible.height
      && frame.minX >= visible.minX && frame.minY >= visible.minY
      && frame.maxX <= visible.maxX && frame.maxY <= visible.maxY
  }

  /// Le maximum qu'on a le droit de poser sur une fenêtre.
  ///
  /// **Jamais inférieur au minimum**, composante par composante. AppKit refuse
  /// un maximum sous le minimum en levant une exception Objective-C, et l'app
  /// meurt d'un `SIGABRT` au lancement — c'est arrivé : la barre latérale, la
  /// liste et le fil ont chacun leur largeur minimale, et leur somme peut
  /// dépasser la largeur visible de l'écran.
  ///
  /// Si le contenu exige plus grand que l'écran, **c'est l'écran qui perd** :
  /// une fenêtre un peu trop large est un désagrément, un plantage est une app
  /// morte.
  static func safeMaximum(screen: CGSize, contentMinimum: CGSize) -> CGSize {
    CGSize(
      width: max(screen.width, contentMinimum.width),
      height: max(screen.height, contentMinimum.height)
    )
  }

  /// Le cadre à poser, ou `nil` s'il n'y a rien à faire. C'est la décision que
  /// prend l'observateur à chaque redimensionnement.
  static func adjustment(for frame: CGRect, visible: CGRect, minimum: CGSize) -> CGRect? {
    guard !fits(frame, visible: visible) else { return nil }
    let borne = clamp(frame, visible: visible, minimum: minimum)
    return borne == frame ? nil : borne
  }
}

/// Ce que le gardien a besoin de savoir d'une fenêtre.
///
/// Une couture, et pas une abstraction gratuite : créer une vraie `NSWindow`
/// dans le harnais de test injecté **fait planter le processus** (exit 139), ce
/// qui emportait toute la suite sans qu'aucune ligne ne le dise. Avec ce
/// protocole, le scénario réel — saine au montage, puis agrandie par le
/// contenu — s'éprouve sans AppKit.
@MainActor
protocol WindowFrameTarget: AnyObject {
  var currentFrame: CGRect { get }
  var currentContentMaxSize: CGSize { get set }
  /// Ce que le contenu exige — SwiftUI le pose, et AppKit refuse tout maximum
  /// qui passerait dessous.
  var currentContentMinSize: CGSize { get }
  func contentSize(forFrame frame: CGRect) -> CGSize
  func applyFrame(_ frame: CGRect)
}

@MainActor
extension NSWindow: WindowFrameTarget {
  var currentFrame: CGRect { frame }
  var currentContentMaxSize: CGSize {
    get { contentMaxSize }
    set { contentMaxSize = newValue }
  }
  var currentContentMinSize: CGSize { contentMinSize }
  func contentSize(forFrame frame: CGRect) -> CGSize { contentRect(forFrameRect: frame).size }
  func applyFrame(_ frame: CGRect) { setFrame(frame, display: true) }
}

/// Tient la borne **dans la durée**.
@MainActor
final class WindowFrameKeeper {
  static let log = Logger(subsystem: "com.correspondance.app", category: "fenetre")

  private weak var target: (any WindowFrameTarget)?
  private weak var window: NSWindow?
  private let minimum: NSSize
  private let visibleFrame: () -> CGRect
  private var observers: [NSObjectProtocol] = []
  /// Notre propre `setFrame` déclenche `didResize` : sans ce drapeau, on
  /// s'observerait soi-même.
  private var enCoursDAjustement = false

  init(target: any WindowFrameTarget, minimum: NSSize, visibleFrame: @escaping () -> CGRect) {
    self.target = target
    self.window = target as? NSWindow
    self.minimum = minimum
    self.visibleFrame = visibleFrame
  }

  convenience init(window: NSWindow, minimum: NSSize, visibleFrame: @escaping () -> CGRect) {
    self.init(target: window, minimum: minimum, visibleFrame: visibleFrame)
  }

  /// On retire les observateurs à la main : un `deinit` ne peut pas toucher à
  /// un état isolé sur l'acteur principal. Appelé quand la fenêtre se ferme.
  /// Une garde de confort ne doit **jamais** pouvoir tuer l'app. Si AppKit
  /// refuse, on renonce et on le journalise : le pire cas acceptable est une
  /// fenêtre mal dimensionnée, jamais un `SIGABRT` au lancement.
  private func sansPlanter(_ quoi: String, _ ecriture: @escaping () -> Void) {
    guard let exception = CorrespondanceExceptionCatcher.catchException(ecriture) else { return }
    Self.log.error(
      "\(quoi, privacy: .public) refusé par AppKit : \(exception.reason ?? "sans raison", privacy: .public) — la fenêtre reste telle quelle"
    )
  }

  func stop() {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers.removeAll()
  }

  func start() {
    apply()
    let centre = NotificationCenter.default
    for nom in [
      NSWindow.didResizeNotification,
      NSWindow.didMoveNotification,
      NSWindow.didChangeScreenNotification,
    ] {
      observers.append(
        centre.addObserver(forName: nom, object: window, queue: .main) { [weak self] _ in
          self?.apply()
        }
      )
    }
  }

  /// Pose la borne, et **arme AppKit** pour qu'il refuse de la dépasser.
  func apply() {
    guard let target, !enCoursDAjustement else { return }
    let visible = visibleFrame()

    // 1. AppKit refuse désormais lui-même : c'est ce qui empêche SwiftUI de
    //    demander la hauteur idéale du contenu quand les conversations
    //    arrivent. Une garde qui court après le redimensionnement arrive
    //    toujours trop tard ; une borne posée sur la fenêtre, non.
    //
    //    Mais jamais sous le minimum du contenu : ça faisait lever AppKit et
    //    mourir l'app au lancement.
    let maxContenu = WindowFrameGuard.safeMaximum(
      screen: target.contentSize(forFrame: visible),
      contentMinimum: target.currentContentMinSize
    )
    if target.currentContentMaxSize != maxContenu {
      sansPlanter("contentMaxSize") { target.currentContentMaxSize = maxContenu }
    }

    // 2. Et ce qui déborde déjà revient dans l'écran.
    guard let borne = WindowFrameGuard.adjustment(
      for: target.currentFrame, visible: visible, minimum: minimum
    ) else { return }
    enCoursDAjustement = true
    sansPlanter("setFrame") { target.applyFrame(borne) }
    enCoursDAjustement = false
  }
}

/// Pose le gardien sur la fenêtre qui porte cette vue.
struct WindowFrameGuardView: NSViewRepresentable {
  var minimum: NSSize = NSSize(width: 720, height: 480)

  func makeCoordinator() -> Coordinator { Coordinator() }

  final class Coordinator {
    var keeper: WindowFrameKeeper?
  }

  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    attach(view, coordinator: context.coordinator)
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    attach(nsView, coordinator: context.coordinator)
  }

  /// La fenêtre n'existe pas encore au premier passage : on réessaie quelques
  /// fois, puis le gardien prend le relais **pour toute la vie de la fenêtre**.
  private func attach(_ view: NSView, coordinator: Coordinator) {
    guard coordinator.keeper == nil else {
      coordinator.keeper?.apply()
      return
    }
    guard let window = view.window else {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        attach(view, coordinator: coordinator)
      }
      return
    }
    let keeper = WindowFrameKeeper(window: window, minimum: minimum) { [weak window] in
      (window?.screen ?? NSScreen.main)?.visibleFrame ?? .zero
    }
    coordinator.keeper = keeper
    keeper.start()
  }
}
