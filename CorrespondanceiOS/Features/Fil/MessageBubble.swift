import AVKit
import CorrespondanceCore
import CorrespondanceUI
import SwiftUI

/// Une bulle du fil, à la main.
///
/// Le rendu est celui du Mac (`MessageBubbleView`) : mêmes coins, même
/// interligne dérivé du thème, même emoji nu et grand, mêmes citations, mêmes
/// pastilles de réaction, même aperçu de lien. Ce qui change tient au doigt :
/// le survol n'existe pas, donc réagir se fait par appui long (sélecteur en
/// rangée, comme Beeper) et citer par balayage vers la droite sur la bulle.
struct MessageBubble: View {
  let message: ChatMessage
  let theme: WritingTheme
  var typeface: WritingTypeface = .quattro
  /// Nom coloré au-dessus du groupe, en conversation de groupe.
  var senderLabel: String?
  var showsLinkPreviews = true
  var onReact: ((String) -> Void)?
  var onReply: (() -> Void)?
  var onHide: (() -> Void)?
  var onDeleteEverywhere: (() -> Void)?
  /// Voter sur le sondage de cette bulle. `nil` = sondage en lecture seule.
  var onVotePoll: ((String) -> Void)?

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isPickingReaction = false
  @State private var dragOffset: CGFloat = 0
  @State private var pendingDeletion = false

  private var bodySize: CGFloat { Typography.bubbleSize() }

