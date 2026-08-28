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
        ForEach(message.attachments.filter(\.isImage)) { attachment in
          attachmentImage(attachment)
        }

        if !message.text.isEmpty {
          Text(message.text)
            .font(Typography.bubble(typeface))
            .foregroundStyle(message.isFromMe ? theme.paper : theme.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
              RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(message.isFromMe ? theme.accent : theme.paperSecondary)
            )
        } else if message.attachments.isEmpty {
          EmptyView()
        }

        Text(message.sentAt, format: .dateTime.hour().minute())
          .font(Typography.meta(typeface))
          .foregroundStyle(theme.inkTertiary)
      }
      .opacity(message.isPending ? 0.55 : 1)
      if !message.isFromMe { Spacer(minLength: 48) }
    }
  }

  @ViewBuilder
  private func attachmentImage(_ attachment: MessageAttachment) -> some View {
    if let url = attachment.resolvedFileURL,
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
    } else {
      Label(attachment.filename ?? "Image", systemImage: "photo")
        .font(Typography.meta)
        .foregroundStyle(theme.inkSecondary)
        .padding(10)
        .background(theme.paperSecondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
  }
}
