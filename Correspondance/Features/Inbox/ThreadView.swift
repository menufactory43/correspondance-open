import SwiftUI

struct ThreadView: View {
  var showsHeader: Bool = true

  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes
  @State private var isShowingThread = false

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
      .defaultScrollAnchor(.bottom)
      .opacity(isShowingThread ? 1 : 0)
      .onAppear { pinToBottom(proxy) }
      .onChange(of: store.messages.count) { _, _ in
        pinToBottom(proxy)
      }
      .onChange(of: store.selectedConversationID) { _, _ in
        isShowingThread = false
        pinToBottom(proxy)
      }
    }
  }

  private func pinToBottom(_ proxy: ScrollViewProxy) {
    let target = store.messages.last?.id
    if let target {
      proxy.scrollTo(target, anchor: .bottom)
    }
    DispatchQueue.main.async {
      if let id = store.messages.last?.id {
        proxy.scrollTo(id, anchor: .bottom)
      }
      isShowingThread = true
    }
  }
}
