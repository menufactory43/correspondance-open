import CorrespondanceCore
import CorrespondanceUI
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Le composer du fil.
///
/// **+** à gauche (Photos / Caméra / Fichier), le champ « Répondre sur
/// {Réseau} » au centre, le micro à droite : un appui commence à enregistrer,
/// le suivant envoie le vocal. Le brouillon se range à chaque frappe
/// (`RelayStore.setDraft`) et part au Relais une seconde après la dernière,
/// comme sur le Mac.
struct ThreadComposer: View {
  let conversationID: String

  @Environment(RelayStore.self) private var store
  @Environment(ThemePreferences.self) private var themes
  @FocusState private var isFocused: Bool

  @State private var photoItems: [PhotosPickerItem] = []
  @State private var isImportingFile = false
  @State private var isTakingPhoto = false
  @State private var isPickingSendLater = false

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

  /// Quelque chose coiffe le champ : citation, pièces jointes, micro…
  private var hasStrips: Bool {
    if !store.scheduledMessages(for: conversationID).isEmpty { return true }
    if store.replyTarget(conversationID) != nil { return true }
    if isEditing { return true }
    if !store.attachments(conversationID).isEmpty { return true }
    if store.recorder.isRecording { return true }
    if case .failed = store.recorder.state { return true }
    return false
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      // Pas de barre pleine largeur : le composer flotte, comme Signal. Ce qui
      // coiffe le champ (citation, pièces jointes, micro) prend sa propre
      // carte de verre plutôt que de s'appuyer sur un fond de fenêtre.
      if hasStrips {
        VStack(alignment: .leading, spacing: 8) {
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
          if store.recorder.isRecording { recordingStrip }
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
    } else if store.recorder.isRecording {
      Button {
        guard let taken = store.recorder.stop() else { return }
        Task { await store.sendVoiceMessage(taken.url, voice: taken.voice, conversationID: conversationID) }
      } label: {
        Image(systemName: "arrow.up")
          .font(.system(size: 15, weight: .bold))
          .foregroundStyle(theme.accentInk)
          .frame(width: 32, height: 32)
          .background(Circle().fill(theme.accentFill))
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Envoyer le message vocal")
    } else {
      Button {
        isFocused = false
        Task { await store.recorder.start() }
      } label: {
        Image(systemName: "mic")
          .font(.system(size: 16, weight: .medium))
          .foregroundStyle(theme.inkTertiary)
          .frame(width: 32, height: 32)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Enregistrer un message vocal")
    }
  }

  /// Ce qu'on est en train de dire : la durée qui court, le niveau du micro,
  /// et le geste pour renoncer. Le bouton d'envoi, lui, est à sa place.
  private var recordingStrip: some View {
    HStack(spacing: 8) {
      Button {
        store.recorder.cancel()
      } label: {
        Image(systemName: "trash")
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(theme.inkTertiary)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Abandonner le message vocal")

      Circle()
        .fill(theme.accent)
        .frame(width: 8, height: 8)
        .opacity(0.4 + 0.6 * store.recorder.level)

      Text(VoiceNote(duration: store.recorder.duration).durationLabel)
        .font(Typography.meta(typeface))
        .foregroundStyle(theme.ink)
        .monospacedDigit()

      // Les derniers relevés, qui défilent : on voit qu'on est entendu.
      HStack(alignment: .center, spacing: 1.5) {
        ForEach(Array(store.recorder.samples.suffix(40).enumerated()), id: \.offset) { _, value in
          Capsule()
            .fill(theme.accent.opacity(0.7))
            .frame(width: 2, height: max(3, value * 18))
        }
      }
      .frame(height: 18, alignment: .trailing)
      .frame(maxWidth: .infinity, alignment: .trailing)
    }
    .padding(.horizontal, Spacing.xs)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Enregistrement en cours")
  }

  private func micError(_ raison: String) -> some View {
    Text(raison)
      .font(Typography.meta(typeface))
      .foregroundStyle(theme.inkSecondary)
      .padding(.horizontal, Spacing.xs)
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
