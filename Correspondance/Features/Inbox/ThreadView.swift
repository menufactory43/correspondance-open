import AppKit
import SwiftUI

struct ThreadView: View {
  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes
  @Environment(\.controlActiveState) private var controlActiveState
  @State private var isShowingThread = false
  @State private var isShowingInfo = false

  private var theme: WritingTheme { themes.theme }

  var body: some View {
    Group {
      if let conversation = store.selectedConversation {
        VStack(spacing: 0) {
          if store.isThreadSearchActive {
            ThreadSearchBar(theme: theme, typeface: themes.typeface)
          }
          messages
          if let quoted = store.replyingToMessage {
            ReplyBanner(message: quoted, theme: theme, typeface: themes.typeface)
          }
          ComposerBar(
            text: Bindable(store).draftText,
            attachmentPaths: Bindable(store).pendingAttachmentPaths,
            isSending: store.isSending,
            theme: theme,
            onAttach: { store.pickAttachments() },
            onSend: { Task { await store.sendDraft() } }
          )
        }
        .overlay(alignment: .top) {
          ConversationPillHeader(
            conversation: conversation,
            theme: theme,
            isShowingInfo: $isShowingInfo
          )
          .padding(.top, Spacing.xs)
          .opacity(controlActiveState == .inactive ? 0.6 : 1)
        }
      } else {
        Text("Aucune conversation")
          .font(Typography.emptyState(themes.typeface))
          .foregroundStyle(theme.inkSecondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .background(theme.paper)
  }

  private var messages: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: Spacing.sm) {
          ForEach(store.messages) { message in
            MessageBubbleView(
              message: message,
              theme: theme,
              typeface: themes.typeface,
              highlightQuery: store.isThreadSearchActive ? store.threadSearchQuery : "",
              isCurrentMatch: store.threadSearchCurrentID == message.id,
              isSelected: store.selectedMessageID == message.id,
              onReact: { emoji in
                Task { await store.react(messageID: message.id, emoji: emoji) }
              },
              onSelect: {
                store.selectMessage(store.selectedMessageID == message.id ? nil : message.id)
              },
              onReply: {
                store.selectMessage(message.id)
                store.replyToSelectedMessage()
              }
            )
            .id(message.id)
          }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.bottom, Spacing.md)
      }
      // La pilule flotte : on réserve sa hauteur dans le contenu défilant.
      .contentMargins(.top, 52, for: .scrollContent)
      .defaultScrollAnchor(.bottom)
      .softTopScrollEdge()
      // TODO(macOS 27) : réduire la barre d'outils au défilement vers le bas.
      // .toolbarMinimizeBehavior(.onScrollDown, for: .navigationBar)
      .opacity(isShowingThread ? 1 : 0)
      .onAppear { pinToBottom(proxy) }
      .onChange(of: store.messages.count) { _, _ in
        pinToBottom(proxy)
      }
      .onChange(of: store.selectedConversationID) { _, _ in
        isShowingThread = false
        pinToBottom(proxy)
      }
      .onChange(of: store.threadSearchCurrentID) { _, target in
        guard let target else { return }
        withAnimation(.easeOut(duration: 0.18)) {
          proxy.scrollTo(target, anchor: .center)
        }
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

/// Entête pilule en verre : avatar + « Nom › », clic → fiche contact / infos groupe.
struct ConversationPillHeader: View {
  let conversation: Conversation
  let theme: WritingTheme
  @Binding var isShowingInfo: Bool

  var body: some View {
    Button {
      isShowingInfo.toggle()
    } label: {
      HStack(spacing: 7) {
        ConversationAvatarView(conversation: conversation, size: 22, theme: theme)
        Text(conversation.title)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(theme.ink)
          .lineLimit(1)
        Image(systemName: "chevron.right")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(theme.inkTertiary)
      }
      .padding(.leading, 5)
      .padding(.trailing, 10)
      .padding(.vertical, 5)
      .glassSurface(
        cornerRadius: 17,
        fallbackFill: theme.paperSecondary,
        border: theme.edge,
        isInteractive: true
      )
      .contentShape(Capsule())
    }
    .buttonStyle(ComposerPressStyle())
    .accessibilityLabel(conversation.isGroup ? "Infos du groupe \(conversation.title)" : "Fiche de \(conversation.title)")
    .accessibilityHint("Ouvre les informations de la conversation")
    .popover(isPresented: $isShowingInfo, arrowEdge: .bottom) {
      ConversationInfoCard(conversation: conversation, theme: theme)
    }
  }
}

/// Fiche contact / infos groupe — ce que l'app sait déjà, sans permission de plus.
private struct ConversationInfoCard: View {
  let conversation: Conversation
  let theme: WritingTheme

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack(spacing: Spacing.xs) {
        ConversationAvatarView(conversation: conversation, size: 44, theme: theme)
        VStack(alignment: .leading, spacing: 2) {
          Text(conversation.title)
            .font(.system(size: 15, weight: .semibold))
          Label(
            conversation.isGroup ? "\(conversation.network.labelFR) · groupe" : conversation.network.labelFR,
            systemImage: conversation.rowSystemImage
          )
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
        }
      }

      if !conversation.isGroup {
        LabeledContent("Adresse") {
          Text(conversation.address)
            .textSelection(.enabled)
            .lineLimit(2)
        }
        .font(.system(size: 11))
      }

      if let delivery = conversation.lastDelivery {
        LabeledContent("Dernier envoi") {
          Label(delivery.labelFR, systemImage: delivery.systemImage)
        }
        .font(.system(size: 11))
      }

      LabeledContent("Dernier message") {
        Text(conversation.lastMessageAt, format: .dateTime.day().month().hour().minute())
      }
      .font(.system(size: 11))

      if !conversation.isGroup, conversation.network == .iMessage {
        Divider()
        Button("Ouvrir dans Contacts") {
          if let url = URL(string: "addressbook://") {
            NSWorkspace.shared.open(url)
          }
        }
        .buttonStyle(.link)
      }
    }
    .padding(Spacing.md)
    .frame(width: 280, alignment: .leading)
  }
}

/// Barre ⌘F du fil : champ, compteur, précédent / suivant, Échap pour fermer.
private struct ThreadSearchBar: View {
  @Environment(InboxStore.self) private var store
  let theme: WritingTheme
  let typeface: WritingTypeface
  @FocusState private var isFocused: Bool

