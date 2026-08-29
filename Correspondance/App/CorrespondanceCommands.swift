import SwiftUI

struct CorrespondanceCommands: Commands {
  var store: InboxStore

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("Nouvelle conversation") {
        store.presentNewConversation()
      }
      .keyboardShortcut("n", modifiers: [.command])

      Button("Actualiser l’inbox") {
        Task { @MainActor in
          await store.refresh()
        }
      }
      .keyboardShortcut("r", modifiers: [.command])
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

      Button("Conversation suivante") {
        Task { @MainActor in await store.focusNext() }
      }
      .keyboardShortcut(.downArrow, modifiers: [.command])

      Button("Conversation précédente") {
        Task { @MainActor in await store.focusPrevious() }
      }
      .keyboardShortcut(.upArrow, modifiers: [.command])

      Button("Archiver") {
        Task { @MainActor in await store.archiveSelected() }
      }
      .keyboardShortcut("e", modifiers: [.command])
    }

    CommandGroup(replacing: .appSettings) {
      Button("Réglages…") {
        NotificationCenter.default.post(name: .correspondanceOpenSettings, object: nil)
      }
      .keyboardShortcut(",", modifiers: [.command])
    }
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
