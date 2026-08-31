import SwiftUI
import CorrespondanceCore
import CorrespondanceUI

/// Le sélecteur de fil d'un transfert (⌘⇧F).
///
/// Une ligne de recherche, la file en dessous : le même index que la recherche
/// de conversations, aucune liste à part. Comme Beeper, le message renvoyé ne
/// porte aucune mention « transféré de » — il arrive comme si on l'avait écrit.
struct ForwardSheet: View {
  let message: ChatMessage

  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  @FocusState private var isSearchFocused: Bool

  private var theme: WritingTheme { themes.theme }

  private var targets: [Conversation] { store.forwardTargets(query) }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider().overlay(theme.edge)
      if targets.isEmpty {
        Text("Aucune conversation.")
          .font(Typography.meta(themes.typeface))
          .foregroundStyle(theme.inkTertiary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List(targets) { conversation in
          Button {
            forward(to: conversation.id)
          } label: {
            HStack(spacing: 8) {
              ConversationAvatarView(conversation: conversation, size: 24, theme: theme)
              VStack(alignment: .leading, spacing: 1) {
                Text(conversation.title)
                  .font(Typography.body(themes.typeface, size: 13))
                  .foregroundStyle(theme.ink)
                  .lineLimit(1)
                Text(conversation.network.labelFR)
                  .font(Typography.meta(themes.typeface))
                  .foregroundStyle(theme.inkTertiary)
              }
              Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
      }
    }
    .frame(width: 340, height: 420)
    .background(theme.paper)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Transférer")
        .font(Typography.body(themes.typeface, size: 15).weight(.semibold))
        .foregroundStyle(theme.ink)
      Text(message.sidebarPreviewText)
        .font(Typography.meta(themes.typeface))
        .foregroundStyle(theme.inkSecondary)
        .lineLimit(2)
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass")
          .font(.system(size: 11))
          .foregroundStyle(theme.inkTertiary)
        TextField("Chercher une conversation", text: $query)
          .textFieldStyle(.plain)
          .font(Typography.meta(themes.typeface))
          .focused($isSearchFocused)
          .onKeyPress(.escape) {
            store.cancelForwarding()
            return .handled
          }
          .onKeyPress(.return) {
            guard let first = targets.first else { return .handled }
            forward(to: first.id)
            return .handled
          }
      }
      .padding(.horizontal, Spacing.xs)
      .padding(.vertical, 6)
      .background {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(theme.room.opacity(theme.isDark ? 0.55 : 0.45))
      }
    }
    .padding(Spacing.sm)
    .onAppear { isSearchFocused = true }
  }

  private func forward(to conversationID: String) {
    let target = conversationID
    let sent = message
    Task { await store.forward(sent, to: target) }
    dismiss()
  }
}
