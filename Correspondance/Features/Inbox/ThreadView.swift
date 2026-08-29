import AppKit
import SwiftUI

struct ThreadView: View {
  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes
  @State private var isShowingThread = false

  private var theme: WritingTheme { themes.theme }

  var body: some View {
    Group {
      if store.selectedConversation != nil {
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

          if let delivery = store.selectedConversation?.lastDelivery,
             store.messages.last?.isFromMe == true
          {
            DeliveryReceiptLabel(delivery: delivery, theme: theme, typeface: themes.typeface)
          }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.bottom, Spacing.md)
      }
      // `contentMargins` s'AJOUTE à la zone sûre de la barre d'outils — inutile
      // d'y recompter la hauteur du titre.
      .contentMargins(.top, ThreadMetrics.topClearance, for: .scrollContent)
      .defaultScrollAnchor(.bottom)
      .overlay(alignment: .top) { TopScrollFade(theme: theme) }
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

enum ThreadMetrics {
  /// Air au-dessus du premier message, en plus de la zone sûre de la barre
  /// d'outils que le système fournit déjà.
  static let topClearance: CGFloat = 16
  /// Hauteur de la bande où le fil se dissout sous la barre d'outils.
  static let topFadeHeight: CGFloat = 64
}

/// Le fil passe SOUS la barre d'outils transparente : sans transition il s'y
/// coupe net, à mi-bulle. On dissout la bande haute dans le papier — pas de
/// filet, pas d'arête — comme le fait Messages sous sa barre en verre.
struct TopScrollFade: View {
  let theme: WritingTheme
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  var body: some View {
    LinearGradient(
      stops: [
        .init(color: theme.paper, location: 0),
        .init(color: theme.paper, location: reduceTransparency ? 0.8 : 0.62),
        .init(color: theme.paper.opacity(0), location: 1),
      ],
      startPoint: .top,
      endPoint: .bottom
    )
    .frame(height: ThreadMetrics.topFadeHeight)
    .frame(maxWidth: .infinity)
    .allowsHitTesting(false)
    .ignoresSafeArea(edges: .top)
    .accessibilityHidden(true)
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

/// Coche d'acheminement sous le dernier message sortant.
///
/// iMessage la donne complète (`is_delivered` / `is_read`). WhatsApp ne bridge que la
/// **lecture** : on y montre « Envoyé » ou « Vu », jamais « Livré ». Signal ne bridge
/// aucun accusé de livraison — rien ne s'affiche.
private struct DeliveryReceiptLabel: View {
  let delivery: MessageDelivery
  let theme: WritingTheme
  let typeface: WritingTypeface

  var body: some View {
    HStack(spacing: 3) {
      Image(systemName: delivery.systemImage)
        .font(.system(size: 9))
      Text(delivery.labelFR)
        .font(Typography.meta(typeface))
    }
    .foregroundStyle(delivery == .read ? theme.accent : theme.inkTertiary)
    .frame(maxWidth: .infinity, alignment: .trailing)
    .padding(.trailing, 4)
    .accessibilityLabel("Dernier message : \(delivery.labelFR)")
  }
}
