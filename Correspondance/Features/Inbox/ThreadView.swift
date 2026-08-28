import SwiftUI

struct ThreadView: View {
  var showsHeader: Bool = true

  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes

  private var theme: WritingTheme { themes.theme }

  var body: some View {
    VStack(spacing: 0) {
      if showsHeader {
        header
        Divider().overlay(theme.edge.opacity(0.6))
      }
      if store.selectedConversation == nil {
        Text("Aucune conversation")
          .font(Typography.emptyState)
          .foregroundStyle(theme.inkSecondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        messages
        Divider().overlay(theme.edge.opacity(0.6))
        ComposerBar(
          text: Bindable(store).draftText,
          attachmentPaths: Bindable(store).pendingAttachmentPaths,
          isSending: store.isSending,
          theme: theme,
          onAttach: { store.pickAttachments() },
          onSend: { Task { await store.sendDraft() } }
        )
      }
    }
    .background(theme.paper.ignoresSafeArea())
  }

  @ViewBuilder
  private var header: some View {
    if let conversation = store.selectedConversation {
      HStack(spacing: Spacing.sm) {
        VStack(alignment: .leading, spacing: 2) {
          Text(conversation.title)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(theme.ink)
          HStack(spacing: 6) {
            Image(systemName: conversation.rowSystemImage)
            Text(conversation.isGroup ? "Signal · groupe" : conversation.network.labelFR)
            if !conversation.isGroup {
              Text("·")
              Text(conversation.address)
                .lineLimit(1)
            }
          }
          .font(Typography.meta)
          .foregroundStyle(theme.inkSecondary)
        }
        Spacer()
        SoftToolButton(systemImage: "archivebox", helpText: "Archiver") {
          Task { await store.archiveSelected() }
        }
      }
      .padding(.horizontal, Spacing.md)
      .padding(.top, LayoutMetrics.pageTopInset * 0.35)
      .padding(.bottom, Spacing.sm)
    }
  }

  private var messages: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: Spacing.sm) {
          ForEach(store.messages) { message in
            MessageBubbleView(message: message, theme: theme, typeface: themes.typeface)
              .id(message.id)
          }
        }
        .padding(Spacing.md)
      }
      .onChange(of: store.messages.count) { _, _ in
        if let last = store.messages.last?.id {
          withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(last, anchor: .bottom)
          }
        }
      }
      .onChange(of: store.selectedConversationID) { _, _ in
        if let last = store.messages.last?.id {
          proxy.scrollTo(last, anchor: .bottom)
        }
      }
    }
  }
}
