import SwiftUI

struct InboxListPane: View {
  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes

  private var theme: WritingTheme { themes.theme }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Inbox")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(theme.inkSecondary)
        Spacer()
        if store.usingDemoData {
          Text("Démo — pas iMessage")
            .font(Typography.meta)
            .foregroundStyle(theme.accent)
        }
      }
      .padding(.horizontal, Spacing.md)
      .padding(.top, LayoutMetrics.pageTopInset * 0.35)
      .padding(.bottom, Spacing.xs)

      if store.usingDemoData {
        PermissionBanner()
          .padding(.horizontal, Spacing.sm)
          .padding(.bottom, Spacing.sm)
      }

      ScrollView {
        LazyVStack(alignment: .leading, spacing: 2) {
          section(title: "Récents", items: store.inboxRecents)
          section(title: "Groupes Signal", items: store.inboxGroups)
          section(title: "Contacts", items: store.inboxContacts)
        }
        .padding(.horizontal, Spacing.xs)
        .padding(.bottom, Spacing.md)
      }
    }
    .background(theme.sidebar.ignoresSafeArea(edges: .top))
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
        Button {
          Task { await store.select(conversation.id) }
        } label: {
          ConversationRowView(
            conversation: conversation,
            isSelected: conversation.id == store.selectedConversationID,
            theme: theme,
            typeface: themes.typeface,
            isSyncing: store.isInitialSync || store.isLoading || store.isLiveSyncing
          )
        }
        .buttonStyle(.plain)
      }
    }
  }
}
