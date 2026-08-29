import SwiftUI

struct ConversationRowView: View {
  let conversation: Conversation
  let isSelected: Bool
  let theme: WritingTheme
  var typeface: WritingTypeface = .quattro
  var isSyncing: Bool = false
  var isPinned: Bool = false
  var isMuted: Bool = false
  var isCompact: Bool = false

  private var subtitle: String {
    if conversation.hasLivePreview { return conversation.preview }
    if isSyncing { return "Synchronisation…" }
    if conversation.isGroup { return "En attente de messages" }
    return conversation.preview
  }

  var body: some View {
    Group {
      if isCompact {
        compactBody
      } else {
        expandedBody
      }
    }
  }

  private var compactBody: some View {
    ZStack(alignment: .topTrailing) {
      ConversationAvatarView(conversation: conversation, size: 40, theme: theme)
      if conversation.hasUnread {
        Circle()
          .fill(theme.accent)
          .frame(width: 10, height: 10)
          .overlay(Circle().strokeBorder(theme.sidebar, lineWidth: 1.5))
          .offset(x: 2, y: -1)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 6)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(isSelected ? theme.selection : Color.clear)
    )
    .contentShape(Rectangle())
    .help(conversation.title)
  }

  private var expandedBody: some View {
    HStack(alignment: .center, spacing: Spacing.sm) {
      ConversationAvatarView(conversation: conversation, size: 34, theme: theme)

      VStack(alignment: .leading, spacing: 3) {
        HStack(alignment: .firstTextBaseline) {
          Text(conversation.title)
            .font(Typography.sidebarItem(typeface))
            .foregroundStyle(theme.ink.opacity(conversation.hasUnread ? 1 : 0.92))
            .lineLimit(1)
          if isPinned {
            Image(systemName: "pin.fill")
              .font(.system(size: 9, weight: .semibold))
              .foregroundStyle(theme.inkTertiary)
          }
          if isMuted {
            Image(systemName: "bell.slash.fill")
              .font(.system(size: 9, weight: .semibold))
              .foregroundStyle(theme.inkTertiary)
          }
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
