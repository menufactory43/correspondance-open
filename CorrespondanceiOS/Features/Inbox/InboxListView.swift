import CorrespondanceCore
import CorrespondanceUI
import SwiftUI

/// L'écran par défaut de l'iPhone (décision 9).
///
/// Le titre à gauche porte le menu de portée : Inbox, Archive, puis un réseau.
/// La barre flottante du bas porte le filtre, la pilule de mode et la
/// recherche. Entre les deux, la file, épinglées en tête.
struct InboxListView: View {
  @Binding var mode: PhoneMode

  @Environment(RelayStore.self) private var store
  @Environment(ThemePreferences.self) private var themes

  private var theme: WritingTheme { themes.theme }
  private var typeface: WritingTypeface { themes.typeface }

  var body: some View {
    @Bindable var store = store
    let list = store.visibleConversations
    let sections = InboxOrdering.sections(list, state: store.viewState)

    return ZStack(alignment: .bottom) {
      Group {
        if list.isEmpty {
          emptyState
        } else {
          List(selection: $store.selectedConversationID) {
            if !sections.pinned.isEmpty {
              Section {
                ForEach(sections.pinned) { row($0) }
              } header: {
                sectionHeader("Épinglées")
              }
            }
            Section {
              ForEach(sections.others) { row($0) }
            } header: {
              if !sections.pinned.isEmpty { sectionHeader(store.scope.labelFR) }
            }
            // De quoi respirer sous la barre flottante.
            Color.clear
              .frame(height: 76)
              .listRowSeparator(.hidden)
              .listRowBackground(Color.clear)
          }
          .listStyle(.plain)
          .scrollContentBackground(.hidden)
          .environment(\.defaultMinListRowHeight, 0)
        }
      }
      .background(theme.paper.ignoresSafeArea())

      InboxFloatingBar(mode: $mode)
        .padding(.horizontal, Spacing.md)
        .padding(.bottom, Spacing.xs)
    }
    .navigationTitle("")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarLeading) { scopeMenu }
      ToolbarItem(placement: .topBarTrailing) { newConversationButton }
    }
    .toolbarBackground(theme.paper, for: .navigationBar)
    .safeAreaInset(edge: .top, spacing: 0) { syncBanner }
  }

  // MARK: - Lignes

  @ViewBuilder
  private func row(_ conversation: Conversation) -> some View {
    ConversationRow(
      conversation: conversation,
      theme: theme,
      typeface: typeface,
      isPinned: store.isPinned(conversation.id),
      isMuted: store.isMuted(conversation.id),
      draft: store.draftText(conversation.id).trimmingCharacters(in: .whitespacesAndNewlines)
    )
    .listRowInsets(EdgeInsets())
    .listRowSeparatorTint(theme.edge.opacity(0.5))
    .listRowBackground(
      store.selectedConversationID == conversation.id ? theme.selection : Color.clear
    )
    .tag(conversation.id)
    .onTapGesture { open(conversation.id) }
    // Balayage à droite : archiver — le geste qui vide la file.
    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
      Button {
        store.toggleArchived(conversation.id)
      } label: {
        Label(
          store.isArchived(conversation.id) ? "Désarchiver" : "Archiver",
          systemImage: store.isArchived(conversation.id) ? "tray.and.arrow.up" : "archivebox"
        )
      }
      .tint(theme.accent)
    }
    // Balayage à gauche : épingler et muet, les deux autres décisions.
    .swipeActions(edge: .leading, allowsFullSwipe: false) {
      Button {
        store.togglePinned(conversation.id)
      } label: {
        Label(
          store.isPinned(conversation.id) ? "Désépingler" : "Épingler",
          systemImage: store.isPinned(conversation.id) ? "pin.slash" : "pin"
        )
      }
      .tint(theme.accentSoft)

      Button {
        store.toggleMuted(conversation.id)
      } label: {
        Label(
          store.isMuted(conversation.id) ? "Réactiver" : "Muet",
          systemImage: store.isMuted(conversation.id) ? "bell" : "bell.slash"
        )
      }
      .tint(theme.inkTertiary)
    }
  }

  private func open(_ id: String) {
    store.selectedConversationID = id
    Task { await store.open(conversationID: id) }
  }

  private func sectionHeader(_ title: String) -> some View {
    Text(title.uppercased())
      .font(Typography.sidebarSection(typeface))
      .kerning(0.6)
      .foregroundStyle(theme.inkTertiary)
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, 4)
      .frame(maxWidth: .infinity, alignment: .leading)
      .listRowInsets(EdgeInsets())
      .background(theme.paper)
  }

  // MARK: - Chrome

  private var scopeMenu: some View {
    Menu {
      Picker("Portée", selection: Binding(
        get: { store.scope },
        set: { store.scope = $0 }
      )) {
        ForEach(InboxScope.allCases) { scope in
          Label(scope.labelFR, systemImage: scope.systemImage).tag(scope)
        }
      }
      Divider()
      Picker("Réseau", selection: Binding(
        get: { store.networkFilter },
        set: { store.networkFilter = $0 }
      )) {
        Label("Tous les réseaux", systemImage: "square.stack.3d.up").tag(MessageNetwork?.none)
        ForEach(store.networksInUse) { network in
          Label(network.labelFR, systemImage: network.systemImage)
            .tag(MessageNetwork?.some(network))
        }
      }
    } label: {
      HStack(spacing: 4) {
        Text(store.networkFilter?.labelFR ?? store.scope.labelFR)
          .font(Typography.letterHeading(typeface, 22))
          .foregroundStyle(theme.ink)
        Image(systemName: "chevron.down")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(theme.inkTertiary)
      }
    }
    .accessibilityLabel("Portée : \(store.networkFilter?.labelFR ?? store.scope.labelFR). Changer.")
  }

  private var newConversationButton: some View {
    Button {
      // Phase C2 : puces réseau + `startBridgeChat`.
    } label: {
      Image(systemName: "square.and.pencil")
        .font(.system(size: 17, weight: .medium))
    }
    .disabled(true)
    .accessibilityLabel("Nouvelle conversation (bientôt)")
  }

  @ViewBuilder
  private var syncBanner: some View {
    if let error = store.syncError {
      HStack(spacing: 6) {
        Image(systemName: "antenna.radiowaves.left.and.right.slash")
        Text(error)
          .lineLimit(2)
        Spacer(minLength: 0)
      }
      .font(Typography.meta(typeface))
      .foregroundStyle(theme.ink)
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, 6)
      .background(theme.accentSoft.opacity(0.2))
      .accessibilityLabel("Relais injoignable. \(error)")
    }
  }

  // MARK: - Vide

  private var emptyState: some View {
    VStack(spacing: Spacing.sm) {
      Image(systemName: emptyIcon)
        .font(.system(size: 34, weight: .light))
        .foregroundStyle(theme.inkTertiary)
      Text(emptyTitle)
        .font(Typography.emptyState(typeface))
        .foregroundStyle(theme.inkSecondary)
        .multilineTextAlignment(.center)
      if store.syncError != nil {
        Text("Le Relais ne répond pas. Vérifie Tailscale.")
          .font(Typography.meta(typeface))
          .foregroundStyle(theme.inkTertiary)
      }
    }
    .padding(Spacing.lg)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var emptyIcon: String {
    if store.filter != .all { return store.filter.systemImage }
    return store.scope == .archive ? "archivebox" : "tray"
  }

  private var emptyTitle: String {
    if store.filter != .all { return "Rien en « \(store.filter.labelFR) »" }
    if let network = store.networkFilter { return "Aucune conversation \(network.labelFR)" }
    return store.scope == .archive ? "L'archive est vide" : "Vous êtes à jour"
  }
}
