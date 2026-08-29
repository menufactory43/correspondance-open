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

        if showsTextBubble {
          Text(highlighted)
            .font(Typography.bubble(typeface))
            .foregroundStyle(message.isFromMe ? theme.paper : theme.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
              RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(message.isFromMe ? theme.accent : theme.paperSecondary)
            )
        }

        if !message.reactions.isEmpty {
          reactionRow
        }

        Text(message.sentAt, format: .dateTime.hour().minute())
          .font(Typography.meta(typeface))
          .foregroundStyle(theme.inkTertiary)
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
      .contextMenu { bubbleMenu }
      if !message.isFromMe { Spacer(minLength: 48) }
    }
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
    guard !ranges.isEmpty else { return attributed }
    let tint = isCurrentMatch ? theme.accent.opacity(0.55) : theme.accent.opacity(0.22)
    for range in ranges {
      guard let bounds = Range(range, in: attributed) else { continue }
      attributed[bounds].backgroundColor = message.isFromMe ? theme.paper.opacity(0.35) : tint
    }
    return attributed
  }

  @ViewBuilder
  private func attachmentView(_ attachment: MessageAttachment) -> some View {
    let repaired = Self.repaired(attachment)
    if let url = repaired.resolvedFileURL, repaired.isImage,
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
        .background(theme.paperSecondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture { NSWorkspace.shared.open(url) }
        .help("Ouvrir la vidéo")
    } else if repaired.isImage {
      Label(repaired.filename ?? "Image indisponible", systemImage: "photo")
        .font(Typography.meta)
        .foregroundStyle(theme.inkSecondary)
        .padding(10)
        .background(theme.paperSecondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    } else {
      Label(repaired.filename ?? "Pièce jointe", systemImage: "paperclip")
        .font(Typography.meta)
        .foregroundStyle(theme.inkSecondary)
        .padding(10)
        .background(theme.paperSecondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
  }

  /// Ré-attache le fichier Signal si le chemin en cache est périmé.
  private static func repaired(_ attachment: MessageAttachment) -> MessageAttachment {
    if attachment.resolvedFileURL != nil { return attachment }
    var copy = attachment
    if let path = SignalAttachmentStore.localPath(forAttachmentID: attachment.id) {
      copy.localPath = path
    }
    return copy
  }
}
