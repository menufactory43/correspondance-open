import SwiftUI

struct InboxListPane: View {
  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes

  @State private var pendingClearID: String?
  @State private var pendingLeaveID: String?

  private var theme: WritingTheme { themes.theme }

  /// Sélection native de la `List` — la sélection réelle reste pilotée par le store.
  private var selection: Binding<String?> {
    Binding(
      get: { store.selectedConversationID },
      set: { newValue in
        guard let newValue, newValue != store.selectedConversationID else { return }
        Task { await store.select(newValue) }
      }
    )
  }

  var body: some View {
    VStack(spacing: 0) {
      if store.usingDemoData {
        PermissionBanner()
          .padding(.horizontal, Spacing.sm)
          .padding(.vertical, Spacing.xs)
      }
      if store.needsContactsPermission {
        ContactsPermissionBanner()
          .padding(.horizontal, Spacing.sm)
          .padding(.bottom, Spacing.xs)
      }

      List(selection: selection) {
        if store.isShowingArchived {
          section(title: "Archivés", items: store.archivedQueue)
        } else {
          section(title: "Récents", items: store.inboxRecents)
          section(title: "Groupes", items: store.inboxGroups)
          section(title: "Contacts", items: store.inboxContacts)
        }
      }
      .listStyle(.sidebar)
      .scrollContentBackground(.hidden)
      .environment(\.defaultMinListRowHeight, 52)
      .overlay {
        if (store.isShowingArchived ? store.archivedQueue : store.activeQueue).isEmpty {
          emptyState
        }
      }

      archiveToggle
    }
    .confirmationDialog(
      "Effacer l’historique ?",
      isPresented: Binding(
        get: { pendingClearID != nil },
        set: { if !$0 { pendingClearID = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Effacer l’historique", role: .destructive) {
        guard let id = pendingClearID else { return }
        Task { await store.clearChatHistory(conversationID: id) }
        pendingClearID = nil
      }
      Button("Annuler", role: .cancel) { pendingClearID = nil }
    } message: {
      Text("Les messages locaux de ce fil seront effacés de Correspondance.")
    }
    .confirmationDialog(
      "Quitter le groupe ?",
      isPresented: Binding(
        get: { pendingLeaveID != nil },
        set: { if !$0 { pendingLeaveID = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Quitter le groupe", role: .destructive) {
        guard let id = pendingLeaveID else { return }
        Task { await store.leaveGroup(conversationID: id) }
        pendingLeaveID = nil
      }
      Button("Annuler", role: .cancel) { pendingLeaveID = nil }
    } message: {
      Text("Tu ne recevras plus les messages de ce groupe Signal.")
    }
  }

  /// Bascule permanente en pied de liste : l'archive est une vue, pas un dossier caché.
  private var archiveToggle: some View {
    Button {
      store.setShowingArchived(!store.isShowingArchived)
    } label: {
      HStack(spacing: 6) {
        Image(systemName: store.isShowingArchived ? "tray.full" : "archivebox")
          .font(.system(size: 11))
        Text(store.isShowingArchived ? "Retour à l’inbox" : "Archivés")
          .font(Typography.meta(themes.typeface))
        Spacer()
        if !store.isShowingArchived, !store.archivedQueue.isEmpty {
          Text("\(store.archivedQueue.count)")
            .font(Typography.meta(themes.typeface))
            .foregroundStyle(theme.inkTertiary)
        }
      }
      .foregroundStyle(theme.inkSecondary)
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, 7)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(store.isShowingArchived ? "Revenir à l’inbox" : "Voir les fils archivés")
  }

  private var emptyState: some View {
    VStack(spacing: Spacing.xs) {
      Text(emptyStateTitle)
        .font(Typography.emptyState(themes.typeface))
        .foregroundStyle(theme.inkSecondary)
      if store.networkFilter != nil {
        Button("Voir tous les réseaux") { store.setNetworkFilter(nil) }
          .buttonStyle(.link)
      }
    }
    .padding(Spacing.md)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var emptyStateTitle: String {
    if store.isShowingArchived { return "Rien d’archivé." }
    return store.networkFilter.map { "Rien sur \($0.labelFR)." } ?? "Rien à traiter."
  }

  @ViewBuilder
  private func section(title: String, items: [Conversation]) -> some View {
    if !items.isEmpty {
      Section(title) {
        ForEach(items) { conversation in
          row(conversation)
        }
      }
    }
  }

  private func row(_ conversation: Conversation) -> some View {
    ConversationRowView(
      conversation: conversation,
      theme: theme,
      typeface: themes.typeface,
      isSyncing: store.isInitialSync || store.isLoading || store.isLiveSyncing,
      isPinned: store.isPinned(conversation.id),
      isMuted: store.isMuted(conversation.id)
    )
    .tag(conversation.id)
    .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
    .contextMenu {
      conversationContextMenu(conversation)
    }
  }

  @ViewBuilder
  private func conversationContextMenu(_ conversation: Conversation) -> some View {
    Button("Ouvrir la discussion") {
      Task { await store.select(conversation.id) }
    }

    Button(store.isArchived(conversation.id) ? "Désarchiver" : "Archiver") {
      Task { await store.toggleArchived(conversationID: conversation.id) }
    }

    Divider()

    if conversation.network == .signal {
      Button(conversation.hasUnread ? "Marquer comme lu" : "Marquer comme non lu") {
        if conversation.hasUnread {
          Task { await store.select(conversation.id) }
        } else {
          store.markUnread(conversationID: conversation.id)
        }
      }

      Button(store.isPinned(conversation.id) ? "Désépingler la discussion" : "Épingler la discussion") {
        store.togglePinned(conversationID: conversation.id)
      }

      Button(store.isMuted(conversation.id) ? "Réactiver les notifications" : "Couper les notifications") {
        store.toggleMuted(conversationID: conversation.id)
      }

      Divider()

      Menu("Messages éphémères") {
        ForEach(DisappearingOption.allCases) { option in
          let selected = store.disappearingSeconds(for: conversation.id) == option.seconds
          Button {
            Task { await store.setDisappearingMessages(conversationID: conversation.id, seconds: option.seconds) }
          } label: {
            if selected {
              Label(option.titleFR, systemImage: "checkmark")
            } else {
              Text(option.titleFR)
            }
          }
        }
      }

      Button("Effacer l’historique…", role: .destructive) {
        pendingClearID = conversation.id
      }

      if conversation.isGroup {
        Button("Quitter le groupe…", role: .destructive) {
          pendingLeaveID = conversation.id
        }
      }
    } else {
      Button(conversation.hasUnread ? "Marquer comme lu" : "Marquer comme non lu") {
        if conversation.hasUnread {
          Task { await store.select(conversation.id) }
        } else {
          store.markUnread(conversationID: conversation.id)
        }
      }
      Button(store.isPinned(conversation.id) ? "Désépingler" : "Épingler") {
        store.togglePinned(conversationID: conversation.id)
      }
    }
  }
}

private enum DisappearingOption: Int, CaseIterable, Identifiable {
  case off = 0
  case thirtySeconds = 30
  case fiveMinutes = 300
  case oneHour = 3_600
  case oneDay = 86_400
  case oneWeek = 604_800
  case fourWeeks = 2_419_200

  var id: Int { rawValue }
  var seconds: Int { rawValue }

  var titleFR: String {
    switch self {
    case .off: "Désactivés"
    case .thirtySeconds: "30 secondes"
    case .fiveMinutes: "5 minutes"
    case .oneHour: "1 heure"
    case .oneDay: "1 jour"
    case .oneWeek: "1 semaine"
    case .fourWeeks: "4 semaines"
    }
  }
}