  private var countLabel: String {
    let total = store.threadSearchMatchIDs.count
    guard total > 0 else {
      return store.threadSearchQuery.isEmpty ? "" : "Aucun résultat"
    }
    return "\(store.threadSearchCursor + 1) sur \(total)"
  }

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 11))
        .foregroundStyle(theme.inkTertiary)

      TextField("Rechercher dans le fil", text: Bindable(store).threadSearchQuery)
        .textFieldStyle(.plain)
        .font(Typography.meta(typeface))
        .foregroundStyle(theme.ink)
        .focused($isFocused)
        .onKeyPress(.escape) {
          store.closeThreadSearch()
          return .handled
        }
        .onKeyPress(.return) {
          if NSEvent.modifierFlags.contains(.shift) {
            store.threadSearchPrevious()
          } else {
            store.threadSearchNext()
          }
          return .handled
        }

      Text(countLabel)
        .font(Typography.meta(typeface))
        .foregroundStyle(theme.inkTertiary)
        .monospacedDigit()

      Button { store.threadSearchPrevious() } label: {
        Image(systemName: "chevron.up")
      }
      .disabled(store.threadSearchMatchIDs.isEmpty)
      .accessibilityLabel("Résultat précédent")

      Button { store.threadSearchNext() } label: {
        Image(systemName: "chevron.down")
      }
      .disabled(store.threadSearchMatchIDs.isEmpty)
      .accessibilityLabel("Résultat suivant")

      Button { store.closeThreadSearch() } label: {
        Image(systemName: "xmark")
      }
      .accessibilityLabel("Fermer la recherche")
    }
    .buttonStyle(.borderless)
    .font(.system(size: 11, weight: .semibold))
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, 7)
    .background(theme.paperSecondary)
    .overlay(alignment: .bottom) {
      Rectangle().fill(theme.edge).frame(height: 1)
    }
    .onAppear { isFocused = true }
  }
}

/// Bandeau « en réponse à… » au-dessus du composer, avec sa croix pour annuler.
private struct ReplyBanner: View {
  @Environment(InboxStore.self) private var store
  let message: ChatMessage
  let theme: WritingTheme
  let typeface: WritingTypeface

  var body: some View {
    HStack(spacing: 8) {
      RoundedRectangle(cornerRadius: 1, style: .continuous)
        .fill(theme.accent)
        .frame(width: 2, height: 26)
      VStack(alignment: .leading, spacing: 1) {
        Text(message.isFromMe ? "Réponse à moi-même" : "En réponse à \(message.senderID ?? "ce message")")
          .font(Typography.meta(typeface))
          .foregroundStyle(theme.accent)
        Text(message.sidebarPreviewText)
          .font(Typography.meta(typeface))
          .foregroundStyle(theme.inkSecondary)
          .lineLimit(1)
      }
      Spacer(minLength: 8)
      Button { store.cancelReply() } label: {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .semibold))
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("Annuler la citation")
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, 6)
    .background(theme.paperSecondary)
  }
}
