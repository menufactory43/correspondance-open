import CorrespondanceCore
import CorrespondanceUI
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Le composer du fil.
///
/// **+** à gauche (Photos / Caméra / Fichier), le champ « Répondre sur
/// {Réseau} » au centre, le micro à droite — inactif jusqu'à la phase D, où
/// l'enregistrement vocal arrive. Le brouillon se range à chaque frappe
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

  private var theme: WritingTheme { themes.theme }
  private var typeface: WritingTypeface { themes.typeface }

  private var text: Binding<String> {
    Binding(
      get: { store.draftText(conversationID) },
      set: { store.setDraft($0, conversationID: conversationID) }
    )
  }

  private var placeholder: String {
    guard let network = store.sendingNetwork(conversationID) else { return "Répondre" }
    return "Répondre sur \(network.labelFR)"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let quoted = store.replyTarget(conversationID) {
        replyChip(quoted)
      }
      if !store.attachments(conversationID).isEmpty {
        attachmentStrip
      }
      HStack(alignment: .bottom, spacing: 8) {
        plusTray
        bubble
      }
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.top, 8)
    .padding(.bottom, 8)
    .background(.bar)
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
    } label: {
      Image(systemName: "plus")
        .font(.system(size: 17, weight: .medium))
        .foregroundStyle(theme.inkSecondary)
        .frame(width: 34, height: 34)
        .background(Circle().fill(theme.paperSecondary))
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
    } else {
      Button {
        // Phase D : enregistrement vocal + transcription.
      } label: {
        Image(systemName: "mic")
          .font(.system(size: 16, weight: .medium))
          .foregroundStyle(theme.inkTertiary)
          .frame(width: 32, height: 32)
      }
      .buttonStyle(.plain)
      .disabled(true)
      .accessibilityLabel("Message vocal (bientôt)")
    }
  }

  // MARK: - Citation et pièces jointes

  private func replyChip(_ message: ChatMessage) -> some View {
    HStack(spacing: 6) {
      RoundedRectangle(cornerRadius: 1).fill(theme.accent).frame(width: 2)
      VStack(alignment: .leading, spacing: 1) {
        Text(message.displayedSenderName ?? "Moi")
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
    .accessibilityElement(children: .combine)
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
