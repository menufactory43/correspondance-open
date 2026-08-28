import SwiftUI

struct ConversationRowView: View {
  let conversation: Conversation
  let isSelected: Bool
  let theme: WritingTheme
  var typeface: WritingTypeface = .quattro
  var isSyncing: Bool = false

  private var subtitle: String {
    if conversation.hasLivePreview { return conversation.preview }
    if isSyncing { return "Synchronisation…" }
    if conversation.isGroup { return "En attente de messages" }
    return conversation.preview
  }

  var body: some View {
    HStack(alignment: .top, spacing: Spacing.sm) {
      Image(systemName: conversation.rowSystemImage)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(theme.accent)
        .frame(width: 22, height: 22)
        .background(theme.selection.opacity(0.85), in: Circle())

      VStack(alignment: .leading, spacing: 3) {
        HStack(alignment: .firstTextBaseline) {
          Text(conversation.title)
            .font(Typography.sidebarItem(typeface))
            .foregroundStyle(theme.ink.opacity(conversation.hasUnread ? 1 : 0.92))
            .lineLimit(1)
          if conversation.isGroup {
            Text("groupe")
              .font(Typography.meta(typeface))
              .foregroundStyle(theme.accent)
              .padding(.horizontal, 5)
              .padding(.vertical, 1)
              .background(theme.selection, in: Capsule())
          }
          Spacer(minLength: 8)
          if conversation.hasUnread {
            UnreadBadge(count: conversation.unreadCount, theme: theme)
          } else if conversation.hasLivePreview {
            Text(conversation.lastMessageAt, style: .relative)
              .font(Typography.meta(typeface))
              .foregroundStyle(theme.inkTertiary)
          }
        }
        Text(subtitle)
          .font(Typography.meta(typeface))
          .foregroundStyle(conversation.hasUnread ? theme.inkSecondary : theme.inkTertiary)
          .lineLimit(2)
      }
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.xs + 2)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(isSelected ? theme.selection : Color.clear)
    )
    .contentShape(Rectangle())
  }
}

private struct UnreadBadge: View {
  let count: Int
  let theme: WritingTheme

  private var label: String {
    count > 99 ? "99+" : "\(max(count, 1))"
  }

  var body: some View {
    Text(label)
      .font(.system(size: 10, weight: .bold, design: .rounded))
      .foregroundStyle(theme.paper)
      .padding(.horizontal, count > 9 ? 6 : 5)
      .padding(.vertical, 2)
      .background(theme.accent, in: Capsule())
      .accessibilityLabel("\(count) nouveaux messages")
  }
}
