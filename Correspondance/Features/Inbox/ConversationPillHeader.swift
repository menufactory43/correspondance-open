import SwiftUI
import CorrespondanceCore
import CorrespondanceUI

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

  @Environment(InboxStore.self) private var store
  @State private var isShowingInfo = false
  @State private var isShowingMergeSuggestion = false

  /// Les mêmes chiffres sur deux réseaux : il y a peut-être une fusion à faire.
  private var mergeCandidates: [Conversation]? {
    store.mergeCandidates(for: conversation)
  }

  var body: some View {
    HStack(spacing: 6) {
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

      // La proposition ne s'affiche pas d'elle-même en travers du fil : elle
      // pose une pastille dans la pilule, et se déplie dessous si on la touche.
      if let candidates = mergeCandidates {
        Button {
          isShowingMergeSuggestion.toggle()
        } label: {
          Image(systemName: "arrow.triangle.merge")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(theme.accent)
        }
        .buttonStyle(.plain)
        .help("Cette personne a un autre chat — fusionner ?")
        .accessibilityLabel("Fusion possible : \(candidates.count) chats pour \(conversation.title)")
        .popover(isPresented: $isShowingMergeSuggestion, arrowEdge: .bottom) {
          MergeSuggestionBar(candidates: candidates, theme: theme)
        }
      }
    }
    .onChange(of: conversation.id) { _, _ in
      isShowingInfo = false
      isShowingMergeSuggestion = false
    }
  }
}

/// Fiche contact / infos groupe — ce que l'app sait déjà, sans permission de plus.
struct ConversationInfoCard: View {
  let conversation: Conversation
  let theme: WritingTheme

  @Environment(InboxStore.self) private var store

  /// Les fils réunis sous cette ligne, s'il s'agit d'un contact fusionné.
  private var members: [Conversation] {
    store.isMerged(conversation.id) ? store.memberConversations(of: conversation.id) : []
  }

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

      if !members.isEmpty {
        Divider()
        Text("Chats réunis")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.secondary)
        ForEach(members) { member in
          Label {
            Text("\(member.network.labelFR) · \(member.address)")
              .font(.system(size: 11))
              .lineLimit(1)
              .truncationMode(.middle)
          } icon: {
            Image(systemName: member.network.systemImage)
          }
        }
        Button("Séparer") {
          let id = conversation.id
          Task { await store.unmerge(id) }
        }
        .buttonStyle(.link)
      }

      if !conversation.isGroup, members.isEmpty {
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
            Platform.open(url)
          }
        }
        .buttonStyle(.link)
      }
    }
    .padding(Spacing.md)
    // Une largeur idéale, pas une largeur imposée : la fiche doit pouvoir se
    // serrer quand la fenêtre qui la porte est un post-it.
    .frame(minWidth: 220, idealWidth: 280, maxWidth: 320, alignment: .leading)
  }
}
