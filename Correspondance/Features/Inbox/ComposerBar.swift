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

  @Environment(InboxStore.self) private var store
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
      dictation.noteTextChanged()
    }
  }

  /// Le fil ouvert est-il une fusion ? Alors il faut dire — et pouvoir choisir —
  /// sur quel réseau part le prochain message.
  private var mergedID: String? {
    guard let id = store.selectedConversationID, store.isMerged(id) else { return nil }
    return id
  }

  private var activeMember: Conversation? {
    mergedID.flatMap { store.activeMember(of: $0) }
  }

  private var placeholder: String {
    guard let member = activeMember, let merged = mergedID,
          let contact = store.mergedContact(for: merged)
    else { return "Message" }
    return "Écrire à \(contact.title) sur \(member.network.labelFR)"
  }

  private var bubble: some View {
    HStack(alignment: .bottom, spacing: 6) {
      if let mergedID, let member = activeMember {
        chatPicker(mergedID: mergedID, active: member)
      }

      TextField(
        "",
        text: $text,
        prompt: Text(placeholder).foregroundStyle(theme.inkTertiary),
        axis: .vertical
      )
      .textFieldStyle(.plain)
      .font(Typography.composer(themes.typeface))
      .foregroundStyle(theme.ink)
      .lineLimit(1...6)
      .focused($isFocused)
      .focusEffectDisabled()
      // Se mettre à écrire dans un fil, c'est le lire — même si c'est l'app qui
      // l'avait ouvert au lancement, sans qu'on l'ait jamais cliqué.
      //
      // On guette la frappe et non le focus : sur macOS, AppKit peut installer
      // le premier champ texte de la fenêtre comme premier répondant quand elle
      // devient active, sans qu'on ait rien demandé. Un focus reçu de cette
      // façon effacerait au lancement, en silence, le non-lu qu'on vient de
      // rendre. Taper, personne ne le fait à notre place.
      .onChange(of: text) { _, _ in
        if isFocused { store.confirmSelectionAsRead() }
      }
      .padding(.leading, 2)
      .padding(.vertical, 4)
      // Avant le « Entrée = envoyer » : quand le menu est ouvert, Entrée choisit.
      .mentionMenu(
        text: $text,
        session: store.primarySession,
        theme: theme,
        font: Typography.composer(themes.typeface)
      )
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



  /// L'avatar du réseau où l'on écrit, cliquable : c'est le sélecteur de chat.
  /// Il porte déjà sa pastille de réseau (cf. `ConversationAvatarView`), donc on
  /// voit d'un coup d'œil si le message part sur iMessage ou sur WhatsApp.
  private func chatPicker(mergedID: String, active: Conversation) -> some View {
    Menu {
      Section("Changer de chat") {
        ForEach(store.memberConversations(of: mergedID)) { member in
          Button {
            store.setActiveMember(mergedID: mergedID, conversationID: member.id)
          } label: {
            Label {
              Text("\(member.network.labelFR) · \(member.address)")
            } icon: {
              Image(systemName: member.id == active.id ? "checkmark" : member.network.systemImage)
            }
          }
        }
      }
    } label: {
      ConversationAvatarView(conversation: active, size: 20, theme: theme)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .padding(.bottom, 3)
    .help("Écrire sur un autre réseau")
    .accessibilityLabel("Chat actif : \(active.network.labelFR). Changer de réseau d'envoi.")
  }

  private func send() {
    dictation.stop()
    store.confirmSelectionAsRead()
    onSend()
  }

  private func startOrStopDictation() {
    // Dicter dans un fil, c'est le lire — et la dictée n'écrit pas forcément
    // tout de suite dans le champ.
    store.confirmSelectionAsRead()
    isFocused = true
    Task { await dictation.toggle(currentText: text) { text = $0 } }
  }
}
