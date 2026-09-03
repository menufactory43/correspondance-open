import SwiftUI
import CorrespondanceCore
import CorrespondanceUI

struct ComposerBar: View {
  @Binding var text: String
  @Binding var attachmentPaths: [String]
  var isSending: Bool
  /// « Plus tard » posé : le bouton d'envoi devient une horloge.
  var isScheduling: Bool = false
  var theme: WritingTheme
  var onAttach: () -> Void
  var onSendLater: () -> Void = {}
  /// Les agents qu'on peut encore inviter ici — vide quand ils y sont tous.
  var invitableAgents: [String] = []
  var onInviteAgent: ((String) -> Void)?
  /// La voix de chaque agent **présent** dans ce fil ; vide quand il n'y en a
  /// aucun.
  var agentVoices: [AgentVoice] = []
  var onToggleAgentVoice: ((String) -> Void)? = nil
  /// « Gérer le groupe… » — nommer, ajouter, retirer. `nil` quand le fil n'est
  /// pas un groupe, ou qu'aucun de ces gestes n'est relayé par son pont.
  var onManageGroup: (() -> Void)?
  /// Le fil qui portera le vocal. `nil` = le réseau ne les porte pas, et le
  /// micro n'a rien à faire là.
  var voiceConversationID: String?
  var onSend: () -> Void

  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @FocusState private var isFocused: Bool
  @State private var dictation = ComposerDictationController()
  /// Tiroir du « + » ouvert. Se referme dès qu'on choisit, ou qu'on reprend l'écriture.
  @State private var isTrayExpanded = false
  /// Le guetteur de ⌘V. `onPasteCommand` ne sert à rien ici : le champ de
  /// texte avale le collage avant nous, même quand le presse-papiers n'a pas
  /// un mot à donner. On l'intercepte donc en amont, et on ne le garde que
  /// s'il porte une image ou un fichier.
  @State private var pasteMonitor: Any?

  private var canSend: Bool {
    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachmentPaths.isEmpty
  }

  /// Le composer corrige une bulle : le champ le dit, et Entrée envoie la
  /// correction (cf. `InboxStore.commitEdit`).
  private var isEditing: Bool { store.editingMessage != nil }

  private var isRecording: Bool { store.recorder.isRecording }

  /// Le micro du VOCAL — pas celui de la dictée, qui écrit dans le champ.
  /// Il n'apparaît que sur un fil dont le réseau porte les vocaux, et
  /// seulement quand il n'y a rien à envoyer d'autre, comme sur l'iPhone.
  private var showsVoiceButton: Bool {
    voiceConversationID != nil && !canSend && !isEditing && !dictation.isListening
  }

  private var trailingAction: ComposerTrailingAction {
    // Un vocal en cours : le bouton d'envoi l'envoie, lui.
    if isRecording { return .send }
    return .resolve(canSend: canSend, isListening: dictation.isListening, isScheduling: isScheduling)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if isRecording { recordingStrip }
      if case .failed(let raison) = store.recorder.state { micError(raison) }
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
          onSendLater: onSendLater,
          invitableAgents: invitableAgents,
          onInviteAgent: onInviteAgent,
          agentVoices: agentVoices,
          onToggleAgentVoice: onToggleAgentVoice,
          onManageGroup: onManageGroup
        )
        .padding(.bottom, 2)

