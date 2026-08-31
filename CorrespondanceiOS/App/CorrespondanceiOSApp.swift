import CorrespondanceCore
import CorrespondanceUI
import SwiftUI

@main
struct CorrespondanceiOSApp: App {
  @State private var store = RelayStore(demo: DemoRelay.isRequested)
  @State private var themes = ThemePreferences()

  var body: some Scene {
    WindowGroup {
      RootView()
        .environment(store)
        .environment(themes)
        // Le chrome du système suit le thème : un thème sombre sur une barre
        // d'état claire, c'est la moitié de l'écran qui jure.
        .preferredColorScheme(themes.theme.isDark ? .dark : .light)
        .tint(themes.theme.accent)
        .task { await store.start() }
    }
  }
}
