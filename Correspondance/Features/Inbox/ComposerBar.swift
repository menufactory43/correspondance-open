import SwiftUI

struct ComposerBar: View {
  @Binding var text: String
  @Binding var attachmentPaths: [String]
  var isSending: Bool
  /// « Plus tard » posé : le bouton d'envoi devient une horloge.
  var isScheduling: Bool = false
  var theme: WritingTheme
  var onAttach: () -> Void
  var onSendLater: () -> Void = {}
  var onSend: () -> Void

  @Environment(ThemePreferences.self) private var themes
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @FocusState private var isFocused: Bool
  @State private var dictation = ComposerDictationController()
  /// Tiroir du « + » ouvert. Se referme dès qu'on choisit, ou qu'on reprend l'écriture.
  @State private var isTrayExpanded = false

  private var canSend: Bool {
    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachmentPaths.isEmpty
  }

  private var trailingAction: ComposerTrailingAction {
    .resolve(canSend: canSend, isListening: dictation.isListening, isScheduling: isScheduling)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if !attachmentPaths.isEmpty {
        ComposerAttachmentStrip(
          paths: $attachmentPaths,
          theme: theme,
          horizontalPadding: Spacing.md
        )
        .padding(.top, 8)
      }

      HStack(alignment: .bottom, spacing: 8) {
        ComposerPlusTray(
          theme: theme,
          isScheduling: isScheduling,
          isExpanded: $isTrayExpanded,
          onAttach: onAttach,
          onSendLater: onSendLater
        )
        .padding(.bottom, 2)

        bubble
      }
      .padding(.horizontal, Spacing.md)
      .padding(.top, 8)
      .padding(.bottom, 10)
    }
    .onDisappear { dictation.stop() }
    .onChange(of: text) { _, _ in
      if isTrayExpanded { isTrayExpanded = false }
    }
  }

  private var bubble: some View {
    HStack(alignment: .bottom, spacing: 6) {
      TextField(
        "",
        text: $text,
        prompt: Text("Message").foregroundStyle(theme.inkTertiary),
        axis: .vertical
      )
      .textFieldStyle(.plain)
      .font(Typography.composer(themes.typeface))
      .foregroundStyle(theme.ink)
      .lineLimit(1...6)
      .focused($isFocused)
      .focusEffectDisabled()
      .padding(.leading, 2)
      .padding(.vertical, 4)
      .onKeyPress(.return) {
        if NSEvent.modifierFlags.contains(.shift) { return .ignored }
        guard canSend, !isSending else { return .handled }
        send()
        return .handled
      }

      ComposerTrailingControl(
        action: trailingAction,
        theme: theme,
        isSending: isSending,
        canSend: canSend,
        isListening: dictation.isListening,
        onSend: send,
        onDictate: startOrStopDictation
      )
      .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: trailingAction)
    }
    .padding(.leading, 12)
    .padding(.trailing, 4)
    .padding(.vertical, 4)
    .frame(minHeight: ComposerMetrics.bubbleMinHeight)
    .frame(maxWidth: .infinity)
    .glassSurface(
      cornerRadius: ComposerMetrics.bubbleCorner,
      tint: dictation.isListening ? theme.accent.opacity(0.2) : nil,
      fallbackFill: theme.paperSecondary,
      border: isFocused ? theme.accent.opacity(0.4) : theme.edge
    )
  }



  private func send() {
    dictation.stop()
    onSend()
  }

  private func startOrStopDictation() {
    isFocused = true
    Task { await dictation.toggle(currentText: text) { text = $0 } }
  }
}
