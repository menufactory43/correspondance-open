import SwiftUI
import CorrespondanceCore
import CorrespondanceUI

struct ContentView: View {
  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.controlActiveState) private var controlActiveState
  @Environment(\.openWindow) private var openWindow

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
    // Focus = chrome fantôme : la barre d'outils s'efface au repos, et revient
    // quand la souris monte en haut de la fenêtre ou qu'on remonte le fil.
    // TODO(macOS 27) : `toolbarMinimizeBehavior(.onScrollDown)` remplacera
    // cette lisière par le comportement natif.
    .correspondanceToolbarVisibility(focusToolbarVisibility)
    .overlay(alignment: .top) {
      if isFocus {
        HoverZone { hovering in
          withAnimation(chromeAnimation) { store.setFocusChromeHovered(hovering) }
        }
        // Une vue AppKit n'a pas de taille idéale : sans cadre explicite la
        // lisière ferait zéro pixel de large et n'attraperait jamais la souris.
        .frame(maxWidth: .infinity, maxHeight: LayoutMetrics.focusChromeHoverHeight)
        .accessibilityHidden(true)
      }
    }
    // La barre d'outils ne peint RIEN : le fond continu vient de la sidebar
    // (à gauche) et du papier de la fenêtre (à droite). Cf. WindowChrome.swift.
    .correspondanceTransparentToolbar()
    .correspondanceWindowBackground(theme.paper)
    .tint(theme.accent)
    .correspondanceWindowChrome(theme)
    .onAppear {
      syncColumns(animated: false)
      // Le délégué d'application n'a pas d'environnement : on lui laisse
      // l'action d'ouverture pendant qu'une fenêtre existe encore.
      WindowOpener.shared.openWindow = openWindow
      // Le panneau de réponse rapide emprunte les deux mêmes sources de vérité,
      // et le raccourci global se pose avec elles. Mais poser un `NSStatusItem`
      // et armer un raccourci Carbon parlent au serveur de fenêtres : rien qui
      // mérite de retarder la première frame. Tâche non structurée : fermer
      // l'inbox dans la foulée ne doit pas laisser l'icône de barre orpheline.
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(300))
        QuickReplyPanelController.shared.configure(store: store, themes: themes)
        QuickReplyStatusItem.shared.configure(store: store)
      }
    }
    .onChange(of: store.mode) { _, _ in syncColumns(animated: true) }
    .onChange(of: store.selectedConversationID) { _, _ in store.resetFocusChrome() }
    .sheet(isPresented: Bindable(store).isPresentingNewGroup) {
      NewGroupSheet()
        .environment(store)
        .environment(themes)
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

  /// Hors Focus la barre reste franche. En Focus elle n'existe qu'au rappel.
  private var focusToolbarVisibility: Visibility {
    guard isFocus else { return .automatic }
    return store.isFocusChromeRevealed ? .visible : .hidden
  }

  private var chromeAnimation: Animation? {
    reduceMotion ? nil : .smooth(duration: 0.25)
  }

  // MARK: - Colonnes

  /// Rail de réseaux + liste : une seule colonne sidebar, matériau système
  /// teinté par le thème, continu du haut de la fenêtre jusqu'en bas.
  private var sidebar: some View {
    HStack(spacing: 0) {
      NetworkRailView()
      Divider()
        .opacity(controlActiveState == .inactive ? 0.4 : 0.8)
      InboxListPane()
        .frame(maxWidth: .infinity)
    }
    .background { SidebarSurface(theme: theme) }
    // « Nouvelle conversation » appartient à la LISTE, pas au fil : posée sur
    // la colonne latérale, elle s'aligne avec elle au lieu de flotter contre
    // le bord gauche du détail. C'est la place que lui donnent Mail et Messages.
    .toolbar {
      if !isFocus {
        ToolbarItem(placement: .primaryAction) {
          Button {
            store.presentNewConversation()
          } label: {
            // Même gabarit que le bouton de colonne posé par le split view.
            // Le décalage n'est pas un caprice : SF Symbols centre la boîte
            // ENTIÈRE du glyphe, or « square.and.pencil » sort sa mine en
            // haut à droite. Son carré descendait donc d'un point et demi
            // sous le rectangle voisin. On aligne les deux carrés, pas les
            // deux boîtes — c'est ce que l'œil compare.
            Image(systemName: "square.and.pencil")
              .font(.system(size: 14, weight: .regular))
              .offset(y: -1.5)
              .frame(width: 28, height: 22)
          }
          .help("Nouvelle conversation (⌘N)")
          .accessibilityLabel("Nouvelle conversation")
        }
      }
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
    if !isFocus, let conversation = store.selectedConversation {
      ToolbarItem(placement: .principal) {
        ConversationPillHeader(conversation: conversation, theme: theme)
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
