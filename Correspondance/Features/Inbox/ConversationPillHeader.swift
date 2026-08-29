import AppKit
import SwiftUI

/// Entête de conversation : avatar + « Nom › », au CENTRE DE LA BARRE D'OUTILS.
///
/// Elle flottait auparavant au-dessus du fil et masquait la première bulle. Un
/// titre de fenêtre est du chrome, pas du contenu : sa place native sur macOS
/// est `ToolbarItem(placement: .principal)`, où le système lui donne son verre,
/// sa réserve d'espace et son estompage quand la fenêtre passe à l'arrière-plan.
/// Le clic ouvre la même fiche contact / infos de groupe qu'avant.
struct ConversationPillHeader: View {
  let conversation: Conversation
  let theme: WritingTheme

  @State private var isShowingInfo = false

  var body: some View {
    Button {
      isShowingInfo.toggle()
    } label: {
      HStack(spacing: 6) {
        ConversationAvatarView(conversation: conversation, size: 20, theme: theme)
        Text(conversation.title)
          .font(.system(size: 13, weight: .semibold))
          .lineLimit(1)
          .truncationMode(.tail)
        Image(systemName: "chevron.right")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(theme.inkTertiary)
      }
      .frame(maxWidth: 320)
    }
    .accessibilityLabel(
      conversation.isGroup
        ? "Infos du groupe \(conversation.title)"
        : "Fiche de \(conversation.title)"
    )
    .accessibilityHint("Ouvre les informations de la conversation")
    .popover(isPresented: $isShowingInfo, arrowEdge: .bottom) {
      ConversationInfoCard(conversation: conversation, theme: theme)
    }
  }
}

/// Fiche contact / infos groupe — ce que l'app sait déjà, sans permission de plus.
private struct ConversationInfoCard: View {
  let conversation: Conversation
  let theme: WritingTheme

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack(spacing: Spacing.xs) {
        ConversationAvatarView(conversation: conversation, size: 44, theme: theme)
        VStack(alignment: .leading, spacing: 2) {
          Text(conversation.title)
            .font(.system(size: 15, weight: .semibold))
          Label(
            conversation.isGroup ? "\(conversation.network.labelFR) · groupe" : conversation.network.labelFR,
            systemImage: conversation.rowSystemImage
          )
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
        }
      }

      if !conversation.isGroup {
        LabeledContent("Adresse") {
          Text(conversation.address)
            .textSelection(.enabled)
            .lineLimit(2)
        }
        .font(.system(size: 11))
      }

      if let delivery = conversation.lastDelivery {
        LabeledContent("Dernier envoi") {
          Label(delivery.labelFR, systemImage: delivery.systemImage)
        }
        .font(.system(size: 11))
      }

      LabeledContent("Dernier message") {
        Text(conversation.lastMessageAt, format: .dateTime.day().month().hour().minute())
      }
      .font(.system(size: 11))

      if !conversation.isGroup, conversation.network == .iMessage {
        Divider()
        Button("Ouvrir dans Contacts") {
          if let url = URL(string: "addressbook://") {
            NSWorkspace.shared.open(url)
          }
        }
        .buttonStyle(.link)
      }
    }
    .padding(Spacing.md)
    .frame(width: 280, alignment: .leading)
  }
}
