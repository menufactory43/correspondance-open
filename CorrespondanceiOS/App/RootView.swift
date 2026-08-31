import CorrespondanceCore
import CorrespondanceUI
import SwiftUI

/// Le mode d'affichage de l'iPhone. Inbox par défaut (décision 9), Focus à un
/// geste de là, dans la pilule de la barre du bas.
enum PhoneMode: String, CaseIterable, Identifiable, Sendable {
  case inbox
  case archive
  case focus

  var id: String { rawValue }

  var labelFR: String {
    switch self {
    case .inbox: "Inbox"
    case .archive: "Archive"
    case .focus: "Focus"
    }
  }

  var systemImage: String {
    switch self {
    case .inbox: "tray.full"
    case .archive: "archivebox"
    case .focus: "rectangle.portrait.and.arrow.right"
    }
  }

  var scope: InboxScope? {
    switch self {
    case .inbox: .inbox
    case .archive: .archive
    case .focus: nil
    }
  }
}

/// La coquille adaptative.
///
/// `NavigationSplitView` fait les deux mises en page d'un seul modèle : en
/// compact (iPhone) il empile liste puis fil, en regular (iPad, Fold déplié) il
/// les pose côte à côte. Ce qui survit à la bascule — conversation ouverte,
/// brouillon, filtre — vit dans `RelayStore`, jamais dans la vue : c'est la
/// seule façon de ne rien perdre en tournant l'appareil.
struct RootView: View {
  @Environment(RelayStore.self) private var store
  @Environment(ThemePreferences.self) private var themes

  @State private var mode: PhoneMode = .inbox

  private var theme: WritingTheme { themes.theme }

  var body: some View {
    Group {
      switch store.session {
      case .unknown:
        loading
      case .disconnected, .connecting:
        RelayLoginView()
      case .connected:
        connected
      }
    }
    .background(theme.paper.ignoresSafeArea())
    .animation(.easeInOut(duration: 0.18), value: store.session)
    .task { openDemoScreenIfRequested() }
  }

  private var loading: some View {
    VStack(spacing: Spacing.sm) {
      ProgressView()
      Text("Connexion au Relais…")
        .font(Typography.emptyState(themes.typeface))
        .foregroundStyle(theme.inkSecondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(theme.paper.ignoresSafeArea())
  }

  /// La liste et le fil arrivent aux étapes suivantes ; pour l'instant, se
  /// connecter et savoir qu'on l'est suffit à prouver la chaîne.
  private var connected: some View {
    VStack(spacing: Spacing.sm) {
      Text("Connecté au Relais")
        .font(Typography.letterHeading(themes.typeface, 22))
        .foregroundStyle(theme.ink)
      Text("\(store.conversations.count) conversation(s)")
        .font(Typography.emptyState(themes.typeface))
        .foregroundStyle(theme.inkSecondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  /// En démonstration, l'écran demandé s'ouvre seul — les captures n'ont pas
  /// de doigt à leur disposition.
  private func openDemoScreenIfRequested() {
    guard store.isDemo else { return }
    switch DemoRelay.requestedScreen {
    case .inbox:
      break
    case .erreur:
      Task {
        await store.connect(
          homeserver: DemoRelay.unreachableHomeserver,
          user: "meffysto",
          password: "mauvais"
        )
      }
    case .fil, .focus, .vide:
      break
    }
  }

}
