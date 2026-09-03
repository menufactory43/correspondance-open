import AppKit
import SwiftUI
import CorrespondanceCore

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
  static let bridgeLoginSceneID = "bridge-login"

  private init() {}

  /// L'inbox devant. Si une fenêtre d'inbox existe déjà, c'est **elle** qu'on
  /// ramène : `WindowGroup` en ouvrirait une seconde à chaque `openWindow`, et
  /// c'est ce qu'on voyait au succès d'une connexion — deux inbox côte à côte.
  /// SwiftUI nomme ses fenêtres « <scène>-AppWindow-N » ; on prend la première
  /// visible, sinon n'importe laquelle encore vivante (réduite dans le Dock).
  func openInbox() {
    let inboxWindows = NSApp.windows.filter {
      $0.identifier?.rawValue.hasPrefix(Self.inboxSceneID) == true && $0.level == .normal
    }
    if let window = inboxWindows.first(where: \.isVisible) ?? inboxWindows.first {
      NSApplication.shared.activate(ignoringOtherApps: true)
      if window.isMiniaturized { window.deminiaturize(nil) }
      window.makeKeyAndOrderFront(nil)
      return
    }
    openWindow?(id: Self.inboxSceneID)
  }

  /// La fenêtre de connexion d'un pont : une seule (`Window`), rappelée devant
  /// si elle existe déjà.
  func openBridgeLogin() {
    openWindow?(id: Self.bridgeLoginSceneID)
  }

  func openConversation(_ conversationID: String) {
    openWindow?(id: Self.conversationSceneID, value: conversationID)
  }
}

extension InboxStore {
  // MARK: - Détacher / ramener

  /// ⌘⇧D, menu contextuel de la liste : ce fil s'en va dans sa fenêtre.
  func detach(conversationID: String) {
    restorePinnedDetached(conversationID)
    // La fenêtre existe déjà : `WindowGroup(for:)` la ramène devant sans
    // repasser par `onAppear`. Poser un jeton ici, c'est en laisser un traîner
    // — et la prochaine fenêtre ressuscitée par le système s'en servirait.
    if raiseDetachedWindow(for: conversationID) { return }
    pendingDetachRequests.insert(conversationID)
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

  // MARK: - Réponse rapide (Lot F3)

  /// Le panneau montre ce fil : on le charge s'il est vide, et on le lit — un
  /// panneau sous les yeux vaut une fenêtre au premier plan.
  func quickReplyBecameVisible(_ conversationID: String) {
    setQuickReplyConversationID(conversationID)
    let session = session(for: conversationID)
    Task { @MainActor in
      if session.messages.isEmpty { await self.loadMessages(into: session) }
      self.markDetachedThreadRead(conversationID)
    }
  }

  func quickReplyClosed() {
    setQuickReplyConversationID(nil)
    pruneSessionsAfterQuickReply()
  }

  /// Envoyer depuis une notification, sans ouvrir quoi que ce soit.
  func sendFromNotification(conversationID: String, text: String) async {
    let rowID = displayRowID(for: conversationID)
    let session = session(for: rowID)
    if session.messages.isEmpty { await loadMessages(into: session) }
    session.draftText = text
    await send(session: session)
  }

  /// La recherche du mini-sélecteur (⌘K) : la même que celle de la liste.
  func quickReplyMatches(_ query: String) -> [Conversation] {
    quickSearch(query)
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
