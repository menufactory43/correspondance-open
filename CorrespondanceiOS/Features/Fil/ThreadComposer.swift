import CorrespondanceCore
import CorrespondanceUI
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Le composer du fil.
///
/// **+** à gauche (Photos / Caméra / Fichier), le champ « Répondre sur
/// {Réseau} » au centre, le micro à droite : on le MAINTIENT pour parler, on
/// relâche pour envoyer, on glisse à gauche pour renoncer et vers le haut pour
/// poser le doigt (cf. `VoiceHoldGesture`). Une tape courte ne fait rien :
/// le micro se tient, il ne se tape pas. Le brouillon se range à chaque frappe
/// (`RelayStore.setDraft`) et part au Relais une seconde après la dernière,
/// comme sur le Mac.
/// Ce que la main sent pendant le geste du micro : le doigt qui se pose, le
/// verrou qui prend, le message qu'on abandonne, celui qui part.
private enum MicHaptic {
  case held, locked, cancelled, sent

  var feedback: SensoryFeedback {
    switch self {
    case .held, .sent: .impact(weight: .medium)
    case .locked: .success
    case .cancelled: .warning
    }
  }
}

struct ThreadComposer: View {
  let conversationID: String

  @Environment(RelayStore.self) private var store
  @Environment(ThemePreferences.self) private var themes
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @FocusState private var isFocused: Bool

  @State private var photoItems: [PhotosPickerItem] = []
  @State private var isImportingFile = false
  @State private var isTakingPhoto = false
  @State private var isPickingSendLater = false
  /// Ce que la main doit sentir, et le compte qui le déclenche. UN SEUL canal
  /// pour tout le composer : deux `sensoryFeedback` dont l'état bascule dans
  /// la même passe (verrouiller lève le doigt ET pose le verrou) s'annulent
  /// l'un l'autre sur l'appareil, et le verrou ne se sentait pas.
  @State private var hapticTick = 0
  @State private var hapticKind = MicHaptic.held
  /// Le doigt tient le micro : l'enregistrement court sous lui.
  @State private var isHolding = false
  /// Le doigt s'est levé sans lâcher l'enregistrement — glissé vers le haut :
  /// la bande reste, avec son « Annuler » et son envoi.
  @State private var isLocked = false
  /// Où le doigt en est depuis le micro : ce qui fait glisser « Glisser pour annuler ».
  @State private var holdTranslation: CGSize = .zero
  @State private var holdStartedAt = Date()
  /// Ce toucher-ci a COMMENCÉ sur un enregistrement déjà verrouillé : c'est
  /// une tape sur la flèche, pas la suite du maintien qui vient de verrouiller.
  @State private var startedLocked = false
  /// Le chevron du guide respire vers le haut : c'est lui qui dit « par ici ».
  @State private var hintBreathes = false
  /// Les gens du groupe, relus à l'ouverture du fil : taper « @ » ne doit pas
  /// attendre le réseau.
  @State private var members: [RelayStore.ThreadMember] = []

  private var theme: WritingTheme { themes.theme }
  private var typeface: WritingTypeface { themes.typeface }

  private var text: Binding<String> {
    Binding(
      get: { store.draftText(conversationID) },
      set: { store.setDraft($0, conversationID: conversationID) }
    )
  }

  private var placeholder: String {
    if isEditing { return "Corriger le message" }
    guard let network = store.sendingNetwork(conversationID) else { return "Répondre" }
    return "Répondre sur \(network.labelFR)"
  }

  /// Le composer corrige une bulle : le champ le dit, et le bouton d'envoi
  /// envoie la correction (cf. `RelayStore.send`).
  private var isEditing: Bool { store.editingMessage(conversationID) != nil }

  /// Le « @Nom » en train de s'écrire, et les gens qui y répondent. Le même
  /// `MentionParser` que le menu du Mac : une seule règle pour les deux
  /// appareils, et le brouillon envoyé a donc exactement la même forme.
  /// Seulement dans un groupe : en tête-à-tête, on sait à qui l'on parle.
  private var mentionToken: MentionParser.Token? {
    guard store.conversation(conversationID)?.isGroup == true else { return nil }
    return MentionParser.activeToken(in: store.draftText(conversationID))
  }

