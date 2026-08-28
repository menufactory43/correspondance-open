import AppKit
import SwiftUI

/// Une conversation à la fois — page zen, chrome fantôme.
struct FocusConversationView: View {
  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes
  @State private var chromeRevealed = false

  private var theme: WritingTheme { themes.theme }

  var body: some View {
    ZStack {
      theme.paper.ignoresSafeArea()

      VStack(spacing: 0) {
        Spacer(minLength: LayoutMetrics.pageTopInset * 0.45)

        if store.usingDemoData {
          PermissionBanner()
            .frame(maxWidth: LayoutMetrics.letterWidth)
            .padding(.bottom, Spacing.lg)
        }

        if let conversation = store.selectedConversation {
          Text(conversation.title)
            .font(Typography.toolbarPhrase(themes.typeface))
            .foregroundStyle(theme.inkTertiary)
            .frame(maxWidth: LayoutMetrics.letterWidth)
            .padding(.bottom, Spacing.md)

          FocusTranscriptView()
            .frame(maxWidth: LayoutMetrics.letterWidth)
            .frame(maxWidth: .infinity)

          FocusComposerBar(
            text: Bindable(store).draftText,
            attachmentPaths: Bindable(store).pendingAttachmentPaths,
            isSending: store.isSending,
            theme: theme,
            onAttach: { store.pickAttachments() },
            onSend: { Task { await store.sendDraft() } }
          )
          .frame(maxWidth: LayoutMetrics.letterWidth)
          .padding(.bottom, Spacing.xl)
        } else {
          VStack(spacing: Spacing.sm) {
            Text(store.isLoading ? "Chargement…" : "Rien à lire pour l’instant.")
              .font(Typography.emptyState(themes.typeface))
              .foregroundStyle(theme.inkSecondary)
            Text(store.signalStatusFR)
              .font(Typography.meta(themes.typeface))
              .foregroundStyle(theme.inkTertiary)
              .multilineTextAlignment(.center)
            Text(store.iMessageStatusFR)
              .font(Typography.meta(themes.typeface))
              .foregroundStyle(theme.inkTertiary)
              .multilineTextAlignment(.center)
          }
          .frame(maxWidth: LayoutMetrics.letterWidth)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .padding(.horizontal, Spacing.xl)

      // Chrome fantôme — apparaît en haut au survol.
      VStack {
        focusChrome
          .opacity(chromeRevealed ? 1 : 0)
          .animation(.easeOut(duration: 0.15), value: chromeRevealed)
        Spacer()
      }
      .padding(.top, 8)
    }
    .onHover { hovering in
      // Bande haute : le chrome se révèle près du haut de fenêtre via hit area.
      if !hovering { chromeRevealed = false }
    }
    .overlay(alignment: .top) {
      Color.clear
        .frame(height: 56)
        .contentShape(Rectangle())
        .onHover { chromeRevealed = $0 }
        .allowsHitTesting(true)
    }
  }

  private var focusChrome: some View {
    HStack(spacing: Spacing.sm) {
      SoftToolButton(
        systemImage: "chevron.left",
        helpText: "Conversation précédente",
        isDisabled: store.focusIndex == nil || store.focusIndex == 0
      ) {
        Task { await store.focusPrevious() }
      }

      SoftToolButton(
        systemImage: "chevron.right",
        helpText: "Conversation suivante",
        isDisabled: {
          guard let index = store.focusIndex else { return true }
          return index >= store.activeQueue.count - 1
        }()
      ) {
        Task { await store.focusNext() }
      }

      SoftToolButton(systemImage: "archivebox", helpText: "Archiver (⌘E)") {
        Task { await store.archiveSelected() }
      }

      Spacer()

      if let conversation = store.selectedConversation {
        HStack(spacing: 6) {
          Image(systemName: conversation.rowSystemImage)
          Text(conversation.isGroup ? "Signal · groupe" : conversation.network.labelFR)
        }
        .font(Typography.meta)
        .foregroundStyle(theme.inkTertiary)
      }
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.xs)
  }
}

/// Fil en prose — pas de bulles chat.
private struct FocusTranscriptView: View {
  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes

  private var theme: WritingTheme { themes.theme }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: Spacing.md) {
          ForEach(store.messages) { message in
            VStack(alignment: .leading, spacing: 6) {
              Text(message.isFromMe ? "Toi" : "Eux")
                .font(Typography.meta(themes.typeface))
                .foregroundStyle(theme.inkTertiary)
              ForEach(message.attachments.filter(\.isImage)) { attachment in
                if let url = attachment.resolvedFileURL,
                   let nsImage = NSImage(contentsOf: url)
                {
                  Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 360, maxHeight: 400)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
              }
              if !message.text.isEmpty {
                Text(message.text)
                  .font(Typography.letterBody(themes.typeface, size: theme.bodySize * themes.typeScale))
                  .foregroundStyle(theme.ink.opacity(message.isFromMe ? 0.72 : 1))
                  .lineSpacing(theme.lineSpacing * 0.65)
              }
            }
            .opacity(message.isPending ? 0.5 : 1)
            .id(message.id)
            .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .padding(.bottom, Spacing.lg)
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

private struct FocusComposerBar: View {
  @Binding var text: String
  @Binding var attachmentPaths: [String]
  var isSending: Bool
  var theme: WritingTheme
  var onAttach: () -> Void
  var onSend: () -> Void

  @Environment(ThemePreferences.self) private var themes

  private var canSend: Bool {
    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachmentPaths.isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if !attachmentPaths.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 8) {
            ForEach(Array(attachmentPaths.enumerated()), id: \.offset) { index, path in
              ZStack(alignment: .topTrailing) {
                if let img = NSImage(contentsOfFile: path) {
                  Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                Button {
                  attachmentPaths.remove(at: index)
                } label: {
                  Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white, .black.opacity(0.55))
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
              }
            }
          }
        }
      }

      HStack(alignment: .bottom, spacing: Spacing.sm) {
        SoftToolButton(systemImage: "photo", helpText: "Joindre une image") {
          onAttach()
        }

        TextField("Répondre…", text: $text, axis: .vertical)
          .textFieldStyle(.plain)
          .font(Typography.composer(themes.typeface))
          .foregroundStyle(theme.ink)
          .lineLimit(1...5)
          .padding(.vertical, 8)

        SoftToolButton(
          systemImage: "arrow.up",
          helpText: "Envoyer",
          isEmphasized: true,
          isDisabled: !canSend || isSending
        ) {
          onSend()
        }
      }
    }
    .overlay(alignment: .top) {
      Rectangle()
        .fill(theme.edge.opacity(0.55))
        .frame(height: 1)
        .offset(y: -4)
    }
  }
}
