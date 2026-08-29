import SwiftUI

struct InboxListPane: View {
  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes

  @State private var pendingClearID: String?
  @State private var pendingLeaveID: String?

  private var theme: WritingTheme { themes.theme }
  private var isCompact: Bool { store.isSidebarCompact }

  var body: some View {
    VStack(spacing: 0) {
      header
      if store.usingDemoData && !isCompact {
        PermissionBanner()
          .padding(.horizontal, Spacing.sm)
          .padding(.bottom, Spacing.sm)
      }
      if store.needsContactsPermission && !isCompact {
        ContactsPermissionBanner()
          .padding(.horizontal, Spacing.sm)
          .padding(.bottom, Spacing.sm)
      }

      ScrollView {
        LazyVStack(alignment: .leading, spacing: isCompact ? 4 : 2) {
          if isCompact {
            ForEach(store.inboxCompactQueue) { conversation in
              conversationButton(conversation)
            }
          } else {
            section(title: "Récents", items: store.inboxRecents)
            section(title: "Groupes Signal", items: store.inboxGroups)
            section(title: "Contacts", items: store.inboxContacts)
          }
        }
        .padding(.horizontal, isCompact ? Spacing.xs : Spacing.xs)
        .padding(.bottom, Spacing.md)
      }
    }
    .background(theme.sidebar.ignoresSafeArea(edges: .top))
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

  private var header: some View {
    HStack(spacing: Spacing.xs) {
      if !isCompact {
        Text("Inbox")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(theme.inkSecondary)
        Spacer(minLength: 0)
        if store.usingDemoData {
          Text("Démo — pas iMessage")
            .font(Typography.meta)
            .foregroundStyle(theme.accent)
        }
        SoftToolButton(systemImage: "square.and.pencil", helpText: "Nouvelle conversation (⌘N)") {
          store.presentNewConversation()
        }
      } else {
        SoftToolButton(systemImage: "square.and.pencil", helpText: "Nouvelle conversation (⌘N)") {
          store.presentNewConversation()
        }
        Spacer(minLength: 0)
      }

      SoftToolButton(
        systemImage: isCompact ? "sidebar.squares.left" : "sidebar.squares.right",
        helpText: isCompact ? "Agrandir la sidebar" : "Réduire la sidebar"
      ) {
        withAnimation(.easeInOut(duration: 0.22)) {
          store.toggleSidebarCompact()
        }
      }
    }
    .padding(.horizontal, isCompact ? Spacing.xs : Spacing.md)
    .padding(.top, LayoutMetrics.pageTopInset * 0.35)
    .padding(.bottom, Spacing.xs)
  }

  @ViewBuilder
  private func section(title: String, items: [Conversation]) -> some View {
    if !items.isEmpty {
      Text(title)
        .font(Typography.sidebarSection(themes.typeface))
        .foregroundStyle(theme.inkTertiary)
        .tracking(0.6)
        .textCase(.uppercase)
        .padding(.horizontal, Spacing.sm)
        .padding(.top, Spacing.sm)
        .padding(.bottom, 4)

      ForEach(items) { conversation in
        conversationButton(conversation)
      }
    }
  }

  private func conversationButton(_ conversation: Conversation) -> some View {
    Button {
      Task { await store.select(conversation.id) }
    } label: {
      ConversationRowView(
        conversation: conversation,
        isSelected: conversation.id == store.selectedConversationID,
        theme: theme,
        typeface: themes.typeface,
        isSyncing: store.isInitialSync || store.isLoading || store.isLiveSyncing,
        isPinned: store.isPinned(conversation.id),
        isMuted: store.isMuted(conversation.id),
        isCompact: isCompact
      )
    }
    .buttonStyle(.plain)
    .contextMenu {
      conversationContextMenu(conversation)
    }
  }

  @ViewBuilder
  private func conversationContextMenu(_ conversation: Conversation) -> some View {
    Button("Ouvrir la discussion") {
      Task { await store.select(conversation.id) }
    }

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
