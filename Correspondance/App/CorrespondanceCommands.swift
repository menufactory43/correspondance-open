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
        store.setMode(.focus)
      }
      .keyboardShortcut("1", modifiers: [.command])

      Button("Mode Inbox") {
        store.setMode(.inbox)
      }
      .keyboardShortcut("2", modifiers: [.command])

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
