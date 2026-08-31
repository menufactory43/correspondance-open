import CorrespondanceCore
import CorrespondanceUI
import SwiftUI

/// Focus : un écran, une conversation de la file.
///
/// Le fil au complet, son composer, et une barre : précédente · archiver ·
/// suivante. Le geste qui compte est le balayage vers le haut sur l'en-tête —
/// archiver et passer à la suivante, sans lever le pouce de l'écran.
/// Quand la file est vide, il n'y a plus d'écran : « Vous êtes à jour ».
struct FocusView: View {
  @Binding var mode: PhoneMode

  @Environment(RelayStore.self) private var store
  @Environment(ThemePreferences.self) private var themes
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @State private var headerOffset: CGFloat = 0

  private var theme: WritingTheme { themes.theme }
  private var typeface: WritingTypeface { themes.typeface }

  var body: some View {
    // La barre de Focus et la barre flottante s'empilent dans le même VStack :
    // en `safeAreaInset`, l'inset du composer du fil se cumulait au nôtre et les
    // deux barres finissaient l'une sur l'autre.
    VStack(spacing: 0) {
      if let conversation = store.focusConversation() {
        header(conversation)
        ThreadView(conversationID: conversation.id, showsHeader: false)
        focusBar(conversation)
      } else {
        upToDate
      }
      InboxFloatingBar(mode: $mode)
        .padding(.horizontal, Spacing.md)
        .padding(.top, Spacing.sm)
    }
    .background(theme.paper.ignoresSafeArea())
  }

  // MARK: - En-tête

  private func header(_ conversation: Conversation) -> some View {
    HStack(spacing: Spacing.sm) {
      ConversationAvatar(conversation: conversation, size: 40, theme: theme)
      VStack(alignment: .leading, spacing: 1) {
        Text(conversation.title)
          .font(Typography.letterHeading(typeface, 19))
          .foregroundStyle(theme.ink)
          .lineLimit(1)
        Text(positionLabel)
          .font(Typography.meta(typeface))
          .foregroundStyle(theme.inkTertiary)
      }
      Spacer(minLength: 0)
      Image(systemName: "chevron.up")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(theme.inkTertiary.opacity(0.7))
        .accessibilityHidden(true)
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
    .contentShape(Rectangle())
    .offset(y: headerOffset)
    .gesture(archiveSwipe)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(conversation.title), \(positionLabel)")
    .accessibilityHint("Balayer vers le haut pour archiver et passer à la suivante")
    .accessibilityAction(named: "Archiver et passer à la suivante") { archive() }
  }

  /// Balayage vers le haut sur l'en-tête = archiver et passer à la suivante.
  /// L'en-tête suit le doigt : sans ce retour, le geste serait invisible tant
  /// qu'il n'a pas abouti.
  private var archiveSwipe: some Gesture {
    DragGesture(minimumDistance: 12)
      .onChanged { value in
        guard value.translation.height < 0 else { return }
        headerOffset = max(value.translation.height * 0.6, -60)
      }
      .onEnded { _ in
        let triggered = headerOffset < -32
        if reduceMotion { headerOffset = 0 }
        else { withAnimation(.spring(duration: 0.25)) { headerOffset = 0 } }
        if triggered { archive() }
      }
  }

  private var positionLabel: String {
    let queue = store.focusQueue
    guard let id = store.focusConversationID,
          let index = queue.firstIndex(where: { $0.id == id })
    else { return "\(queue.count) en attente" }
    return "\(index + 1) sur \(queue.count)"
  }

  // MARK: - La barre

  private func focusBar(_ conversation: Conversation) -> some View {
    HStack(spacing: Spacing.sm) {
      barButton("chevron.left", label: "Conversation précédente", enabled: hasPrevious) {
        store.focusPrevious()
      }
      Button {
        archive()
      } label: {
        Label("Archiver", systemImage: "archivebox")
          .font(Typography.body(typeface, size: 15))
          .foregroundStyle(theme.accentInk)
          .padding(.horizontal, Spacing.md)
          .padding(.vertical, 10)
          .frame(maxWidth: .infinity)
          .background(Capsule().fill(theme.accentFill))
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Archiver \(conversation.title) et passer à la suivante")

      barButton("chevron.right", label: "Conversation suivante", enabled: hasFollowing) {
        store.focusNext()
      }
    }
    .padding(.horizontal, Spacing.md)
    .padding(.top, Spacing.sm)
  }

  private func barButton(
    _ systemImage: String,
    label: String,
    enabled: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(enabled ? theme.inkSecondary : theme.inkTertiary.opacity(0.4))
        .frame(width: 44, height: 40)
        .background(Capsule().fill(theme.paperSecondary))
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
    .accessibilityLabel(label)
  }

  private var hasPrevious: Bool {
    guard let id = store.focusConversationID else { return false }
    return InboxOrdering.previous(before: id, in: store.focusQueue) != nil
  }

  private var hasFollowing: Bool {
    guard let id = store.focusConversationID else { return false }
    return InboxOrdering.following(id, in: store.focusQueue) != nil
  }

  private func archive() {
    if reduceMotion { store.focusArchiveAndAdvance() }
    else { withAnimation(.easeOut(duration: 0.2)) { store.focusArchiveAndAdvance() } }
  }

  // MARK: - File vide

  private var upToDate: some View {
    VStack(spacing: Spacing.sm) {
      Image(systemName: "checkmark.seal")
        .font(.system(size: 40, weight: .light))
        .foregroundStyle(theme.accent.opacity(0.8))
      Text("Vous êtes à jour")
        .font(Typography.letterHeading(typeface, 22))
        .foregroundStyle(theme.ink)
      Text("La file est vide. Rien n'attend de réponse.")
        .font(Typography.emptyState(typeface))
        .foregroundStyle(theme.inkSecondary)
        .multilineTextAlignment(.center)
    }
    .padding(Spacing.lg)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .combine)
  }
}
