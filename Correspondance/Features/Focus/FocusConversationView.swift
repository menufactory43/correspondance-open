import AppKit
import SwiftUI

/// Une conversation à la fois — page zen, chrome fantôme.
struct FocusConversationView: View {
  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var theme: WritingTheme { themes.theme }
  private var isWriting: Bool { store.isComposerFocused }

  var body: some View {
    ZStack(alignment: .topLeading) {
      theme.paper.ignoresSafeArea()

      VStack(alignment: .leading, spacing: 0) {
        Spacer(minLength: LayoutMetrics.pageTopInset * 0.4)

        if store.usingDemoData {
          PermissionBanner()
            .padding(.bottom, Spacing.lg)
            .opacity(isWriting ? 0 : 1)
        }

        if let conversation = store.selectedConversation {
          Text(conversation.title)
            .font(Typography.toolbarPhrase(themes.typeface))
            .foregroundStyle(theme.inkTertiary)
            .padding(.bottom, Spacing.md)
            .opacity(isWriting ? 0 : 1)
            .accessibilityHidden(isWriting)

          FocusTranscriptView()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
          VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(store.isLoading ? "Chargement…" : "Rien à lire pour l’instant.")
              .font(Typography.emptyState(themes.typeface))
              .foregroundStyle(theme.inkSecondary)
            Text(store.signalStatusFR)
              .font(Typography.meta(themes.typeface))
              .foregroundStyle(theme.inkTertiary)
            Text(store.iMessageStatusFR)
              .font(Typography.meta(themes.typeface))
              .foregroundStyle(theme.inkTertiary)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
      }
      .frame(maxWidth: LayoutMetrics.letterWidth, alignment: .leading)
      .padding(.leading, LayoutMetrics.pageLeading)
      .padding(.trailing, Spacing.xl)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .animation(chromeAnimation, value: isWriting)
    }
  }

  private var chromeAnimation: Animation? {
    reduceMotion ? nil : .easeOut(duration: 0.15)
  }

}

/// Fil en prose — le brouillon est le dernier paragraphe de la page.
private struct FocusTranscriptView: View {
  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isShowingThread = false

  private var theme: WritingTheme { themes.theme }
  private var isWriting: Bool { store.isComposerFocused }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: Spacing.md) {
          ForEach(messageGroups) { group in
            VStack(alignment: .leading, spacing: 6) {
              // Une page ne réannonce pas son locuteur à chaque phrase : un
              // libellé par prise de parole, et rien du tout en tête-à-tête.
              if let label = focusLabel(for: group) {
                Text(label)
                  .font(Typography.toolbarPhrase(themes.typeface))
                  .foregroundStyle(theme.inkTertiary)
              }
              ForEach(group.messages) { message in
                VStack(alignment: .leading, spacing: 6) {
                  ForEach(message.attachments) { raw in
                    let attachment = FocusAttachment.repaired(raw)
                    if let url = attachment.resolvedFileURL, attachment.isImage,
                       let nsImage = NSImage(contentsOf: url)
                    {
                      Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 360, maxHeight: 400)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                  }
                  if shouldShowFocusText(message) {
                    Text(message.text)
                      .font(pageFont)
                      .foregroundStyle(theme.ink.opacity(message.isFromMe ? 0.72 : 1))
                      .lineSpacing(theme.lineSpacing * 0.65)
                  }
                }
                .opacity(message.isPending ? 0.5 : 1)
                .id(message.id)
                .frame(maxWidth: .infinity, alignment: .leading)
              }
            }
            .opacity(isWriting ? 0.34 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isWriting)
            .frame(maxWidth: .infinity, alignment: .leading)
          }

          ForEach(store.scheduledForSelection) { scheduled in
            ScheduledMessageRow(message: scheduled, theme: theme, typeface: themes.typeface, isProse: true)
              .font(pageFont)
              .padding(.top, Spacing.sm)
              .opacity(isWriting ? 0.34 : 1)
          }

          if let config = store.sendLaterConfig {
            SendLaterBanner(config: config, theme: theme, typeface: themes.typeface)
              .padding(.top, Spacing.sm)
          }

          FocusPageEditor(
            text: Bindable(store).draftText,
            attachmentPaths: Bindable(store).pendingAttachmentPaths,
            isSending: store.isSending,
            isScheduling: store.sendLaterConfig != nil,
            theme: theme,
            onAttach: { store.pickAttachments() },
            onSendLater: { store.toggleSendLaterPicker() },
            onSend: { Task { await store.sendDraft() } }
          )
          .id("draft")
          .popover(
            isPresented: Binding(
              get: { store.sendLaterPicker != nil },
              set: { if !$0 { store.sendLaterPicker = nil } }
            ),
            arrowEdge: .top
          ) {
            SendLaterPicker()
          }
        }
        .padding(.bottom, LayoutMetrics.pageBottomInset)
      }
      .defaultScrollAnchor(.bottom)
      .scrollIndicators(.never)
      // Remonter le fil rappelle la barre d'outils, comme un geste de retour
      // en arrière ; descendre la laisse dormir.
      .overlay(alignment: .top) {
        // Même soin qu'en Inbox : le fil se dissout sous le titre de la page
        // au lieu d'y être tranché.
        TopScrollFade(theme: theme, height: Spacing.lg, reachesWindowEdge: false)
      }
      .onScrollUp {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) {
          store.flashFocusChrome()
        }
      }
      .opacity(isShowingThread ? 1 : 0)
      .overlay {
        MacOverlayScrollerHider()
          .allowsHitTesting(false)
      }
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
    proxy.scrollTo("draft", anchor: .bottom)
    DispatchQueue.main.async {
      proxy.scrollTo("draft", anchor: .bottom)
      isShowingThread = true
    }
  }

  private var pageFont: Font {
    Typography.letterBody(themes.typeface, size: theme.bodySize * themes.typeScale)
  }

  private var isGroup: Bool { store.selectedConversation?.isGroup == true }

  private var messageGroups: [MessageGroup] {
    MessageGrouping.groups(for: store.messages, showsSenderNames: isGroup)
  }

  /// En groupe, chaque prise de parole s'annonce une fois ; en tête-à-tête, la
  /// page se lit comme une lettre — l'encre plus pâle dit déjà que c'est moi.
  private func focusLabel(for group: MessageGroup) -> String? {
    guard isGroup else { return nil }
    return group.isFromMe ? "Toi" : group.senderLabel
  }
}

