import AppKit
import Observation

/// L'icône de barre de menus de la réponse rapide — en AppKit, pas en scène.
///
/// `MenuBarExtra(isInserted:)` posé à côté de `.commands` fait reboucler
/// SwiftUI sur la reconstruction du menu principal (100 % de processeur et
/// plusieurs gigaoctets en quelques minutes, dès le lancement, même l'icône
/// éteinte). Un `NSStatusItem` fait la même chose sans rien coûter, et suit
/// le réglage comme le compteur de non-lus de lui-même.
@MainActor
final class QuickReplyStatusItem {
  static let shared = QuickReplyStatusItem()

  private var item: NSStatusItem?
  private weak var store: InboxStore?
  private var defaultsToken: NSObjectProtocol?
  /// Vrai le temps de poser ou de retirer l'élément. Voir `refresh()` : sans
  /// ce garde-fou, l'app déborde sa pile et meurt en quelques millisecondes.
  private var isUpdating = false
  /// Le dernier état appliqué. `UserDefaults.didChangeNotification` se déclenche
  /// pour TOUTE écriture de préférence : on ne refait rien si rien n'a changé.
  private var appliedState: Bool?

  private init() {}

  func configure(store: InboxStore) {
    self.store = store
    if defaultsToken == nil {
      defaultsToken = NotificationCenter.default.addObserver(
        forName: UserDefaults.didChangeNotification, object: nil, queue: .main
      ) { _ in
        MainActor.assumeIsolated { QuickReplyStatusItem.shared.refresh() }
      }
    }
    refresh()
    observeUnread()
  }

  /// Relit le réglage : l'icône paraît, ou s'efface.
  ///
  /// Poser un `NSStatusItem` écrit dans les préférences (AppKit y range la place
  /// de l'icône dans la barre) : la notification de changement revient donc AU
  /// MILIEU de la création, alors que l'élément n'est pas encore rangé dans
  /// `item`. Sans garde-fou, on le recrée à chaque tour — la pile déborde et
  /// l'app meurt (`EXC_BAD_ACCESS`, « excessive recursion ») dès qu'on allume
  /// l'icône dans les Réglages.
  func refresh() {
    guard !isUpdating else { return }
    let wanted = QuickReplyPreferences.showsMenuBarExtra()
    guard wanted != appliedState || (wanted != (item != nil)) else {
      updateLabel()
      return
    }
    isUpdating = true
    appliedState = wanted
    defer { isUpdating = false }
    switch (wanted, item) {
    case (true, nil): install()
    case (false, .some(let existing)):
      NSStatusBar.system.removeStatusItem(existing)
      item = nil
    default: break
    }
    updateLabel()
  }

  private func install() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    menu.addItem(withTitle: "Réponse rapide", action: #selector(toggleQuickReply), keyEquivalent: "")
      .target = self
    menu.addItem(withTitle: "Ouvrir l’inbox", action: #selector(openInbox), keyEquivalent: "")
      .target = self
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quitter Correspondance", action: #selector(quit), keyEquivalent: "")
      .target = self
    item.menu = menu
    self.item = item
  }

  /// Une corbeille, et le nombre de non-lus s'il y en a.
  private func updateLabel() {
    guard let button = item?.button else { return }
    let unread = store?.unreadCount(for: nil) ?? 0
    button.image = NSImage(
      systemSymbolName: unread > 0 ? "tray.full" : "tray",
      accessibilityDescription: "Correspondance"
    )
    button.title = unread > 0 ? " \(unread)" : ""
    button.imagePosition = .imageLeading
  }

  /// Le compteur se remet à jour tout seul quand le magasin bouge.
  private func observeUnread() {
    guard let store else { return }
    withObservationTracking {
      _ = store.unreadCount(for: nil)
    } onChange: {
      Task { @MainActor in
        QuickReplyStatusItem.shared.updateLabel()
        QuickReplyStatusItem.shared.observeUnread()
      }
    }
  }

  @objc private func toggleQuickReply() {
    QuickReplyPanelController.shared.toggle()
  }

  @objc private func openInbox() {
    NSApplication.shared.activate(ignoringOtherApps: true)
    WindowOpener.shared.openInbox()
  }

  @objc private func quit() {
    NSApplication.shared.terminate(nil)
  }
}
