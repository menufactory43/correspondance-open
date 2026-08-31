import CorrespondanceCore
import CorrespondanceUI
import SwiftUI

/// Une ligne de l'inbox — même information que sur le Mac
/// (`ConversationRowView`), à la mesure du pouce : avatar plus grand, deux
/// lignes d'aperçu, la date à droite du nom.
struct ConversationRow: View {
  let conversation: Conversation
  let theme: WritingTheme
  var typeface: WritingTypeface = .quattro
  var isPinned = false
  var isMuted = false
  /// Le brouillon en cours, s'il y en a un : il remplace l'aperçu, en accent —
  /// c'est ce qu'on a à faire ici, pas ce qu'on y a reçu.
  var draft: String = ""

  @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = 46

  private var subtitle: String {
    if !draft.isEmpty { return draft }
    if conversation.hasLivePreview { return conversation.preview }
    if conversation.isGroup { return "En attente de messages" }
    return conversation.preview
  }

  var body: some View {
    HStack(alignment: .top, spacing: Spacing.sm) {
      ConversationAvatar(conversation: conversation, size: avatarSize, theme: theme)

      VStack(alignment: .leading, spacing: 3) {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
          Text(conversation.title)
            .font(Typography.body(typeface, size: 16))
            .fontWeight(conversation.hasUnread ? .semibold : .regular)
            .foregroundStyle(theme.ink)
            .lineLimit(1)
            .truncationMode(.tail)
          if isPinned {
            Image(systemName: "pin.fill")
              .font(.system(size: 9, weight: .semibold))
              .foregroundStyle(theme.inkTertiary)
              .accessibilityLabel("Épinglée")
          }
          if isMuted {
            Image(systemName: "bell.slash.fill")
              .font(.system(size: 9, weight: .semibold))
              .foregroundStyle(theme.inkTertiary)
              .accessibilityLabel("Notifications coupées")
          }
          Spacer(minLength: 6)
          if conversation.hasLivePreview {
            Text(Self.shortDate(conversation.lastMessageAt))
              .font(Typography.meta(typeface))
              .monospacedDigit()
              .foregroundStyle(conversation.hasUnread ? theme.accent : theme.inkTertiary)
              .lineLimit(1)
              .layoutPriority(1)
          }
        }

        HStack(alignment: .top, spacing: 5) {
          if !draft.isEmpty {
            Image(systemName: "pencil.line")
              .font(.system(size: 10, weight: .semibold))
              .foregroundStyle(theme.accent)
              .padding(.top, 2)
          } else if let delivery = conversation.lastDelivery {
            Image(systemName: delivery.systemImage)
              .font(.system(size: 10, weight: .semibold))
              .foregroundStyle(delivery == .read ? theme.accent : theme.inkTertiary)
              .padding(.top, 2)
              .accessibilityLabel(delivery.labelFR)
          }
          Text(subtitle)
            .font(Typography.meta(typeface))
            .foregroundStyle(draftOrPreviewInk)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 6)
          if conversation.hasUnread {
            UnreadBadge(count: conversation.unreadCount, theme: theme, typeface: typeface)
              .padding(.top, 1)
          }
        }
      }
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLine)
  }

  private var draftOrPreviewInk: Color {
    if !draft.isEmpty { return theme.accent }
    return conversation.hasUnread ? theme.inkSecondary : theme.inkTertiary
  }

  private var accessibilityLine: String {
    var parts = [conversation.title, conversation.network.labelFR]
    if conversation.hasUnread { parts.append("\(conversation.unreadCount) non lus") }
    if isPinned { parts.append("épinglée") }
    if isMuted { parts.append("muette") }
    if !draft.isEmpty { parts.append("brouillon : \(draft)") } else { parts.append(subtitle) }
    return parts.joined(separator: ", ")
  }

  /// Colonne de droite compacte : heure aujourd'hui, jour cette semaine, date sinon.
  /// La même règle que sur le Mac, pour que la même conversation s'y date pareil.
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

struct UnreadBadge: View {
  let count: Int
  let theme: WritingTheme
  var typeface: WritingTypeface = .quattro

  var body: some View {
    Text(count > 99 ? "99+" : "\(count)")
      .font(Typography.meta(typeface))
      .monospacedDigit()
      .foregroundStyle(theme.badgeInk)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(Capsule().fill(theme.badge))
      .accessibilityHidden(true)
  }
}
