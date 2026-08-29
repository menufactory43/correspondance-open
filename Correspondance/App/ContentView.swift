import SwiftUI

struct ContentView: View {
  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes
  @State private var showSettingsSheet = false
  @State private var chromeRevealed = false

  private var theme: WritingTheme { themes.theme }
  private var isFocus: Bool { store.mode == .focus }
  private var showsModeChrome: Bool { chromeRevealed && !store.isComposerFocused }

  var body: some View {
    Group {
      switch store.mode {
      case .focus:
        FocusConversationView()
      case .inbox:
        inboxSplit
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background((isFocus ? theme.paper : theme.room).ignoresSafeArea())
    .overlay(alignment: .topTrailing) {
      modeChrome
        .opacity(isFocus ? (showsModeChrome ? 1 : 0) : 1)
        .animation(.easeOut(duration: 0.15), value: showsModeChrome)
        .animation(.easeOut(duration: 0.15), value: isFocus)
        .allowsHitTesting(!isFocus || showsModeChrome)
    }
    .overlay(alignment: .topTrailing) {
      if isFocus {
        Color.clear
          .frame(width: 220, height: 56)
          .contentShape(Rectangle())
          .onHover { hovering in
            chromeRevealed = hovering && !store.isComposerFocused
          }
          .allowsHitTesting(!store.isComposerFocused)
      }
    }
    .tint(theme.accent)
    .correspondanceWindowChrome(
      theme,
      sidebarVisible: store.mode == .inbox,
      zenMode: isFocus
    )
    .onReceive(NotificationCenter.default.publisher(for: .correspondanceOpenSettings)) { _ in
      showSettingsSheet = true
    }
    .onChange(of: store.mode) { _, newMode in
      chromeRevealed = newMode != .focus
    }
    .onChange(of: store.isComposerFocused) { _, focused in
      if focused { chromeRevealed = false }
    }
    .sheet(isPresented: $showSettingsSheet) {
      SettingsView()
        .environment(store)
        .environment(themes)
        .frame(minWidth: 540, minHeight: 460)
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

  /// Vue Beeper : sidebar liste + fil.
  private var inboxSplit: some View {
    HStack(spacing: 0) {
      InboxListPane()
        .frame(width: store.isSidebarCompact
          ? LayoutMetrics.sidebarCompactWidth
          : LayoutMetrics.sidebarWidth + 40)
        .frame(maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.22), value: store.isSidebarCompact)

      Rectangle()
        .fill(theme.edge.opacity(0.55))
        .frame(width: 1)
        .frame(maxHeight: .infinity)
        .ignoresSafeArea(edges: .top)

      ThreadView(showsHeader: true)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private var modeChrome: some View {
    HStack(spacing: Spacing.xs) {
      modeToggle
      SoftToolButton(
        systemImage: (store.isLoading || store.isLiveSyncing) ? "hourglass" : "arrow.clockwise",
        helpText: store.isLiveSyncing ? "Sync live…" : (store.isLoading ? "Actualisation…" : "Actualiser"),
        isDisabled: store.isLoading
      ) {
        Task { await store.refresh() }
      }
    }
    .padding(.trailing, Spacing.md)
    .padding(.top, 10)
  }

  private var modeToggle: some View {
    HStack(spacing: 2) {
      ForEach(InboxMode.allCases) { mode in
        Button {
          store.setMode(mode)
        } label: {
          Image(systemName: mode.systemImage)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(store.mode == mode ? theme.accent : theme.inkTertiary)
            .frame(width: 28, height: 28)
            .background(
              RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(store.mode == mode ? theme.selection : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .help(mode == .focus ? "Focus (⌘1)" : "Inbox avec sidebar (⌘2)")
      }
    }
    .padding(2)
    .background(theme.paperSecondary.opacity(0.92), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}

extension Notification.Name {
  static let correspondanceOpenSettings = Notification.Name("correspondanceOpenSettings")
}