        bubble
      }
      .padding(.horizontal, Spacing.md)
      .padding(.top, 8)
      .padding(.bottom, 10)
    }
    .onAppear(perform: watchPaste)
    .onDisappear {
      dictation.stop()
      if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
      pasteMonitor = nil
    }
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
    if isEditing { return "Corriger le message" }
    guard let member = activeMember, let merged = mergedID,
          let contact = store.mergedContact(for: merged)
    else { return Self.placeholder(base: "Message", asideAgents: store.primarySession?.asideAgents ?? []) }
    return Self.placeholder(
      base: "Écrire à \(contact.title) sur \(member.network.labelFR)",
      asideAgents: store.primarySession?.asideAgents ?? []
    )
  }

  /// Un agent est là : le champ vide le dit, et dit comment lui parler. Sans
  /// ça, après le message initial « cc a rejoint », rien ne rappelle qu'on
  /// peut le nommer — ni que ce sera un aparté, que les autres ne verront pas.
  static func placeholder(base: String, asideAgents: [String]) -> String {
    guard let premier = asideAgents.first else { return base }
    return "\(base) · @\(premier) pour un aparté"
  }

  /// Le composer suit l'échelle de lecture (⌘+ / ⌘−), comme les bulles.
  private var composerFont: Font {
    Typography.composer(themes.typeface, scale: themes.textScale)
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
      .font(composerFont)
      // On écrit à l'interligne où l'on lira : relire son brouillon ne doit pas
      // demander un autre œil que relire le fil.
      .lineSpacing(theme.bubbleLineSpacing(forBodySize: Typography.composerSize(themes.textScale)))
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
      // Avant le « Entrée = envoyer » : quand le menu est ouvert, Entrée choisit.
      // Avant les marges, aussi : le surlignage de la mention se pose derrière
      // le texte, et se décalerait d'autant.
      .mentionMenu(
        text: $text,
        session: store.primarySession,
        theme: theme,
        font: composerFont,
        lineSpacing: theme.bubbleLineSpacing(forBodySize: Typography.composerSize(themes.textScale))
      )
      .padding(.leading, 2)
      .padding(.vertical, 4)
      .onKeyPress(.escape) {
        guard isEditing else { return .ignored }
        store.cancelEditing()
        return .handled
      }
      .onKeyPress(.return) {
        if NSEvent.modifierFlags.contains(.shift) { return .ignored }
        guard canSend, !isSending else { return .handled }
        send()
        return .handled
      }

      // Le palette de caractères du système (⌘⌃Espace) : le bouton dit
      // seulement qu'elle existe.
      ComposerCircleButton(
        systemImage: "face.smiling",
        helpText: "Emoji et symboles (⌘⌃Espace)",
        theme: theme,
        size: ComposerMetrics.innerControl,
        iconSize: 14,
        action: { NSApp.orderFrontCharacterPalette(nil) }
      )

      if showsVoiceButton {
        ComposerCircleButton(
          systemImage: "waveform",
          helpText: "Enregistrer un message vocal",
          theme: theme,
          size: ComposerMetrics.innerControl,
          iconSize: 14,
          action: startRecording
        )
      }

      ComposerTrailingControl(
        action: trailingAction,
        theme: theme,
        isSending: isSending,
        canSend: canSend || isRecording,
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
              Text(member.networkAndReadableAddress)
            } icon: {
              Image(systemName: member.id == active.id ? "checkmark" : member.network.systemImage)
            }
          }
        }
      }
    } label: {
      ConversationAvatarView(conversation: active, size: 20, theme: theme)
        .frame(width: 20, height: 20)
    }
    // Pas `.borderlessButton` : ce style passe par un bouton AppKit qui prend
    // l'image de l'étiquette à sa taille native et ignore le cadre SwiftUI —
    // la photo de profil Signal d'un fil fusionné s'étalait sur tout le
    // composer. Avec le style bouton plein et un `buttonStyle(.plain)`, c'est
    // SwiftUI qui dessine l'étiquette, à 20 points.
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .padding(.bottom, 3)
    .help("Écrire sur un autre réseau")
    .accessibilityLabel("Chat actif : \(active.network.labelFR). Changer de réseau d'envoi.")
  }

  private func send() {
    if isRecording {
      sendRecording()
      return
    }
    dictation.stop()
    store.confirmSelectionAsRead()
    onSend()
  }

  private func startRecording() {
    guard voiceConversationID != nil else { return }
    dictation.stop()
    store.confirmSelectionAsRead()
    Task { await store.recorder.start() }
  }

  private func sendRecording() {
    guard let taken = store.recorder.stop() else { return }
    Task { await store.sendVoiceMessage(taken.url, voice: taken.voice) }
  }

  /// Ce qu'on est en train de dire : la durée qui court, le niveau du micro, et
  /// le geste pour renoncer. Le bouton d'envoi, lui, reste à sa place.
  private var recordingStrip: some View {
    HStack(spacing: 8) {
      Button { store.recorder.cancel() } label: {
        Image(systemName: "trash")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(theme.inkTertiary)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Abandonner le message vocal")

      Circle()
        .fill(theme.accent)
        .frame(width: 8, height: 8)
        .opacity(0.4 + 0.6 * store.recorder.level)

      Text(VoiceNote(duration: store.recorder.duration).durationLabel)
        .font(Typography.meta(themes.typeface))
        .foregroundStyle(theme.ink)
        .monospacedDigit()

      HStack(alignment: .center, spacing: 1.5) {
        ForEach(Array(store.recorder.samples.suffix(48).enumerated()), id: \.offset) { _, value in
          Capsule()
            .fill(theme.accent.opacity(0.7))
            .frame(width: 2, height: max(3, value * 18))
        }
      }
      .frame(height: 18, alignment: .trailing)
      .frame(maxWidth: .infinity, alignment: .trailing)
    }
    .padding(.horizontal, Spacing.md)
    .padding(.top, 8)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Enregistrement en cours")
  }

  private func micError(_ raison: String) -> some View {
    Text(raison)
      .font(Typography.meta(themes.typeface))
      .foregroundStyle(theme.inkSecondary)
      .padding(.horizontal, Spacing.md)
      .padding(.top, 8)
  }

  private func watchPaste() {
    guard pasteMonitor == nil else { return }
    pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      guard event.modifierFlags.contains(.command),
            event.charactersIgnoringModifiers?.lowercased() == "v",
            store.attachFromPasteboard()
      else { return event }
      return nil
    }
  }

  private func startOrStopDictation() {
    // Dicter dans un fil, c'est le lire — et la dictée n'écrit pas forcément
    // tout de suite dans le champ.
    store.confirmSelectionAsRead()
    isFocused = true
    Task { await dictation.toggle(currentText: text) { text = $0 } }
  }
}
