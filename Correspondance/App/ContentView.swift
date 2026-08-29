import SwiftUI

struct ContentView: View {
  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.controlActiveState) private var controlActiveState

  @State private var showSettingsSheet = false
  @State private var columnVisibility: NavigationSplitViewVisibility = .all

  private var theme: WritingTheme { themes.theme }
  private var isFocus: Bool { store.mode == .focus }

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      sidebar
        .navigationSplitViewColumnWidth(
          min: RailMetrics.width + 232,
          ideal: RailMetrics.width + 284,
          max: RailMetrics.width + 400
        )
    } detail: {
      detail
    }
    .navigationSplitViewStyle(.balanced)
    // TODO(macOS 27) : fondu croisé natif entre Focus et Inbox.
    // .navigationTransition(.crossFade)
    .navigationTitle("")
    .toolbar { toolbarContent }
    .toolbarBackground(theme.paper, for: .windowToolbar)
    .correspondanceWindowBackground(theme.paper)
    .tint(theme.accent)
    .correspondanceWindowChrome(theme)
    .onAppear { syncColumns(animated: false) }
    .onChange(of: store.mode) { _, _ in syncColumns(animated: true) }
    .onReceive(NotificationCenter.default.publisher(for: .correspondanceOpenSettings)) { _ in
      showSettingsSheet = true
    }
    .sheet(isPresented: $showSettingsSheet) {
      SettingsView()
        .environment(store)
        .environment(themes)
        .frame(minWidth: 540, minHeight: 460)
    }
    .sheet(isPresented: Bindable(store).isPresentingNewConversation) {
      NewConversationSheet()
        .environment(store)
        .environment(themes)
    }
    .alert(
      "Une difficulté",
      isPresented: Binding(
        get: { store.lastErrorMessage != nil },
        set: { if !$0 { store.lastErrorMessage = nil } }
      )
    ) {
      Button("D’accord", role: .cancel) {
        store.lastErrorMessage = nil
      }
    } message: {
      Text(store.lastErrorMessage ?? "")
    }
  }

  // MARK: - Colonnes

  /// Rail de réseaux + liste : une seule colonne sidebar, matériau système.
  private var sidebar: some View {
    HStack(spacing: 0) {
      NetworkRailView()
      Divider()
        .opacity(controlActiveState == .inactive ? 0.4 : 0.8)
      InboxListPane()
        .frame(maxWidth: .infinity)
    }
  }

  @ViewBuilder
  private var detail: some View {
    if isFocus {
      FocusConversationView()
    } else {
      ThreadView()
    }
  }

  /// Focus = même écran, chrome minimisé : la sidebar s'efface.
  private func syncColumns(animated: Bool) {
    let target: NavigationSplitViewVisibility = isFocus ? .detailOnly : .all
    guard columnVisibility != target else { return }
    if animated, !reduceMotion {
      withAnimation(.smooth(duration: 0.3)) { columnVisibility = target }
    } else {
      columnVisibility = target
    }
  }

  // MARK: - Toolbar native

  @ToolbarContentBuilder
  private var toolbarContent: some ToolbarContent {
    if !isFocus {
      ToolbarItem(placement: .navigation) {
        Button("Nouvelle conversation", systemImage: "square.and.pencil") {
          store.presentNewConversation()
        }
        .help("Nouvelle conversation (⌘N)")
      }
    }

    if isFocus {
      ToolbarItemGroup(placement: .navigation) {
        Button("Conversation précédente", systemImage: "chevron.left") {
          Task { await store.focusPrevious() }
        }
        .disabled(store.focusIndex == nil || store.focusIndex == 0)

        Button("Conversation suivante", systemImage: "chevron.right") {
          Task { await store.focusNext() }
        }
        .disabled({
          guard let index = store.focusIndex else { return true }
          return index >= store.activeQueue.count - 1
        }())
      }
    }

    ToolbarItemGroup(placement: .primaryAction) {
      if store.selectedConversation != nil {
        Button("Archiver", systemImage: "archivebox") {
          Task { await store.archiveSelected() }
        }
        .help("Archiver (⌘E)")
      }

      if !isFocus {
        Button(
          store.isLoading || store.isLiveSyncing ? "Synchronisation…" : "Actualiser",
          systemImage: store.isLoading || store.isLiveSyncing ? "hourglass" : "arrow.clockwise"
        ) {
          Task { await store.refresh() }
        }
        .disabled(store.isLoading)
        .help("Actualiser (⌘R)")
      }

      Button("Focus", systemImage: isFocus ? "rectangle.split.2x1" : "text.aligncenter") {
        store.setMode(isFocus ? .inbox : .focus)
      }
      .help(isFocus ? "Revenir à l’inbox (⌘⇧F)" : "Mode Focus (⌘⇧F)")
    }
  }
}

extension Notification.Name {
  static let correspondanceOpenSettings = Notification.Name("correspondanceOpenSettings")
}
