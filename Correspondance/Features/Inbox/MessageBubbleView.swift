import AppKit
import SwiftUI

struct MessageBubbleView: View {
  let message: ChatMessage
  let theme: WritingTheme
  var typeface: WritingTypeface = .quattro
  /// Requête ⌘F à surligner dans le corps du message. Vide = aucun surlignage.
  var highlightQuery: String = ""
  /// Ce message est celui que la navigation ⌘F vise en ce moment.
  var isCurrentMatch: Bool = false
  /// La bulle est celle que visent les actions du fil (⌘⇧R, ⌘R).
  var isSelected: Bool = false
  /// `nil` en aperçu : la bulle est alors purement décorative.
  var onReact: ((String) -> Void)?
  var onSelect: (() -> Void)?
  var onReply: (() -> Void)?
  /// Lot M2 — modifier / annuler l'envoi d'un iMessage, via l'automatisation
  /// Accessibilité. `nil` = le réseau (ou le réglage) ne le permet pas.
  var onEdit: ((String) -> Void)?
  var onUndoSend: (() -> Void)?

  /// Feuille « Modifier le message ».
  @State private var isEditing = false
  @State private var editedText = ""

  var body: some View {
    HStack {
      if message.isFromMe { Spacer(minLength: 48) }
      VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 6) {
        if let quote = message.replyTo, !quote.isEmpty {
          quoteChip(quote)
        }

        ForEach(visibleAttachments) { attachment in
          attachmentView(attachment)
        }

        if message.isRetracted {
          retractedBubble
        } else if showsTextBubble {
          Text(highlighted)
            .font(Typography.bubble(typeface))
            .foregroundStyle(message.isFromMe ? theme.bubbleOutInk : theme.bubbleInInk)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
              RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(message.isFromMe ? theme.bubbleOut : theme.bubbleIn)
            )
        }

        if let footnote = footnoteLabel {
          Text(footnote.text)
            .font(Typography.meta(typeface))
            .foregroundStyle(theme.inkTertiary)
            .help(footnote.help)
            .accessibilityLabel(footnote.help)
        }

        if !message.reactions.isEmpty {
          reactionRow
        }
      }
      .opacity(message.isPending ? 0.55 : 1)
      .padding(.horizontal, 4)
      .padding(.vertical, 2)
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(isSelected ? theme.accent.opacity(0.10) : .clear)
      )
      .contentShape(Rectangle())
      .onTapGesture { onSelect?() }
      // L'heure a quitté le dessous de chaque bulle (elle noyait le fil) : elle
      // reste accessible au survol, comme dans Messages.
      .help(message.sentAt.formatted(date: .abbreviated, time: .shortened))
      .accessibilityElement(children: .combine)
      .accessibilityValue(message.sentAt.formatted(date: .omitted, time: .shortened))
      .contextMenu { bubbleMenu }
      if !message.isFromMe { Spacer(minLength: 48) }
    }
    .alert("Modifier le message", isPresented: $isEditing) {
      TextField("Nouveau texte", text: $editedText)
      Button("Annuler", role: .cancel) {}
      Button("Modifier") { onEdit?(editedText) }
    } message: {
      Text("Messages n’autorise la modification que 15 minutes après l’envoi.")
    }
  }

  /// Un envoi annulé laisse sa place dans le fil, vidée : Messages fait pareil,
  /// et effacer la bulle ferait mentir la conversation.
  private var retractedBubble: some View {
    Text("Message annulé")
      .font(Typography.bubble(typeface).italic())
      .foregroundStyle(theme.inkTertiary)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .strokeBorder(theme.edge, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
      )
      .accessibilityLabel("Message annulé par son auteur")
  }

  /// Mention sous la bulle : « Modifié » (historique au survol) ou l'effet reçu.
  /// Les deux ensemble tiennent sur une ligne, séparés d'un point médian.
  private var footnoteLabel: (text: String, help: String)? {
    var parts: [String] = []
    var help: [String] = []
    if message.editedAt != nil, !message.isRetracted {
      parts.append("Modifié")
      if message.editHistory.isEmpty {
        help.append("Message modifié après envoi")
      } else {
        help.append(
          "Versions précédentes :\n"
            + message.editHistory.map { "• \($0)" }.joined(separator: "\n")
        )
      }
    }
    if let effect = message.expressiveEffectName, !message.isRetracted {
      parts.append("envoyé avec \(effect)")
      help.append("Effet d’envoi : \(effect)")
    }
    guard !parts.isEmpty else { return nil }
    return (parts.joined(separator: " · "), help.joined(separator: "\n\n"))
  }

  /// Citation compacte au-dessus de la bulle : un filet, l'auteur, une ligne de texte.
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

  /// Pastilles sous la bulle : emoji, compteur au-delà d'une personne, et un liseré
  /// quand j'en fais partie. Cliquer une pastille repose (donc retire) le même emoji.
  private var reactionRow: some View {
    HStack(spacing: 4) {
      ForEach(message.reactions) { reaction in
        Button {
          onReact?(reaction.emoji)
        } label: {
          HStack(spacing: 3) {
            Text(reaction.emoji).font(.system(size: 11))
            if reaction.count > 1 {
              Text("\(reaction.count)")
                .font(Typography.meta(typeface))
                .foregroundStyle(theme.inkSecondary)
            }
          }
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(
            Capsule().fill(theme.paperSecondary)
          )
          .overlay(
            Capsule().stroke(reaction.isMine ? theme.accent : theme.edge, lineWidth: 1)
          )
        }
        .buttonStyle(.plain)
        .help(reaction.senders.isEmpty ? reaction.emoji : reaction.senders.joined(separator: ", "))
        .accessibilityLabel("\(reaction.emoji), \(reaction.count)")
      }
    }
  }

  @ViewBuilder
  private var bubbleMenu: some View {
    if let onReply {
      Button("Répondre en citant") { onReply() }
      Divider()
    }
    if onReact != nil {
      ForEach(InboxStore.quickReactions, id: \.self) { emoji in
        Button {
          onReact?(emoji)
        } label: {
          // Le même emoji déjà posé : le menu propose alors de le retirer.
          Text(message.myReactionEmoji == emoji ? "\(emoji)  Retirer" : emoji)
        }
      }
    }
    if onEdit != nil || onUndoSend != nil {
      Divider()
      if onEdit != nil {
        Button("Modifier…") {
          editedText = message.text
          isEditing = true
        }
      }
      if let onUndoSend {
        Button("Annuler l’envoi") { onUndoSend() }
      }
    }
    if !message.text.isEmpty {
      Divider()
      Button("Copier le texte") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
      }
    }
  }

  private var visibleAttachments: [MessageAttachment] {
    message.attachments.map(Self.repaired).filter { $0.isImage || $0.isVideo || $0.resolvedFileURL != nil }
  }

  private var displayText: String {
    let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let hasVisibleImage = message.attachments.contains {
      let repaired = Self.repaired($0)
      return repaired.isImage && repaired.resolvedFileURL != nil
    }
    if hasVisibleImage, trimmed.isEmpty || trimmed == "📷 Photo" {
      return ""
    }
    // Un audio joué sur place n'a pas besoin de son libellé de secours.
    let hasPlayableAudio = message.attachments.contains {
      let repaired = Self.repaired($0)
      return repaired.isAudio && repaired.resolvedFileURL != nil
    }
    if hasPlayableAudio, trimmed.isEmpty || trimmed == "🎤 Message audio" {
      return ""
    }
    return trimmed
  }

  private var showsTextBubble: Bool {
    !displayText.isEmpty
  }

  /// Corps du message avec les occurrences de la requête ⌘F surlignées.
  /// Le message visé par la navigation est marqué plus franchement que les autres.
  private var highlighted: AttributedString {
    var attributed = AttributedString(displayText)
    let ranges = ConversationSearch.highlightRanges(in: displayText, query: highlightQuery)
    let tint = isCurrentMatch ? theme.accent.opacity(0.55) : theme.accent.opacity(0.22)
    for range in ranges {
      guard let bounds = Range(range, in: attributed) else { continue }
      attributed[bounds].backgroundColor = message.isFromMe ? theme.paper.opacity(0.35) : tint
    }
    // Les liens par-dessus le surlignage : les deux se voient, l'un colore le fond,
    // l'autre l'encre. L'encre d'accent tient sur les deux bulles des six thèmes.
    return LinkedText.render(
      text: displayText,
      tint: message.isFromMe ? theme.bubbleOutInk : theme.accent,
      base: attributed
    )
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
    } else if let url = repaired.resolvedFileURL, repaired.isImage,
       let nsImage = NSImage(contentsOf: url)
    {
      Image(nsImage: nsImage)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(maxWidth: 280, maxHeight: 320)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(theme.edge.opacity(0.5), lineWidth: 1)
        )
        .accessibilityLabel(repaired.filename ?? "Image")
    } else if let url = repaired.resolvedFileURL, repaired.isVideo {
      Label(repaired.filename ?? "Vidéo", systemImage: "video.fill")
        .font(Typography.meta)
        .foregroundStyle(theme.inkSecondary)
        .padding(10)
        .background(theme.bubbleIn, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture { NSWorkspace.shared.open(url) }
        .help("Ouvrir la vidéo")
    } else if repaired.isImage {
      Label(repaired.filename ?? "Image indisponible", systemImage: "photo")
        .font(Typography.meta)
        .foregroundStyle(theme.inkSecondary)
        .padding(10)
        .background(theme.bubbleIn, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    } else {
      Label(repaired.filename ?? "Pièce jointe", systemImage: "paperclip")
        .font(Typography.meta)
        .foregroundStyle(theme.inkSecondary)
        .padding(10)
        .background(theme.bubbleIn, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
  }

  /// Ré-attache le fichier si le chemin en cache est périmé. L'identifiant d'une
  /// pièce jointe bridgée est son MXC : le média déjà téléchargé se retrouve sous
  /// ce nom, sans redemander quoi que ce soit au serveur.
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
}
