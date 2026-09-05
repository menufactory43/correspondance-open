import CorrespondanceCore
import CorrespondanceUI
import SwiftUI

/// Les onglets de l'iPhone. Inbox par défaut (décision 9), Focus à un tap,
/// dans la barre d'onglets du système ; la recherche est l'onglet de rôle
/// `search`, celui qu'iOS pose seul dans sa bulle à droite.
enum PhoneMode: String, CaseIterable, Identifiable, Sendable {
  case inbox
  case archive
  case focus
  case search

  var id: String { rawValue }

  var labelFR: String {
    switch self {
    case .inbox: "Inbox"
    case .archive: "Archive"
    case .focus: "Focus"
    case .search: "Rechercher"
    }
  }

  var systemImage: String {
    switch self {
    case .inbox: "tray.full"
    case .archive: "archivebox"
    case .focus: "rectangle.portrait.and.arrow.right"
    case .search: "magnifyingglass"
    }
  }

  var scope: InboxScope? {
    switch self {
    case .inbox: .inbox
    case .archive: .archive
    case .focus, .search: nil
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
  @Environment(PushRegistration.self) private var push

  @State private var mode: PhoneMode = .inbox
  // `.automatic` replie la liste sur un iPad en portrait : les deux colonnes
  // sont justement ce qu'on veut en regular (décision 9). En compact, cette
  // valeur n'a aucun effet — la pile reste une pile.
  @State private var columns = NavigationSplitViewVisibility.doubleColumn

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

  /// L'attente ne se dit qu'à partir d'une seconde : un lancement ordinaire
  /// n'atteint jamais ce cap, et le papier nu vaut mieux qu'un mot qui clignote.
  @State private var loadingIsLong = false

  private var loading: some View {
    VStack(spacing: Spacing.sm) {
      if loadingIsLong {
        ProgressView()
        Text("Connexion au Relais…")
          .font(Typography.emptyState(themes.typeface))
          .foregroundStyle(theme.inkSecondary)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(theme.paper.ignoresSafeArea())
    .task {
      try? await Task.sleep(for: .seconds(1))
      loadingIsLong = true
    }
  }

  @ViewBuilder
  private var connected: some View {
    @Bindable var store = store
    TabView(selection: $mode) {
      Tab(PhoneMode.inbox.labelFR, systemImage: PhoneMode.inbox.systemImage, value: .inbox) {
        split(scope: .inbox)
      }
      .badge(unreadCount)

      Tab(PhoneMode.archive.labelFR, systemImage: PhoneMode.archive.systemImage, value: .archive) {
        split(scope: .archive)
      }

      Tab(PhoneMode.focus.labelFR, systemImage: PhoneMode.focus.systemImage, value: .focus) {
        FocusView()
      }

      Tab(value: .search, role: .search) {
        SearchSheet(embedded: true) { conversationID in
          store.selectedConversationID = conversationID
          mode = .inbox
        }
      }
    }
    .tabBarMinimizedOnScroll()
    .tint(theme.accent)
    .onChange(of: mode, initial: true) { _, new in
      // La portée du store suit l'onglet : c'est elle que la recherche et
      // les feuilles lisent.
      if let scope = new.scope { store.scope = scope }
    }
  }

  /// Le badge de l'onglet Inbox : ce qui n'est pas lu dans la file.
  private var unreadCount: Int {
    store.conversations(in: .inbox).reduce(0) { $0 + $1.unreadCount }
  }

  /// Liste puis fil en compact, côte à côte en regular — un split view par
  /// portée, chacun dans son onglet.
  private func split(scope: InboxScope) -> some View {
    @Bindable var store = store
    return NavigationSplitView(columnVisibility: $columns) {
      InboxListView(scope: scope)
        .navigationSplitViewColumnWidth(min: 320, ideal: 360, max: 460)
    } detail: {
      // Pas de `NavigationStack` ici : la colonne de détail en a déjà un, et
      // en compact c'est lui qui reçoit la poussée quand la sélection change.
      // En imbriquer un second faisait taper dans le vide — la conversation
      // se sélectionnait, mais rien ne s'ouvrait.
      if let id = store.selectedConversationID, store.conversation(id) != nil {
        ThreadView(conversationID: id)
      } else {
        noSelection
      }
    }
    .navigationSplitViewStyle(.balanced)
  }

  /// En démonstration, l'écran demandé s'ouvre seul — les captures n'ont pas
  /// de doigt à leur disposition.
  private func openDemoScreenIfRequested() {
    guard store.isDemo else { return }
    // Une adresse passée au lancement vaut session : les Réglages ont alors
    // quelque chose à montrer, et l'extension quelque chose à lire.
    DemoRelay.seedSharedCredentials()
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
    case .fil:
      // Le fil le plus fourni : c'est celui qui montre le regroupement, les
      // réactions et les citations sur une seule capture.
      store.selectedConversationID = store.visibleConversations
        .max { store.visibleMessages($0.id).count < store.visibleMessages($1.id).count }?.id
    case .focus:
      mode = .focus
    case .vide:
      mode = .focus
      store.state.archived = Set(store.conversations.map(\.id))
      store.focusConversationID = nil
    case .medias:
      // Le fil le plus illustré : c'est lui qui porte la mosaïque et le partage.
      store.selectedConversationID = store.visibleConversations
        .max { photoCount($0) < photoCount($1) }?.id
    case .nouvelle, .recherche, .reglages:
      // Ces trois-là s'ouvrent en feuille, depuis l'inbox : c'est elle qui
      // les porte (`InboxListView.openDemoSheetIfRequested`).
      break
    case .plusTard:
      // Le sélecteur « Quand ? » a besoin d'un brouillon sous la main :
      // on ouvre le fil qui en porte un (`ThreadComposer` fait le reste).
      store.selectedConversationID = store.visibleConversations
        .first { !store.draftText($0.id).isEmpty }?.id
        ?? store.visibleConversations.first?.id
    case .notification:
      // Le seul écran de démonstration qui ne se photographie pas : il arme le
      // push. La capture, elle, se prend sur l'écran d'accueil.
      Task {
        await push.requestAuthorizationIfNeeded()
        guard let reference = DemoRelay.demoPushReference else { return }
        await push.presentDemoNotification(reference: reference, after: 8)
      }
    }
  }

  /// Le nombre de photos d'un fil — de quoi choisir celui qu'on photographie.
  private func photoCount(_ conversation: Conversation) -> Int {
    store.visibleMessages(conversation.id).reduce(0) { $0 + $1.attachments.count }
  }

  private var noSelection: some View {
    VStack(spacing: Spacing.sm) {
      Image(systemName: "tray")
        .font(.system(size: 32, weight: .light))
        .foregroundStyle(theme.inkTertiary)
      Text("Choisis une conversation")
        .font(Typography.emptyState(themes.typeface))
        .foregroundStyle(theme.inkSecondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(theme.paper.ignoresSafeArea())
  }
}

extension View {
  /// La barre d'onglets se replie sur l'onglet courant en défilant — le
  /// comportement d'iOS 26. Avant, la barre reste : rien à replier.
  @ViewBuilder
  func tabBarMinimizedOnScroll() -> some View {
    if #available(iOS 26.0, *) {
      tabBarMinimizeBehavior(.onScrollDown)
    } else {
      self
    }
  }
}
