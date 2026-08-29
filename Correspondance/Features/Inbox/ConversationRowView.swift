import SwiftUI

struct ConversationRowView: View {
  let conversation: Conversation
  let theme: WritingTheme
  var typeface: WritingTypeface = .quattro
  var isSyncing: Bool = false
  var isPinned: Bool = false
  var isMuted: Bool = false

  private var subtitle: String {
    if conversation.hasLivePreview { return conversation.preview }
    if isSyncing { return "Synchronisation…" }
    if conversation.isGroup { return "En attente de messages" }
    return conversation.preview
  }

  var body: some View {
    HStack(alignment: .top, spacing: Spacing.sm) {
      ConversationAvatarView(conversation: conversation, size: 36, theme: theme)
        .overlay(alignment: .bottomTrailing) {
          NetworkPip(network: conversation.network, theme: theme)
            .offset(x: 2, y: 2)
        }

      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
          Text(conversation.title)
            .font(Typography.sidebarItem(typeface))
            .fontWeight(conversation.hasUnread ? .semibold : .regular)
            .foregroundStyle(theme.ink)
            .lineLimit(1)
            .truncationMode(.tail)
          if isPinned {
            Image(systemName: "pin.fill")
              .font(.system(size: 8, weight: .semibold))
              .foregroundStyle(theme.inkTertiary)
              .accessibilityLabel("Épinglée")
          }
          if isMuted {
            Image(systemName: "bell.slash.fill")
              .font(.system(size: 8, weight: .semibold))
              .foregroundStyle(theme.inkTertiary)
              .accessibilityLabel("Notifications coupées")
          }
          Spacer(minLength: 6)
          if conversation.hasLivePreview {
            Text(Self.shortDate(conversation.lastMessageAt))
              .font(Typography.meta(typeface))
              .monospacedDigit()
              .foregroundStyle(theme.inkTertiary)
              .lineLimit(1)
              .layoutPriority(1)
          }
        }

        HStack(alignment: .top, spacing: 4) {
          if let delivery = conversation.lastDelivery {
            Image(systemName: delivery.systemImage)
              .font(.system(size: 9, weight: .semibold))
              .foregroundStyle(delivery == .read ? theme.accent : theme.inkTertiary)
              .padding(.top, 2)
              .accessibilityLabel(delivery.labelFR)
          }
          Text(subtitle)
            .font(Typography.meta(typeface))
            .foregroundStyle(conversation.hasUnread ? theme.inkSecondary : theme.inkTertiary)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 6)
          if conversation.hasUnread {
            UnreadBadge(count: conversation.unreadCount, theme: theme)
              .padding(.top, 1)
          }
        }
      }
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.xs)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }

  /// Colonne de droite compacte : heure aujourd'hui, jour cette semaine, date sinon.
  static func shortDate(_ date: Date, now: Date = Date()) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) {
      return date.formatted(.dateTime.hour().minute())
    }
    if calendar.isDateInYesterday(date) {
      return "hier"
    }
    if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 {
      return date.formatted(.dateTime.weekday(.abbreviated))
    }
    return date.formatted(.dateTime.day().month(.twoDigits))
  }
}

/// Pastille réseau discrète, posée sur l'avatar.
private struct NetworkPip: View {
  let network: MessageNetwork
  let theme: WritingTheme

  var body: some View {
    Image(systemName: network.systemImage)
      .font(.system(size: 8, weight: .bold))
      .foregroundStyle(theme.inkSecondary)
      .frame(width: 15, height: 15)
      .background(theme.sidebar, in: Circle())
      .overlay(Circle().strokeBorder(theme.edge.opacity(0.7), lineWidth: 0.5))
      .accessibilityLabel(network.labelFR)
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
