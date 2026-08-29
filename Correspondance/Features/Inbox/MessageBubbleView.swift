import AppKit
import SwiftUI

struct MessageBubbleView: View {
  let message: ChatMessage
  let theme: WritingTheme
  var typeface: WritingTypeface = .quattro

  var body: some View {
    HStack {
      if message.isFromMe { Spacer(minLength: 48) }
      VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 6) {
        ForEach(visibleAttachments) { attachment in
          attachmentView(attachment)
        }

        if showsTextBubble {
          Text(displayText)
            .font(Typography.bubble(typeface))
            .foregroundStyle(message.isFromMe ? theme.bubbleOutInk : theme.bubbleInInk)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
              RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(message.isFromMe ? theme.bubbleOut : theme.bubbleIn)
            )
        }

        Text(message.sentAt, format: .dateTime.hour().minute())
          .font(Typography.meta(typeface))
          .foregroundStyle(theme.inkTertiary)
      }
      .opacity(message.isPending ? 0.55 : 1)
      if !message.isFromMe { Spacer(minLength: 48) }
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