  var body: some View {
    VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 4) {
      if let senderLabel, !message.isFromMe {
        Text(senderLabel)
          .font(Typography.meta(typeface))
          .fontWeight(.semibold)
          .foregroundStyle(Self.senderColor(senderLabel, theme: theme))
          .padding(.leading, 14)
          .accessibilityHidden(true)
      }

      HStack(spacing: 0) {
        if message.isFromMe { Spacer(minLength: 44) }
        bubbleStack
        if !message.isFromMe { Spacer(minLength: 44) }
      }
    }
    .offset(x: dragOffset)
    .gesture(replyDrag)
    .frame(maxWidth: .infinity, alignment: message.isFromMe ? .trailing : .leading)
    .alert("Supprimer ce message pour tout le monde ?", isPresented: $pendingDeletion) {
      Button("Supprimer", role: .destructive) { onDeleteEverywhere?() }
      Button("Annuler", role: .cancel) {}
    } message: {
      Text("Il disparaît du fil, chez toi comme chez ton correspondant. C'est sans retour.")
    }
  }

  private var bubbleStack: some View {
    VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 6) {
      if let quote = message.replyTo, !quote.isEmpty {
        quoteChip(quote)
      }

      ForEach(visibleAttachments) { attachment in
        attachmentView(attachment)
      }

      if let poll = message.poll {
        PollView(
          poll: poll,
          theme: theme,
          typeface: typeface,
          isFromMe: message.isFromMe,
          onVote: onVotePoll
        )
      } else if message.isRetracted {
        retractedBubble
      } else if message.isEmojiOnly {
        Text(displayText)
          .font(.system(size: 44))
          .padding(.horizontal, 2)
          .accessibilityLabel(displayText)
      } else if showsTextBubble {
        Text(highlighted)
          .font(Typography.bubble(typeface))
          .lineSpacing(theme.bubbleLineSpacing(forBodySize: bodySize))
          .foregroundStyle(message.isFromMe ? theme.bubbleOutInk : theme.bubbleInInk)
          .textSelection(.enabled)
          .padding(.horizontal, 13)
          .padding(.vertical, 9)
          .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
              .fill(message.isFromMe ? theme.bubbleOut : theme.bubbleIn)
          )
      }

      if let link = previewedLink {
        LinkPreviewCard(url: link, theme: theme, typeface: typeface, bridged: bridgedPreview)
      }

      if let footnote = footnoteLabel {
        Text(footnote)
          .font(Typography.meta(typeface))
          .foregroundStyle(theme.inkTertiary)
      }

      if !message.reactions.isEmpty {
        reactionRow
      }
    }
    .opacity(message.isPending ? 0.55 : 1)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLine)
    // LA LONGUEUR DE LIGNE, comme sur le Mac : sans plafond, une phrase
    // traverserait tout un iPad et l'œil ne retrouverait plus le début de la
    // ligne suivante. Le cadre borne la largeur PROPOSÉE, la pile continue
    // d'épouser son contenu — les pastilles ne s'étirent donc pas.
    .frame(
      maxWidth: 520,
      alignment: message.isFromMe ? .trailing : .leading
    )
    .contextMenu { bubbleMenu }
    .popover(isPresented: $isPickingReaction, arrowEdge: .top) {
      reactionPicker
        .presentationCompactAdaptation(.popover)
    }
  }

  // MARK: - Gestes

  /// Répondre en citant se fait par balayage vers la droite sur la bulle — le
  /// geste de WhatsApp, de Signal et de Beeper. Le retour au repos est animé,
  /// sauf sous « Réduire les animations ».
  private var replyDrag: some Gesture {
    DragGesture(minimumDistance: 18)
      .onChanged { value in
        guard onReply != nil, value.translation.width > 0 else { return }
        dragOffset = min(value.translation.width * 0.5, 56)
      }
      .onEnded { _ in
        let triggered = dragOffset > 34
        if reduceMotion { dragOffset = 0 }
        else { withAnimation(.spring(duration: 0.28)) { dragOffset = 0 } }
        if triggered { onReply?() }
      }
  }

  private var reactionPicker: some View {
    HStack(spacing: 2) {
      ForEach(RelayStore.quickReactions, id: \.self) { emoji in
        Button {
          isPickingReaction = false
          onReact?(emoji)
        } label: {
          Text(emoji)
            .font(.system(size: 26))
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .background(
              Capsule().fill(message.myReactionEmoji == emoji ? theme.selection : .clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
          message.myReactionEmoji == emoji ? "Retirer la réaction \(emoji)" : "Réagir \(emoji)"
        )
      }
    }
    .padding(8)
    .background(theme.paperSecondary)
  }

  @ViewBuilder
  private var bubbleMenu: some View {
    if onReact != nil {
      Button {
        isPickingReaction = true
      } label: {
        Label("Réagir…", systemImage: "face.smiling")
      }
    }
    if let onReply {
      Button { onReply() } label: { Label("Répondre en citant", systemImage: "arrowshape.turn.up.left") }
    }
    if !message.text.isEmpty {
      Button {
        Platform.copyToPasteboard(message.text)
      } label: {
        Label("Copier le texte", systemImage: "doc.on.doc")
      }
    }
    Divider()
    if onDeleteEverywhere != nil {
      Button(role: .destructive) { pendingDeletion = true } label: {
        Label("Supprimer pour tout le monde…", systemImage: "trash")
      }
    }
    if let onHide {
      Button(role: .destructive) { onHide() } label: {
        Label("Supprimer ici", systemImage: "eye.slash")
      }
    }
  }

  // MARK: - Morceaux

  private var retractedBubble: some View {
    Text("Message annulé")
      .font(Typography.bubble(typeface).italic())
      .foregroundStyle(theme.inkTertiary)
      .padding(.horizontal, 13)
      .padding(.vertical, 9)
      .background(
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .strokeBorder(theme.edge, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
      )
      .accessibilityLabel("Message annulé par son auteur")
  }

  private func quoteChip(_ quote: QuotedMessage) -> some View {
    HStack(spacing: 6) {
      RoundedRectangle(cornerRadius: 1, style: .continuous)
        .fill(theme.accent.opacity(0.6))
        .frame(width: 2)
      VStack(alignment: .leading, spacing: 1) {
        if !quote.senderName.isEmpty {
          Text(quote.senderName)
            .font(Typography.meta(typeface))
            .foregroundStyle(theme.accent)
        }
        Text(quote.text)
          .font(Typography.meta(typeface))
          .foregroundStyle(theme.inkSecondary)
          .lineLimit(2)
      }
    }
    .padding(.leading, 2)
    .frame(maxWidth: 260, alignment: .leading)
    .accessibilityLabel("En réponse à \(quote.senderName) : \(quote.text)")
  }

  private var reactionRow: some View {
    HStack(spacing: 4) {
      ForEach(message.reactions) { reaction in
        Button {
          onReact?(reaction.emoji)
        } label: {
          HStack(spacing: 3) {
            Text(reaction.emoji).font(.system(size: 13))
            if reaction.count > 1 {
              Text("\(reaction.count)")
                .font(Typography.meta(typeface))
                .foregroundStyle(theme.inkSecondary)
            }
          }
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(Capsule().fill(theme.paperSecondary))
          .overlay(Capsule().stroke(reaction.isMine ? theme.accent : theme.edge, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(reaction.emoji), \(reaction.count)")
      }
    }
  }

  private var footnoteLabel: String? {
    var parts: [String] = []
    if message.editedAt != nil, !message.isRetracted { parts.append("Modifié") }
    if let effect = message.expressiveEffectName, !message.isRetracted {
      parts.append("envoyé avec \(effect)")
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  @ViewBuilder
  private func attachmentView(_ attachment: MessageAttachment) -> some View {
    let repaired = Self.repaired(attachment)
    if repaired.isAudio, repaired.resolvedFileURL != nil {
      AudioMessageView(
        attachment: repaired,
        theme: theme,
        typeface: typeface,
        isFromMe: message.isFromMe
      )
    } else if let url = repaired.resolvedFileURL, repaired.isGIF {
      // Un GIF se joue : montrer sa première trame, ce serait le rater.
      AnimatedImageView(
        url: url,
        maxWidth: 300,
        maxHeight: 420,
        cornerRadius: 16,
        placeholder: theme.bubbleIn,
        label: repaired.filename ?? "image animée"
      )
    } else if let url = repaired.resolvedFileURL, repaired.isImage {
      // En grand : sur un écran de téléphone, une photo de 280 points est un
      // timbre. On la laisse prendre la largeur utile de la bulle.
      AttachmentImageView(
        url: url,
        maxWidth: 300,
        maxHeight: 420,
        cornerRadius: 16,
        placeholder: theme.bubbleIn,
        border: theme.edge.opacity(0.5),
        label: repaired.filename ?? "Image"
      ) {
        unavailable(repaired, systemImage: "photo")
      }
    } else if let url = repaired.resolvedFileURL, repaired.isVideo {
      VideoPlayer(player: AVPlayer(url: url))
        .frame(width: 300, height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(theme.edge.opacity(0.5), lineWidth: 1)
        )
        .accessibilityLabel(repaired.filename ?? "Vidéo")
    } else if repaired.isImage {
      unavailable(repaired, systemImage: "photo")
    } else {
      unavailable(repaired, systemImage: "paperclip")
    }
  }

  private func unavailable(_ attachment: MessageAttachment, systemImage: String) -> some View {
    Label(attachment.filename ?? "Pièce jointe", systemImage: systemImage)
      .font(Typography.meta(typeface))
      .foregroundStyle(theme.inkSecondary)
      .padding(10)
      .background(theme.bubbleIn, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  // MARK: - Texte

  private var visibleAttachments: [MessageAttachment] {
    message.attachments.map(Self.repaired).filter {
      $0.isImage || $0.isVideo || $0.resolvedFileURL != nil
    }
  }

  private var displayText: String {
    let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let hasVisibleImage = message.attachments.contains {
      let repaired = Self.repaired($0)
      return repaired.isImage && repaired.resolvedFileURL != nil
    }
    if hasVisibleImage, trimmed.isEmpty || trimmed == "📷 Photo" { return "" }
    let hasPlayableAudio = message.attachments.contains {
      let repaired = Self.repaired($0)
      return repaired.isAudio && repaired.resolvedFileURL != nil
    }
    if hasPlayableAudio, trimmed.isEmpty || trimmed == "🎤 Message audio" { return "" }
    return trimmed
  }

  private var showsTextBubble: Bool { !displayText.isEmpty }

  private var previewedLink: URL? {
    guard showsLinkPreviews, !message.isRetracted, !message.isEmojiOnly, showsTextBubble
    else { return nil }
    // L'aperçu livré par le réseau désigne son adresse ; sinon la première du texte.
    if let bridged = message.linkPreview, bridgedPreview != nil, let url = bridged.webURL { return url }
    return TextLinks.firstWebURL(in: displayText)
  }

  /// L'aperçu déjà produit côté réseau, s'il a de quoi faire une carte.
  private var bridgedPreview: LinkPreview? { message.linkPreview?.asLinkPreview }

  private var highlighted: AttributedString {
    LinkedText.render(
      text: displayText,
      tint: message.isFromMe ? theme.bubbleOutInk : theme.accent
    )
  }

  private var accessibilityLine: String {
    var parts: [String] = []
    if let senderLabel, !message.isFromMe { parts.append(senderLabel) }
    parts.append(message.isFromMe ? "Moi" : "Reçu")
    parts.append(message.sidebarPreviewText)
    parts.append(message.sentAt.formatted(date: .omitted, time: .shortened))
    for reaction in message.reactions { parts.append("\(reaction.emoji) \(reaction.count)") }
    return parts.joined(separator: ", ")
  }

  private static func repaired(_ attachment: MessageAttachment) -> MessageAttachment {
    if attachment.resolvedFileURL != nil { return attachment }
    var copy = attachment
    if let path = MatrixAttachmentStore.existingLocalPath(
      forMXC: attachment.id,
      contentType: attachment.contentType
    ) {
      copy.localPath = path
    }
    return copy
  }

  /// La couleur d'un nom dans un groupe. Stable (dérivée du nom), et tirée des
  /// teintes du thème plutôt que d'une palette étrangère : le fil garde son
  /// ambiance même quand douze personnes y parlent.
  static func senderColor(_ name: String, theme: WritingTheme) -> Color {
    var hash = 0
    for scalar in name.unicodeScalars { hash = (hash &* 31) &+ Int(scalar.value) }
    let hue = Double(abs(hash) % 360) / 360
    return Color(
      hue: hue,
      saturation: theme.isDark ? 0.45 : 0.62,
      brightness: theme.isDark ? 0.86 : 0.52
    )
  }
}
