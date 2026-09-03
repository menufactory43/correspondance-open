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
          // Ce que la conversation est vraiment. iMessage n'a pas de salon
          // Matrix : sa confidentialité est celle d'Apple, et nous n'en savons
          // rien — mieux vaut ne rien dire que dire à peu près.
          if conversation.network != .iMessage {
            ConfidentialiteBadge(
              conversation.confidentialite,
              teinte: conversation.privacy.showsClosedLock ? theme.accent : theme.inkTertiary
            )
          }
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
    .onChange(of: conversation.id) { _, _ in
      isShowingInfo = false
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

      // Le chiffrement se dit **avant** l'adresse et la date : c'est ce qui
      // décide de ce qu'on écrit ici, pas un détail de fiche technique.
      // Un portail ne porte jamais le cadenas plein, même chiffré (cf.
      // `ConfidentialiteAffichee`).
      Divider()
      LabeledContent("Confidentialité") {
        VStack(alignment: .trailing, spacing: 2) {
          Label(conversation.confidentialite.libelleFR, systemImage: conversation.confidentialite.symbole)
          Text(conversation.confidentialite.phraseFR)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .font(.system(size: 11))

      if !members.isEmpty {
        Divider()
        Text("Chats réunis")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.secondary)
        ForEach(members) { member in
          Label {
            Text(member.networkAndReadableAddress)
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

      // L'adresse seulement quand elle dit quelque chose : un numéro, un e-mail.
      // Un identifiant de salon n'apprend rien et fait peur pour rien.
      if !conversation.isGroup, members.isEmpty, let readable = conversation.readableAddress {
        LabeledContent("Adresse") {
          Text(readable)
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

      // Réunir cette personne avec ses autres réseaux : le geste vit dans sa
      // fiche, là où l'on regarde qui elle est. Une fusion déjà repérée (même
      // numéro, même nom) est dite ici, et proposée en tête du sélecteur.
      if !conversation.isGroup, conversation.network != .selfNote, conversation.network != .agent {
        Divider()
        let suggested = store.mergeCandidates(for: conversation)
        Button {
          store.mergePickerConversationID = conversation.id
        } label: {
          HStack(spacing: 8) {
            Image(systemName: "person.line.dotted.person.fill")
              .font(.system(size: 13, weight: .semibold))
              .foregroundStyle(theme.accent)
              .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
              Text(members.isEmpty ? "Fusionner avec un autre chat…" : "Ajouter un chat à cette personne…")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.ink)
              if let suggested {
                Text("\(suggested.count - 1) chat\(suggested.count > 2 ? "s" : "") repéré\(suggested.count > 2 ? "s" : "") — même numéro ou même nom")
                  .font(.system(size: 11))
                  .foregroundStyle(theme.accent)
              } else {
                Text("Signal, Messenger, WhatsApp… la même personne, une seule ligne.")
                  .font(.system(size: 11))
                  .foregroundStyle(.secondary)
              }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
              .font(.system(size: 9, weight: .semibold))
              .foregroundStyle(.tertiary)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(members.isEmpty ? "Fusionner avec un autre chat" : "Ajouter un chat à cette personne")
      }

      TranslationCard(conversationID: conversation.id, theme: theme)

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
