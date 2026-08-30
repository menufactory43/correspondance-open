import AppKit
import SwiftUI
import CorrespondanceCore

/// Le panneau de la réponse rapide.
///
/// `nonactivatingPanel` : il paraît sans mettre Correspondance au premier plan —
/// l'app qu'on quittait des yeux reste active derrière. Mais il prend le clavier,
/// sinon il n'y aurait rien à écrire dedans : d'où `canBecomeKey`.
final class QuickReplyPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  /// Jamais « main » : ce n'est pas une fenêtre de document, c'est une fiche.
  override var canBecomeMain: Bool { false }
}

/// Ce que le panneau a sous les yeux. Vit dans le contrôleur, pas dans la vue :
/// le moniteur clavier (⌘↑ ⌘↓ ⌘K Échap) doit pouvoir le pousser de l'extérieur.
@MainActor
@Observable
final class QuickReplyModel {
  /// Le fil montré. `nil` = rien à répondre.
  var conversationID: String?
  /// Le mini-sélecteur (⌘K) est-il ouvert ?
  var isShowingPicker = false
  var query = ""

  /// La file où tournent ⌘↑ et ⌘↓ : la même que celle du Focus.
  func queue(in store: InboxStore) -> [Conversation] { store.activeQueue }

  /// À l'ouverture : le non-lu le plus récent, sinon le fil de l'inbox.
  func openDefault(in store: InboxStore) {
    let queue = queue(in: store)
    conversationID = QuickReplyQueue.defaultConversationID(
      in: queue, selectedID: store.selectedConversationID
    )
  }

  /// ⌘↑ / ⌘↓ — circulaire.
  func step(in store: InboxStore, by delta: Int) {
    let ids = queue(in: store).map(\.id)
    conversationID = QuickReplyQueue.step(from: conversationID, in: ids, by: delta)
  }

  func choose(_ id: String) {
    conversationID = id
    isShowingPicker = false
    query = ""
  }

  func togglePicker() {
    isShowingPicker.toggle()
    if !isShowingPicker { query = "" }
  }
}

/// Un seul panneau, jamais ouvert de lui-même — uniquement sur geste : le
/// raccourci global, l'icône de barre de menus, ou une notification.
@MainActor
final class QuickReplyPanelController {
  static let shared = QuickReplyPanelController()

  let model = QuickReplyModel()

  private var panel: QuickReplyPanel?
  private var keyMonitor: Any?
  private var resignToken: NSObjectProtocol?
  private weak var store: InboxStore?
  private var themes: ThemePreferences?

  private init() {}

  var isVisible: Bool { panel?.isVisible == true }

  /// L'app confie ses deux sources de vérité au contrôleur : le panneau ne
  /// fabrique ni magasin ni préférences, il emprunte ceux de l'inbox.
  func configure(store: InboxStore, themes: ThemePreferences) {
    self.store = store
    self.themes = themes
    refreshHotKey()
  }

  /// Relit les réglages : le raccourci répond, ou plus du tout.
  func refreshHotKey() {
    guard QuickReplyPreferences.isEnabled() else {
      GlobalHotKey.shared.unregister()
      return
    }
    GlobalHotKey.shared.register(QuickReplyPreferences.hotKey()) { [weak self] in
      self?.toggle()
    }
  }

  func toggle() {
    if isVisible { close() } else { present() }
  }

  /// Ouvre le panneau sur le fil qui attend une réponse.
  func present(conversationID: String? = nil) {
    guard let store, let themes else { return }
    // « Jamais au-dessus d'une app plein écran » : on ne s'invite pas.
    if QuickReplyPreferences.avoidsFullScreen(), Self.isFrontmostScreenFullScreen() { return }

    if let conversationID {
      model.choose(conversationID)
    } else if model.conversationID == nil
      || !store.conversations.contains(where: { $0.id == model.conversationID })
    {
      model.openDefault(in: store)
    }

    let panel = self.panel ?? makePanel(store: store, themes: themes)
    self.panel = panel
    Self.place(panel)
    applyCollectionBehavior(panel)
    panel.makeKeyAndOrderFront(nil)
    installKeyMonitor()
    observeResignKey(panel)
    if let id = model.conversationID { store.quickReplyBecameVisible(id) }
  }

  /// Comme Spotlight : cliquer ailleurs, c'est avoir fini. Le panneau n'a ni
  /// feux ni bouton — sans cela, il resterait à flotter sans porte de sortie.
  private func observeResignKey(_ panel: QuickReplyPanel) {
    guard resignToken == nil else { return }
    resignToken = NotificationCenter.default.addObserver(
      forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
    ) { _ in
      MainActor.assumeIsolated { QuickReplyPanelController.shared.close() }
    }
  }