/// Au repos / à la pause : photo + envoyer. Pendant la frappe : une feuille.
private struct FocusPageEditor: View {
  @Binding var text: String
  @Binding var attachmentPaths: [String]
  var isSending: Bool
  var isScheduling: Bool = false
  var theme: WritingTheme
  var onAttach: () -> Void
  var onSendLater: () -> Void = {}
  var onSend: () -> Void

  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @FocusState private var isFocused: Bool
  @State private var isActivelyTyping = false
  @State private var idleTask: Task<Void, Never>?
  @State private var isTrayExpanded = false

  private var canSend: Bool {
    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachmentPaths.isEmpty
  }

  private var showsChrome: Bool { !isActivelyTyping }

  private var pageFont: Font {
    Typography.letterBody(themes.typeface, size: theme.bodySize * themes.typeScale)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
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

      HStack(alignment: .top, spacing: 8) {
        TextField(showsChrome ? "Répondre…" : "", text: $text, axis: .vertical)
          .textFieldStyle(.plain)
          .font(pageFont)
          .foregroundStyle(theme.ink)
          .lineLimit(1...20)
          .focused($isFocused)
          .frame(maxWidth: .infinity, alignment: .leading)
          .onKeyPress(.return) {
            if NSEvent.modifierFlags.contains(.shift) { return .ignored }
            guard canSend, !isSending else { return .handled }
            endTyping()
            onSend()
            return .handled
          }
          .onKeyPress(.escape) {
            isFocused = false
            endTyping()
            return .handled
          }

        ComposerPlusTray(
          theme: theme,
          isScheduling: isScheduling,
          iconSize: 18,
          isExpanded: $isTrayExpanded,
          onAttach: onAttach,
          onSendLater: onSendLater
        )
        .opacity(showsChrome ? 1 : 0)
        .allowsHitTesting(showsChrome)

        sendButton
          .opacity(showsChrome ? 1 : 0)
          .allowsHitTesting(showsChrome)
      }
    }
    .padding(.top, 8)
    .overlay(alignment: .top) {
      Rectangle()
        .fill(theme.edge.opacity(0.55))
        .frame(height: 1)
        .opacity(showsChrome ? 1 : 0)
    }
    .onChange(of: text) { _, newValue in
      if isTrayExpanded { isTrayExpanded = false }
      guard isFocused, !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return
      }
      noteTyping()
    }
    .onChange(of: isFocused) { _, focused in
      if !focused { endTyping() }
    }
    .onDisappear {
      idleTask?.cancel()
      store.isComposerFocused = false
    }
  }

  private var sendButton: some View {
    Button {
      endTyping()
      onSend()
    } label: {
      Image(systemName: isScheduling ? "clock.badge.checkmark" : "arrow.up")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(canSend ? theme.paper : theme.inkTertiary.opacity(0.45))
        .frame(width: 28, height: 28)
        .background(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(canSend ? theme.accent : theme.inkTertiary.opacity(0.12))
        )
    }
    .buttonStyle(.plain)
    .disabled(!canSend || isSending)
    .help(isScheduling ? "Programmer l’envoi" : "Envoyer")
    .accessibilityLabel(isScheduling ? "Programmer l’envoi" : "Envoyer")
  }

  private func noteTyping() {
    isActivelyTyping = true
    store.isComposerFocused = true
    idleTask?.cancel()
    idleTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 1_100_000_000)
      guard !Task.isCancelled else { return }
      isActivelyTyping = false
      store.isComposerFocused = false
    }
  }

  private func endTyping() {
    idleTask?.cancel()
    isActivelyTyping = false
    store.isComposerFocused = false
  }
}

