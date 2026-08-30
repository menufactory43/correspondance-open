import SwiftUI

struct CorrespondanceCommands: Commands {
  var store: InboxStore

  private var archiveTitle: String {
    guard let id = store.selectedConversationID else { return "Archiver" }
    return store.isArchived(id) ? "Désarchiver" : "Archiver"
  }

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("Nouvelle conversation") {
        store.presentNewConversation()
      }
      .keyboardShortcut("n", modifiers: [.command])

      // ⌘R appartient à « Répondre en citant » (comme Beeper) : l'actualisation
      // manuelle, rare depuis que les trois réseaux syncent tout seuls, passe en ⌘⇧R.
      Button("Actualiser l’inbox") {
        Task { @MainActor in
          await store.refresh()
        }
      }
      .keyboardShortcut("r", modifiers: [.command, .shift])
    }

    CommandMenu("Inbox") {
      Button("Mode Focus") {
        store.setMode(store.mode == .focus ? .inbox : .focus)
      }
      .keyboardShortcut("f", modifiers: [.command, .shift])

      Divider()

      // Rail de réseaux : ⌘1 = Tous, puis l'ordre de `MessageNetwork`.
      ForEach(Array(NetworkRailView.slots.enumerated()), id: \.offset) { index, network in
        NetworkFilterCommand(store: store, network: network, position: index + 1)
      }

      Divider()

      Button("Répondre en citant") {
        store.replyToSelectedMessage()
      }
      .keyboardShortcut("r", modifiers: [.command])

      // ⌘⇧R est pris par l'actualisation : le « quick react » de Beeper passe en ⌘⌥R.
      Button("Réagir 👍") {
        Task { @MainActor in await store.quickReactToSelectedMessage() }
      }
      .keyboardShortcut("r", modifiers: [.command, .option])

      Button("Rechercher dans le fil") {
        store.toggleThreadSearch()
      }
      .keyboardShortcut("f", modifiers: [.command])

      // Même touche que Beeper (SCHEDULE_MESSAGE ⌘⇧L).
      Button("Envoyer plus tard…") {
        store.toggleSendLaterPicker()
      }
      .keyboardShortcut("l", modifiers: [.command, .shift])

      Divider()

      Button("Conversation suivante") {
        Task { @MainActor in await store.focusNext() }
      }
      .keyboardShortcut(.downArrow, modifiers: [.command])

      Button("Conversation précédente") {
        Task { @MainActor in await store.focusPrevious() }
      }
      .keyboardShortcut(.upArrow, modifiers: [.command])

      Button(archiveTitle) {
        Task { @MainActor in
          guard let id = store.selectedConversationID else { return }
          await store.toggleArchived(conversationID: id)
        }
      }
      .keyboardShortcut("e", modifiers: [.command])

      Button(store.isShowingArchived ? "Retour à l’inbox" : "Voir les archivés") {
        store.setShowingArchived(!store.isShowingArchived)
      }
      .keyboardShortcut("e", modifiers: [.command, .shift])

      Button(store.isShowingScheduled ? "Retour à l’inbox" : "Voir les programmés") {
        store.setShowingScheduled(!store.isShowingScheduled)
      }
      .disabled(!store.isShowingScheduled && store.scheduledMessages.isEmpty)

      // Le geste Focus : je réponds, j'archive, je passe au suivant.
      // Commande de menu plutôt que `onKeyPress` : le raccourci vaut alors dans
      // le composer de l'Inbox *et* dans l'éditeur pleine page du mode Focus.
      Button("Envoyer et archiver") {
        Task { @MainActor in await store.sendDraftAndArchive() }
      }
      .keyboardShortcut(.return, modifiers: [.command])
    }

    // Rien ici pour les Réglages : la scène `Settings` pose elle-même son
    // « Settings… » (⌘,) qui ouvre la VRAIE fenêtre. Un `CommandGroup` de plus
    // ne la remplacerait pas, il doublerait l'entrée du menu.
  }
}

/// Un cran du rail dans le menu. Au-delà de ⌘9 on n'attribue plus de raccourci.
private struct NetworkFilterCommand: View {
  let store: InboxStore
  let network: MessageNetwork?
  let position: Int

  var body: some View {
    Button(network?.labelFR ?? "Tous les réseaux") {
      store.setNetworkFilter(network)
    }
    .keyboardShortcut(shortcut)
  }

  private var shortcut: KeyboardShortcut? {
    guard (1...9).contains(position), let digit = "\(position)".first else { return nil }
    return KeyboardShortcut(KeyEquivalent(digit), modifiers: [.command])
  }
}