  func close() {
    if let resignToken { NotificationCenter.default.removeObserver(resignToken) }
    resignToken = nil
    panel?.orderOut(nil)
    removeKeyMonitor()
    model.isShowingPicker = false
    model.query = ""
    store?.quickReplyClosed()
  }

  /// Le message est parti : « Fermer après envoi » décide de la suite.
  func noteSent() {
    guard QuickReplyPreferences.closesAfterSend() else { return }
    close()
  }

  // MARK: - Fabrication

  private func makePanel(store: InboxStore, themes: ThemePreferences) -> QuickReplyPanel {
    let panel = QuickReplyPanel(
      contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
      styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.hidesOnDeactivate = false
    // `becomesKeyOnlyIfNeeded` resterait à `true` pour une palette d'outils :
    // ici tout le panneau EST un champ de texte, il prend le clavier d'emblée.
    panel.becomesKeyOnlyIfNeeded = false
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.isMovableByWindowBackground = true
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.isRestorable = false
    panel.animationBehavior = .utilityWindow
    panel.minSize = NSSize(width: 240, height: 180)
    // Aucun des trois feux : le panneau n'est pas une fenêtre de travail. Il se
    // ferme d'un Échap, d'un ⌘W, ou parce que le message est parti. Les laisser
    // poserait un point rouge flottant au-dessus du papier, hors de la carte.
    for button in [NSWindow.ButtonType.closeButton, .zoomButton, .miniaturizeButton] {
      panel.standardWindowButton(button)?.isHidden = true
    }

    let host = NSHostingView(
      rootView: QuickReplyView(model: model)
        .environment(store)
        .environment(themes)
    )
    panel.contentView = host
    // Après le contenu : le papier doit monter jusqu'au bord haut du cadre,
    // sinon une bande transparente reste à la place de la barre de titre.
    panel.styleMask.insert(.fullSizeContentView)
    return panel
  }

  /// Comme Spotlight : centré en haut de l'écran qui porte la souris.
  private static func place(_ panel: NSPanel) {
    guard let screen = screenUnderMouse() else { return }
    let visible = screen.visibleFrame
    let size = panel.frame.size
    let origin = NSPoint(
      x: visible.midX - size.width / 2,
      y: visible.maxY - size.height - min(140, visible.height * 0.18)
    )
    panel.setFrameOrigin(origin)
  }

  private static func screenUnderMouse() -> NSScreen? {
    let point = NSEvent.mouseLocation
    return NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
  }

  /// Barre des menus escamotée sur l'écran visé : quelqu'un y est en plein écran.
  /// Faute d'API publique pour l'interroger, c'est le signe qu'on a.
  static func isFrontmostScreenFullScreen() -> Bool {
    guard let screen = screenUnderMouse() else { return false }
    return screen.visibleFrame.height >= screen.frame.height
  }

  private func applyCollectionBehavior(_ panel: NSPanel) {
    var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
    if !QuickReplyPreferences.avoidsFullScreen() {
      behavior.insert(.fullScreenAuxiliary)
    }
    panel.collectionBehavior = behavior
  }

  // MARK: - Clavier

  /// ⌘↑ ⌘↓ ⌘K Échap : au-dessus du champ de texte, qui mangerait les flèches.
  private func installKeyMonitor() {
    guard keyMonitor == nil else { return }
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      // `assumeIsolated` ne rend qu'un booléen : un `NSEvent` ne traverse pas
      // une frontière d'isolation en Swift 6.
      let handled = MainActor.assumeIsolated { () -> Bool in
        guard let self, let panel = self.panel, panel.isKeyWindow else { return false }
        return self.handle(event)
      }
      return handled ? nil : event
    }
  }

  private func removeKeyMonitor() {
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    keyMonitor = nil
  }

  private func handle(_ event: NSEvent) -> Bool {
    let command = event.modifierFlags.contains(.command)
    switch event.keyCode {
    case 53: // Échap
      if model.isShowingPicker {
        model.togglePicker()
      } else {
        close()
      }
      return true
    case 126 where command: // ⌘↑
      moveTo(delta: -1)
      return true
    case 125 where command: // ⌘↓
      moveTo(delta: 1)
      return true
    case 40 where command: // ⌘K
      model.togglePicker()
      return true
    default:
      return false
    }
  }

  private func moveTo(delta: Int) {
    guard let store else { return }
    model.step(in: store, by: delta)
    if let id = model.conversationID { store.quickReplyBecameVisible(id) }
  }
}