  private var mentionMatches: [MentionCandidate] {
    guard let mentionToken else { return [] }
    let candidates = members.map { member in
      MentionCandidate(
        id: member.userID,
        name: member.name,
        avatar: .avatarStub(
          network: store.conversation(conversationID)?.network ?? .whatsapp,
          address: member.userID,
          title: member.name
        )
      )
    }
    return MentionParser.matches(candidates, query: mentionToken.query)
  }

  /// Quelque chose coiffe le champ : citation, pièces jointes, micro…
  private var hasStrips: Bool {
    if !mentionMatches.isEmpty { return true }
    if !store.scheduledMessages(for: conversationID).isEmpty { return true }
    if store.replyTarget(conversationID) != nil { return true }
    if isEditing { return true }
    if !store.attachments(conversationID).isEmpty { return true }
    if case .failed = store.recorder.state { return true }
    return false
  }

  /// La bulle se fait enregistreur — même place, même hauteur : rien ne saute
  /// sous le doigt qui tient. Dès qu'il tient, pas quand le micro daigne
  /// démarrer : le rappel « glisser pour annuler » doit être là tout de suite.
  private var isRecordingBubble: Bool {
    if case .failed = store.recorder.state { return false }
    return isHolding || store.recorder.isRecording
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      // Pas de barre pleine largeur : le composer flotte, comme Signal. Ce qui
      // coiffe le champ (citation, pièces jointes, micro) prend sa propre
      // carte de verre plutôt que de s'appuyer sur un fond de fenêtre.
      if hasStrips {
        VStack(alignment: .leading, spacing: 8) {
          if !mentionMatches.isEmpty { mentionStrip }
          if !store.scheduledMessages(for: conversationID).isEmpty {
            scheduledStrip
          }
          if let quoted = store.replyTarget(conversationID) {
            replyChip(quoted)
          }
          if let edited = store.editingMessage(conversationID) {
            editChip(edited)
          }
          if !store.attachments(conversationID).isEmpty {
            attachmentStrip
          }
          if case .failed(let raison) = store.recorder.state { micError(raison) }
        }
        .padding(.vertical, 10)
        .glassSurface(cornerRadius: 18, fallbackFill: theme.paperSecondary, border: theme.edge)
      }
      HStack(alignment: .bottom, spacing: 8) {
        plusTray
        bubble
      }
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.top, 8)
    .padding(.bottom, 8)
    // Le seul canal d'haptique du composer, posé sur une vue qui ne change
    // jamais d'identité : le micro, lui, se transforme sous le doigt.
    .sensoryFeedback(trigger: hapticTick) { _, _ in hapticKind.feedback }
    .onChange(of: photoItems) { _, items in
      guard !items.isEmpty else { return }
      Task { await importPhotos(items) }
    }
    .fileImporter(
      isPresented: $isImportingFile,
      allowedContentTypes: [.item],
      allowsMultipleSelection: true
    ) { result in
      if case .success(let urls) = result { importFiles(urls) }
    }
    .sheet(isPresented: $isPickingSendLater) {
      SendLaterSheet(conversationID: conversationID)
        .environment(store)
        .environment(themes)
    }
    .task {
      // En démonstration, le sélecteur s'ouvre seul : une capture n'a pas de doigt.
      guard store.isDemo, DemoRelay.requestedScreen == .plusTard else { return }
      isPickingSendLater = true
    }
    .task(id: conversationID) { members = await store.members(conversationID) }
    .fullScreenCover(isPresented: $isTakingPhoto) {
      CameraCapture { url in
        if let url { store.addAttachment(url.path, conversationID: conversationID) }
      }
      .ignoresSafeArea()
    }
  }

  // MARK: - Le +

  private var plusTray: some View {
    Menu {
      PhotosPicker(selection: $photoItems, maxSelectionCount: 5, matching: .any(of: [.images, .videos])) {
        Label("Photos", systemImage: "photo.on.rectangle")
      }
      Button { isTakingPhoto = true } label: { Label("Caméra", systemImage: "camera") }
      Button { isImportingFile = true } label: { Label("Fichier", systemImage: "folder") }
      Divider()
      Button {
        isPickingSendLater = true
      } label: {
        Label("Envoyer plus tard", systemImage: "clock")
      }
      .disabled(!store.canSend(conversationID))
    } label: {
      Image(systemName: "plus")
        .font(.system(size: 17, weight: .medium))
        .foregroundStyle(theme.inkSecondary)
        .frame(width: 34, height: 34)
        // Verre non interactif, comme le chevron : la variante interactive
        // avale les touches hors barre d'outils.
        .glassSurface(cornerRadius: 17, fallbackFill: theme.paperSecondary, border: theme.edge)
    }
    .accessibilityLabel("Joindre une photo, une prise de vue ou un fichier")
  }

  // MARK: - Le champ

  private var bubble: some View {
    HStack(alignment: .bottom, spacing: 6) {
      if isRecordingBubble {
        recordingField
      } else {
        TextField(
          "",
          text: text,
          prompt: Text(placeholder).foregroundStyle(theme.inkTertiary),
          axis: .vertical
        )
        .textFieldStyle(.plain)
        .font(Typography.composer(typeface))
        .lineSpacing(theme.bubbleLineSpacing(forBodySize: Typography.composerSize()))
        .foregroundStyle(theme.ink)
        .lineLimit(1...6)
        .focused($isFocused)
        .padding(.leading, 4)
        .padding(.vertical, 6)
      }

      trailingControl
    }
    .padding(.leading, 10)
    .padding(.trailing, 4)
    .padding(.vertical, 4)
    .frame(minHeight: 40)
    .glassSurface(
      cornerRadius: 22,
      fallbackFill: theme.paperSecondary,
      border: isFocused ? theme.accent.opacity(0.4) : theme.edge
    )
  }

  @ViewBuilder
  private var trailingControl: some View {
    if store.isSending(conversationID) {
      ProgressView()
        .frame(width: 32, height: 32)
    } else if store.canSend(conversationID) {
      Button {
        isFocused = false
        haptic(.sent)
        Task { await store.send(conversationID: conversationID) }
      } label: {
        Image(systemName: "arrow.up")
          .font(.system(size: 15, weight: .bold))
          .foregroundStyle(theme.accentInk)
          .frame(width: 32, height: 32)
          .background(Circle().fill(theme.accentFill))
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Envoyer")
    } else {
      micButton
    }
  }

  /// Le micro qu'on maintient. Pas un `Button` : c'est le glissement qui
  /// décide, et un bouton avalerait le geste avant qu'il commence. Une seule
  /// image du repos au verrou : remplacer la vue sous le doigt tuerait le
  /// geste en cours — seul le symbole change.
  private var micButton: some View {
    Image(systemName: isLocked ? "arrow.up" : (isHolding ? "mic.fill" : "mic"))
      .font(.system(size: isLocked ? 15 : 16, weight: isLocked ? .bold : .medium))
      .foregroundStyle(isLocked ? theme.accentInk : (isHolding ? theme.accent : theme.inkTertiary))
      .frame(width: 32, height: 32)
      .background(Circle().fill(isLocked ? theme.accentFill : .clear))
      .scaleEffect(isHolding ? 1.25 : 1)
      .contentShape(Circle())
      .highPriorityGesture(holdToTalk)
      .accessibilityLabel(isLocked ? "Envoyer le message vocal" : "Enregistrer un message vocal")
      .accessibilityHint(isLocked ? "" : "Maintenir pour parler, relâcher pour envoyer")
      .overlay(alignment: .top) { if isHolding, !isLocked { lockGuide } }
  }

  /// Le guide du geste, au-dessus du micro : le cadenas où l'on va, le chevron
  /// qui montre le chemin. Une pastille de verre, exactement celle de la
  /// pilule ↓ du fil (même largeur, même fond, même bord) — c'est la même
  /// famille d'objets flottants, et elle occupe la même place.
  private var lockGuide: some View {
    VStack(spacing: 4) {
      Image(systemName: "lock")
        .font(.system(size: 12, weight: .semibold))
      Image(systemName: "chevron.up")
        .font(.system(size: 11, weight: .semibold))
        .offset(y: hintBreathes ? -3 : 0)
    }
    .foregroundStyle(theme.accent)
    .frame(width: 38)
    .padding(.vertical, 9)
    .glassSurface(cornerRadius: 19, fallbackFill: theme.paperSecondary, border: theme.edge)
    .opacity(lockHintOpacity)
    .offset(y: -58 - min(-min(holdTranslation.height, 0), VoiceHoldGesture.threshold) * 0.2)
    .onAppear {
      guard !reduceMotion else { return }
      withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { hintBreathes = true }
    }
    .onDisappear { hintBreathes = false }
    .accessibilityHidden(true)
  }

  /// L'opacité du cadenas : il se révèle à mesure qu'on monte.
  private var lockHintOpacity: Double {
    min(max(-holdTranslation.height, 0) / VoiceHoldGesture.threshold, 1) * 0.4 + 0.6
  }

  private var holdToTalk: some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        // Verrouillé : le premier relevé d'un toucher n'a pas encore bougé —
        // c'est une tape sur la flèche, et elle enverra. Les suivants sont la
        // fin du geste qui vient de verrouiller : ils ne doivent rien envoyer.
        guard !isLocked else {
          if value.translation == .zero { startedLocked = true }
          return
        }
        if !isHolding, !store.recorder.isRecording {
          // Demander le micro PENDANT le maintien annule le toucher : la
          // première pression ne fait que demander, la suivante enregistre.
          guard VoiceRecorder.hasPermission else {
            Task { if await VoiceRecorder.requestPermission() == false { await store.recorder.start() } }
            return
          }
          isHolding = true
          isLocked = false
          store.isHoldingMic = true
          holdStartedAt = Date()
          isFocused = false
          haptic(.held)
          Task { await store.recorder.start() }
        }
        guard isHolding, !isLocked else { return }
        holdTranslation = value.translation
        switch VoiceHoldGesture.outcome(translation: value.translation) {
        case .recording: break
        case .locked: lock()
        case .cancelled:
          // Le message part à la corbeille sans qu'on regarde l'écran : la
          // main doit le savoir.
          haptic(.cancelled)
          store.recorder.cancel()
          endHold()
        }
      }
      .onEnded { _ in
        if startedLocked {
          startedLocked = false
          endHold()
          sendRecording()
          return
        }
        guard isHolding else { return }
        // Une tape, pas un maintien : on n'a rien voulu dire. Le micro se
        // tient ; une tape n'enregistre pas, ne verrouille pas, n'envoie pas.
        if Date().timeIntervalSince(holdStartedAt) < VoiceHoldGesture.tapDuration {
          store.recorder.cancel()
          endHold()
          return
        }
        endHold()
        sendRecording()
      }
  }

  private func lock() {
    isLocked = true
    isHolding = false
    holdTranslation = .zero
    store.isHoldingMic = true
    haptic(.locked)
  }

  private func endHold() {
    isHolding = false
    isLocked = false
    holdTranslation = .zero
    store.isHoldingMic = false
  }

  /// Une seule vibration à la fois, sur le canal unique : le compteur monte,
  /// la nature dit ce que la main sent.
  private func haptic(_ kind: MicHaptic) {
    hapticKind = kind
    hapticTick += 1
  }

  private func sendRecording() {
    guard let taken = store.recorder.stop() else { return }
    haptic(.sent)
    Task { await store.sendVoiceMessage(taken.url, voice: taken.voice, conversationID: conversationID) }
  }

  /// Ce qu'on est en train de dire, À LA PLACE du champ : la durée qui court,
  /// le niveau du micro, et le geste pour renoncer. « Annuler » n'apparaît
  /// qu'une fois le doigt reparti — tant qu'il tient, c'est le glissement qui
  /// renonce.
  private var recordingField: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(theme.accent)
        .frame(width: 8, height: 8)
        .opacity(0.4 + 0.6 * store.recorder.level)

      Text(VoiceNote(duration: store.recorder.duration).durationLabel)
        .font(Typography.meta(typeface))
        .foregroundStyle(theme.ink)
        .monospacedDigit()

      if isHolding {
        // Le rappel suit le doigt et s'efface à mesure qu'on approche du seuil :
        // on VOIT qu'un pas de plus abandonne le message.
        Text("‹ Glisser pour annuler")
          .font(Typography.meta(typeface))
          .foregroundStyle(theme.inkSecondary)
          .lineLimit(1)
          .offset(x: min(holdTranslation.width, 0))
          .opacity(1 - min(max(-holdTranslation.width, 0) / VoiceHoldGesture.threshold, 1))
          .frame(maxWidth: .infinity, alignment: .trailing)
      } else {
        // Les derniers relevés, qui défilent : on voit qu'on est entendu.
        HStack(alignment: .center, spacing: 1.5) {
          ForEach(Array(store.recorder.samples.suffix(20).enumerated()), id: \.offset) { _, value in
            Capsule()
              .fill(theme.accent.opacity(0.7))
              .frame(width: 2, height: max(3, value * 18))
          }
        }
        .frame(height: 18, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)

        // Le doigt est reparti : c'est le seul moyen de renoncer, et il se lit.
        Button {
          haptic(.cancelled)
          store.recorder.cancel()
          endHold()
        } label: {
          Text("Annuler")
            .font(Typography.meta(typeface))
            .foregroundStyle(theme.accent)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Annuler le message vocal")
      }
    }
    .padding(.leading, 4)
    .padding(.vertical, 6)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Enregistrement en cours")
  }

  private func micError(_ raison: String) -> some View {
    Text(raison)
      .font(Typography.meta(typeface))
      .foregroundStyle(theme.inkSecondary)
      .padding(.horizontal, Spacing.xs)
  }

  /// Les gens qu'on peut désigner, en pastilles qui défilent — le Mac, lui, a
  /// la place d'une liste et le clavier pour la piloter. Une tape pose
  /// « @Nom » dans le brouillon, à la place de ce qu'on avait commencé.
  private var mentionStrip: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(mentionMatches) { candidate in
          Button {
            insertMention(candidate)
          } label: {
            HStack(spacing: 6) {
              MemberAvatar(
                conversationID: conversationID,
                userID: candidate.id,
                name: candidate.name,
                size: 24,
                theme: theme
              )
              Text(candidate.name)
                .font(Typography.meta(typeface))
                .foregroundStyle(theme.ink)
                .lineLimit(1)
            }
            .padding(.leading, 4)
            .padding(.trailing, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(theme.bubbleIn))
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Mentionner \(candidate.name)")
        }
      }
      .padding(.horizontal, Spacing.xs)
    }
    .frame(height: 36)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Mentionner quelqu'un")
  }

  private func insertMention(_ candidate: MentionCandidate) {
    guard let mentionToken else { return }
    store.setDraft(
      MentionParser.insert(candidate, replacing: mentionToken, in: store.draftText(conversationID)),
      conversationID: conversationID
    )
  }

  /// Ce qui attend son heure dans CE fil, au-dessus du champ : sinon un
  /// message programmé disparaîtrait de la vue et reviendrait par surprise.
  private var scheduledStrip: some View {
    let pending = store.scheduledMessages(for: conversationID)
    return HStack(spacing: 6) {
      Image(systemName: "clock")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(theme.accent)
      Text(pending.count == 1
        ? "1 message part \(SendLaterTime.label(for: pending[0].sendAt).lowercased())"
        : "\(pending.count) messages programmés")
        .font(Typography.meta(typeface))
        .foregroundStyle(theme.inkSecondary)
        .lineLimit(1)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, Spacing.xs)
    .accessibilityElement(children: .combine)
  }

  // MARK: - Citation et pièces jointes

  private func replyChip(_ message: ChatMessage) -> some View {
    HStack(spacing: 6) {
      RoundedRectangle(cornerRadius: 1).fill(theme.accent).frame(width: 2)
      VStack(alignment: .leading, spacing: 1) {
        // Le nom, jamais l'identifiant du pont — et jamais « Moi » pour un
        // message reçu : à défaut de nom, le titre du fil dit à qui l'on parle.
        Text(quotedSenderName(message))
          .font(Typography.meta(typeface))
          .foregroundStyle(theme.accent)
        Text(message.sidebarPreviewText)
          .font(Typography.meta(typeface))
          .foregroundStyle(theme.inkSecondary)
          .lineLimit(1)
      }
      Spacer(minLength: 0)
      Button {
        store.setReplyTarget(nil, conversationID: conversationID)
      } label: {
        Image(systemName: "xmark.circle.fill")
          .foregroundStyle(theme.inkTertiary)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Ne plus citer ce message")
    }
    .padding(.horizontal, Spacing.xs)
    // Le trait d'accent n'a pas de hauteur à lui : sans ce garde-fou, il
    // prend celle que l'encart de bas d'écran lui propose — tout l'écran —
    // et la citation recouvre le fil au lieu de coiffer le champ.
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityElement(children: .combine)
  }

  /// Bandeau « correction en cours ». Même forme que la citation : c'est le
  /// même geste, sur l'autre bord du temps — l'un désigne ce à quoi on répond,
  /// l'autre ce qu'on réécrit.
  private func editChip(_ message: ChatMessage) -> some View {
    HStack(spacing: 6) {
      Image(systemName: "pencil")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(theme.accent)
      VStack(alignment: .leading, spacing: 1) {
        Text("Modification du message")
          .font(Typography.meta(typeface))
          .foregroundStyle(theme.accent)
        Text(message.text)
          .font(Typography.meta(typeface))
          .foregroundStyle(theme.inkSecondary)
          .lineLimit(1)
      }
      Spacer(minLength: 0)
      Button {
        store.endEditing(conversationID)
      } label: {
        Image(systemName: "xmark.circle.fill")
          .foregroundStyle(theme.inkTertiary)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Renoncer à la modification")
    }
    .padding(.horizontal, Spacing.xs)
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityElement(children: .combine)
  }

  private func quotedSenderName(_ message: ChatMessage) -> String {
    if message.isFromMe { return "Moi" }
    return message.displayedSenderName
      ?? store.conversation(conversationID)?.title
      ?? "Ce message"
  }

  private var attachmentStrip: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(store.attachments(conversationID), id: \.self) { path in
          ZStack(alignment: .topTrailing) {
            AttachmentImageView(
              url: URL(fileURLWithPath: path),
              maxWidth: 72,
              maxHeight: 72,
              cornerRadius: 10,
              placeholder: theme.bubbleIn,
              border: theme.edge,
              label: URL(fileURLWithPath: path).lastPathComponent
            ) {
              Image(systemName: "doc")
                .frame(width: 72, height: 72)
                .background(theme.bubbleIn, in: RoundedRectangle(cornerRadius: 10))
            }
            Button {
              store.removeAttachment(path, conversationID: conversationID)
            } label: {
              Image(systemName: "xmark.circle.fill")
                .foregroundStyle(theme.paper, theme.ink)
            }
            .buttonStyle(.plain)
            .padding(3)
            .accessibilityLabel("Retirer la pièce jointe")
          }
        }
      }
      .padding(.horizontal, Spacing.xs)
    }
    .frame(height: 78)
  }

  // MARK: - Import

  private func importPhotos(_ items: [PhotosPickerItem]) async {
    for item in items {
      guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
      let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(UUID().uuidString).\(ext)")
      guard (try? data.write(to: url)) != nil else { continue }
      store.addAttachment(url.path, conversationID: conversationID)
    }
    photoItems = []
  }

  /// Un fichier choisi hors du bac à sable arrive sous portée de sécurité :
  /// on le recopie dans le temporaire, sinon l'envoi le trouverait illisible.
  private func importFiles(_ urls: [URL]) {
    for source in urls {
      let scoped = source.startAccessingSecurityScopedResource()
      defer { if scoped { source.stopAccessingSecurityScopedResource() } }
      let destination = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(UUID().uuidString)-\(source.lastPathComponent)")
      guard (try? FileManager.default.copyItem(at: source, to: destination)) != nil else { continue }
      store.addAttachment(destination.path, conversationID: conversationID)
    }
  }
}