private enum FocusAttachment {
  static func repaired(_ attachment: MessageAttachment) -> MessageAttachment {
    if attachment.resolvedFileURL != nil { return attachment }
    var copy = attachment
    if let path = SignalAttachmentStore.localPath(forAttachmentID: attachment.id) {
      copy.localPath = path
    }
    return copy
  }
}

private func shouldShowFocusText(_ message: ChatMessage) -> Bool {
  let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return false }
  let hasVisibleImage = message.attachments.contains {
    let repaired = FocusAttachment.repaired($0)
    return repaired.isImage && repaired.resolvedFileURL != nil
  }
  if hasVisibleImage, trimmed == "📷 Photo" { return false }
  return true
}

/// SwiftUI pose souvent l’overlay *à côté* du NSScrollView, pas dedans.
/// On cherche frères + ancêtres, et on re-masque pendant le geste.
private struct MacOverlayScrollerHider: NSViewRepresentable {
  func makeNSView(context: Context) -> OverlayScrollerHiderView {
    OverlayScrollerHiderView()
  }

  func updateNSView(_ nsView: OverlayScrollerHiderView, context: Context) {
    nsView.hideNearbyScrollers()
  }
}

private final class OverlayScrollerHiderView: NSView {
  private var tokens: [NSObjectProtocol] = []

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    hideNearbyScrollers()
    startObserving()
  }

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    hideNearbyScrollers()
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    super.viewWillMove(toWindow: newWindow)
    if newWindow == nil { stopObserving() }
  }

  func hideNearbyScrollers() {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      var current: NSView? = self
      while let view = current {
        Self.mute(in: view)
        current = view.superview
      }
    }
  }

  private static func mute(in view: NSView) {
    if let scroll = view as? NSScrollView {
      mute(scroll)
    }
    if view is NSScroller {
      view.alphaValue = 0
      view.isHidden = true
    }
    for sub in view.subviews {
      if let scroll = sub as? NSScrollView {
        mute(scroll)
      }
      if sub is NSScroller {
        sub.alphaValue = 0
        sub.isHidden = true
      }
    }
  }

  private static func mute(_ scroll: NSScrollView) {
    scroll.scrollerStyle = .overlay
    scroll.autohidesScrollers = true
    for scroller in [scroll.verticalScroller, scroll.horizontalScroller].compactMap({ $0 }) {
      scroller.wantsLayer = true
      scroller.alphaValue = 0
      scroller.isHidden = true
      scroller.layer?.opacity = 0
      scroller.isEnabled = false
    }
  }

  private func startObserving() {
    stopObserving()
    let nc = NotificationCenter.default
    tokens.append(nc.addObserver(
      forName: NSScrollView.didLiveScrollNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.hideNearbyScrollers() }
    })
    tokens.append(nc.addObserver(
      forName: NSView.boundsDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] note in
      guard note.object is NSClipView else { return }
      Task { @MainActor in self?.hideNearbyScrollers() }
    })
  }

  private func stopObserving() {
    let nc = NotificationCenter.default
    tokens.forEach { nc.removeObserver($0) }
    tokens.removeAll()
  }
}
