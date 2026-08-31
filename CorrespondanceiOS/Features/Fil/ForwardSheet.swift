import CorrespondanceCore
import CorrespondanceUI
import SwiftUI

/// Le sélecteur de fil d'un transfert.
///
/// Une recherche, la liste des fils en dessous, un appui suffit. Comme sur le
/// Mac et comme Beeper, le message renvoyé ne porte aucune mention
/// « transféré de » — il arrive comme si on l'avait écrit.
struct ForwardSheet: View {
  let message: ChatMessage

  @Environment(RelayStore.self) private var store
  @Environment(ThemePreferences.self) private var themes
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""

  private var theme: WritingTheme { themes.theme }
  private var typeface: WritingTypeface { themes.typeface }

  var body: some View {
    NavigationStack {
      List {
        Section {
          Text(message.sidebarPreviewText)
            .font(Typography.meta(typeface))
            .foregroundStyle(theme.inkSecondary)
            .lineLimit(3)
        }
        Section {
          ForEach(store.forwardTargets(query)) { conversation in
            Button {
              let target = conversation.id
              let sent = message
              Task { await store.forward(sent, to: target) }
              dismiss()
            } label: {
              HStack(spacing: 10) {
                ConversationAvatar(conversation: conversation, size: 30, theme: theme)
                VStack(alignment: .leading, spacing: 1) {
                  Text(conversation.title)
                    .font(Typography.body(typeface, size: 16))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                  Text(conversation.network.labelFR)
                    .font(Typography.meta(typeface))
                    .foregroundStyle(theme.inkTertiary)
                }
                Spacer(minLength: 0)
              }
            }
            .buttonStyle(.plain)
          }
        }
      }
      .scrollContentBackground(.hidden)
      .background(theme.paper.ignoresSafeArea())
      .searchable(text: $query, prompt: "Chercher une conversation")
      .navigationTitle("Transférer")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Annuler") {
            store.cancelForwarding()
            dismiss()
          }
        }
      }
      .toolbarBackground(theme.paper, for: .navigationBar)
    }
    .tint(theme.accent)
  }
}
