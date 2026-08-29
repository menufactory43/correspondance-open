import SwiftUI

@main
struct CorrespondanceApp: App {
  @State private var store = InboxStore()
  @State private var themes = ThemePreferences()

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environment(store)
        .environment(themes)
        .task {
          // Fenêtre visible → puis demande Contacts (sinon pas dans Confidentialité).
          try? await Task.sleep(for: .milliseconds(500))
          await store.start()
        }
    }
    .defaultSize(width: 1100, height: 760)
    .commands { CorrespondanceCommands(store: store) }

    Settings {
      SettingsView()
        .environment(store)
        .environment(themes)
    }
  }
}
