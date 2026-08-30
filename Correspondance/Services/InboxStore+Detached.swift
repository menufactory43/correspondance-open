import AppKit
import SwiftUI

/// L'action `openWindow`, gardée sous la main.
///
/// Un délégué d'application n'a pas d'environnement SwiftUI : quand le Dock
/// redemande l'inbox alors que plus aucune fenêtre n'est ouverte, il n'y a plus
/// une seule vue vivante pour l'ouvrir. On garde donc l'action, cueillie dans
/// l'environnement pendant qu'une fenêtre existait — elle reste valable pour
/// toute la vie de l'app.
@MainActor
final class WindowOpener {
  static let shared = WindowOpener()

  var openWindow: OpenWindowAction?

  /// Identifiants des scènes. Les mêmes chaînes qu'en face, dans `CorrespondanceApp`.
  static let inboxSceneID = "inbox"
  static let conversationSceneID = "conversation"

  private init() {}

  func openInbox() {
    openWindow?(id: Self.inboxSceneID)
  }

  func openConversation(_ conversationID: String) {
    openWindow?(id: Self.conversationSceneID, value: conversationID)
  }
}

extension InboxStore {
  // MARK: - Détacher / ramener

  /// ⌘⇧D, menu contextuel de la liste : ce fil s'en va dans sa fenêtre.
  func detach(conversationID: String) {
    pendingDetachRequests.insert(conversationID)
    restorePinnedDetached(conversationID)
    WindowOpener.shared.openConversation(conversationID)
  }

  /// La scène s'ouvre : est-ce bien nous qui l'avons demandée ? Sinon c'est la
  /// restauration système qui la ressuscite au lancement, et elle n'a rien à
  /// faire là — la fenêtre détachée ne s'ouvre que sur geste.
  func claimDetachRequest(_ conversationID: String) -> Bool {
    pendingDetachRequests.remove(conversationID) != nil
  }

  /// « Ramener dans l'inbox » : le fil retourne sous les yeux de la liste.
  func reattach(conversationID: String) async {
    detachedWindows[conversationID]?.close()
    WindowOpener.shared.openInbox()
    await select(conversationID)
  }

  // MARK: - Fenêtres

  func registerDetachedWindow(_ window: NSWindow, for conversationID: String) {
    detachedWindows[conversationID] = window
    noteDetached(conversationID)
  }

  func unregisterDetachedWindow(for conversationID: String) {
    detachedWindows.removeValue(forKey: conversationID)
    noteReattached(conversationID)
  }

  /// Ce fil a-t-il une fenêtre à lui ?
  func isDetached(_ conversationID: String) -> Bool {
    detachedConversationIDs.contains(conversationID)
  }

  /// Amener au premier plan la fenêtre d'un fil, si elle existe.
  @discardableResult
  func raiseDetachedWindow(for conversationID: String) -> Bool {
    guard let window = detachedWindows[conversationID] else { return false }
    NSApplication.shared.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    return true
  }

  /// Une fenêtre détachée passe devant : le fil est lu, comme dans l'inbox.
  func detachedWindowBecameKey(_ conversationID: String) {
    noteDetachedWindowFront(conversationID)
    markDetachedThreadRead(conversationID)
  }

  func detachedWindowResignedKey(_ conversationID: String) {
    if frontDetachedConversationID == conversationID { noteDetachedWindowFront(nil) }
  }

  /// Lire, c'est le dire au réseau : même geste que l'ouverture d'un fil dans
  /// la liste, accusé compris.
  func markDetachedThreadRead(_ conversationID: String) {
    guard conversations.contains(where: { $0.id == conversationID }) else { return }
    clearUnreadForDetached(conversationID)
    Task { @MainActor in await self.sendReadReceipt(conversationID: conversationID) }
  }

  // MARK: - Épingle (Lot F2)

  func isPinnedDetached(_ conversationID: String) -> Bool {
    pinnedDetachedIDs.contains(conversationID)
  }

  /// ⌘⌥P : la fenêtre reste au-dessus, et s'en souvient.
  func setPinnedDetached(_ pinned: Bool, for conversationID: String) {
    if pinned {
      pinnedDetachedIDs.insert(conversationID)
    } else {
      pinnedDetachedIDs.remove(conversationID)
    }
    DetachedWindowState.setPinned(pinned, for: conversationID)
  }

  func togglePinnedDetached(_ conversationID: String) {
    setPinnedDetached(!isPinnedDetached(conversationID), for: conversationID)
  }

  /// Relit l'épingle du disque à l'ouverture d'une fenêtre.
  func restorePinnedDetached(_ conversationID: String) {
    if DetachedWindowState.isPinned(conversationID) {
      pinnedDetachedIDs.insert(conversationID)
    } else {
      pinnedDetachedIDs.remove(conversationID)
    }
  }
}
