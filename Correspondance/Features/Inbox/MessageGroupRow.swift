import SwiftUI
import CorrespondanceCore
import CorrespondanceUI

/// Ce qu'une bulle **peut** faire, décidé par le magasin : la rangée ne lui
/// demande rien en se dessinant, elle reçoit ces réponses toutes faites — et
/// c'est ce qui permet de la comparer d'une passe à l'autre.
struct BubbleOffers: Equatable {
  var edit = false
  var undoViaAutomation = false
  var forward = false
  var undoSend = false
  var deleteEverywhere = false
}

/// Une prise de parole : la photo de son auteur dans la marge, puis ses bulles.
/// La photo se coupe dans Réglages ; les événements de conversation, eux, ne
/// sont de personne et gardent toute la largeur.
///
/// Une **valeur**, comparable (`.equatable()`), et rien d'observé dans son
/// corps : tout ce qu'elle montre lui arrive en entrée. Le fil, lui, se
/// refait à chaque `/sync` — un aperçu, un accusé, « écrit… » touchent
/// `conversations` — et tant que la rangée vivait dans son corps, SwiftUI
/// remettait en page les cent cinquante rangées à chaque fois : 250 ms de
/// layout par `/sync`, mesuré au Time Profiler sur un groupe Signal, une
/// frame gelée toutes les quelques secondes en plein défilement. Une rangée
/// dont les entrées n'ont pas bougé n'est plus ni refaite ni remesurée.
///
/// Le magasin reste là pour **agir** (répondre, corriger, supprimer…) : les
/// fermetures le capturent, on ne le lit jamais ici.
struct MessageGroupRow: View, Equatable {
  let group: MessageGroup
  /// Le fil dont on emprunte le visage — débarrassé de ce qui bouge à chaque
  /// `/sync` (aperçu, date, non-lus), cf. `Conversation.faceOnly`.
  let avatarConversation: Conversation?
  let showsMessageAvatars: Bool
  let theme: WritingTheme
  let typeface: WritingTypeface
  let textScale: CGFloat
  let showsLinkPreviews: Bool
  let highlightQuery: String
  /// L'occurrence courante de ⌘F, le message cité qu'on vient de rejoindre,
  /// le message qui s'encre : donnés seulement s'ils vivent dans CE groupe,
  /// sinon `nil` — pour qu'un surlignage plus loin ne refasse pas cette rangée.
  let currentMatchID: String?
  let flashedMessageID: String?
  let freshMessageID: String?
  let reduceMotion: Bool
  let selectedConversationID: String?
  /// L'agent qui a piloté un envoi en mon nom.
  let pilotAgent: String
  /// Le dernier message du fil : c'est la ligne d'accusé qui porte son « Annuler ».
  let lastMessageID: String?
  /// Une entrée par message du groupe, dans l'ordre.
  let offers: [BubbleOffers]
  let store: InboxStore
  let onJump: (String) -> Void

  nonisolated static func == (lhs: MessageGroupRow, rhs: MessageGroupRow) -> Bool {
    lhs.group == rhs.group
      && lhs.avatarConversation == rhs.avatarConversation
      && lhs.showsMessageAvatars == rhs.showsMessageAvatars
      && lhs.theme == rhs.theme
      && lhs.typeface == rhs.typeface
      && lhs.textScale == rhs.textScale
      && lhs.showsLinkPreviews == rhs.showsLinkPreviews
      && lhs.highlightQuery == rhs.highlightQuery
      && lhs.currentMatchID == rhs.currentMatchID
      && lhs.flashedMessageID == rhs.flashedMessageID
      && lhs.freshMessageID == rhs.freshMessageID
      && lhs.reduceMotion == rhs.reduceMotion
      && lhs.selectedConversationID == rhs.selectedConversationID
      && lhs.pilotAgent == rhs.pilotAgent
      && lhs.lastMessageID == rhs.lastMessageID
      && lhs.offers == rhs.offers
  }

  #if DEBUG
  /// Compteur de passes du corps, pour le banc : une rangée dont les entrées
  /// n'ont pas bougé ne doit pas se refaire.
  nonisolated(unsafe) static var bodyPasses = 0
  #endif

  var body: some View {
    #if DEBUG
    let _ = { Self.bodyPasses += 1 }()
    #endif
    let first = group.messages.first
    let showsAvatar = showsMessageAvatars
      && !group.isFromMe
      && first?.isSystemEvent != true
    // La photo se pose EN BAS de la prise de parole, en face de la dernière
    // bulle : c'est là que Messages, WhatsApp et Telegram la mettent, et c'est
    // la bulle la plus récente que l'œil cherche à attribuer. Sur son BORD, pas
    // sous ce qui la suit — cf. `VerticalAlignment.bubbleBottom`.
    VStack(alignment: .leading, spacing: ThreadMetrics.interGroupSpacing) {
      if let stamp = group.timeSeparator {
        ThreadTimeSeparator(
          date: stamp,
          network: group.networkOrigin,
          theme: theme,
          typeface: typeface
        )
      }
      HStack(alignment: .bubbleBottom, spacing: ThreadMetrics.avatarSpacing) {
        if showsAvatar, let first {
          MessageAvatarView(
            message: first,
            conversation: avatarConversation,
            size: ThreadMetrics.avatarSize,
            theme: theme
          )
        }
        VStack(alignment: .leading, spacing: ThreadMetrics.intraGroupSpacing) {
          if let label = group.senderLabel {
            Text(label)
              .font(Typography.meta(typeface))
              .foregroundStyle(SenderTint.color(for: label, theme: theme))
              .lineLimit(1)
              .padding(.leading, ThreadMetrics.senderLabelLeading)
          }
          ForEach(Array(group.messages.enumerated()), id: \.element.id) { index, message in
            if let proposal = message.agentProposal {
              AgentProposalCard(
                proposal: proposal,
                theme: theme,
                typeface: typeface,
                onSend: { Task { await store.sendAgentProposal(message) } },
                onEdit: { store.editAgentProposal(message) },
                onIgnore: { store.ignoreAgentProposal(message) },
                onReply: { store.requestComposerFocus() }
              )
              .id(message.id)
            } else if let notice = message.agentNotice {
              // L'avis de cc sur lui-même : une pastille, et le geste qu'il propose.
              AgentNoticePill(
                notice: notice,
                theme: theme,
                typeface: typeface,
                onAction: notice.action.map { action in
                  {
                    Task {
                      switch action {
                      case .rescan: await store.rescanAgent(named: notice.agent)
                      case .retry: await store.retryLastAside()
                      }
                    }
                  }
                }
              )
              .id(message.id)
            } else if let event = message.systemEventText {
              ThreadEventSeparator(text: event, theme: theme, typeface: typeface)
                .id(message.id)
            } else if message.isFromMe, message.isPiloted {
              // Envoyé par cc en mon nom : la bulle est la mienne, la ligne
              // dessous le dit — en rouge, parce que c'est le mode qui engage.
              VStack(alignment: .trailing, spacing: 2) {
                bubble(for: message, at: index)
                  .equatable()
                PilotedFootnote(
                  agent: pilotAgent,
                  sentAt: message.sentAt,
                  theme: theme,
                  typeface: typeface
                )
              }
              .id(message.id)
            } else if !message.isFromMe, !message.isRetracted, message.attachments.isEmpty,
                      let source = TextTranslator.foreignLanguage(of: message.text) {
              // Une bulle reçue dans une autre langue que celle du Mac : le
              // « Traduire » vit ICI, sous la bulle, pas dedans — dans la bulle,
              // sous son menu contextuel et sa forme de contenu, ni un bouton ni
              // un geste ne recevaient le clic (vérifié à l'écran, trace à
              // l'appui). La ligne traduite s'affiche d'emblée quand le fil le
              // demande. Sur cet appareil, sans réseau : cf. `TextTranslator`.
              VStack(alignment: .leading, spacing: 2) {
                bubble(for: message, at: index)
                  .equatable()
                IncomingTranslationSlot(
                  messageID: message.id,
                  text: message.text,
                  source: source,
                  // Le fil ouvert, pas `message.conversationID` : dans la note à
                  // soi et le fil d'un agent, la bulle porte l'identifiant brut du
                  // salon quand la fiche écrit le réglage sous le sien — « Français »
                  // choisi, et la bulle anglaise restait à « Traduire ».
                  conversationID: selectedConversationID ?? message.conversationID,
                  theme: theme,
                  typeface: typeface,
                  font: Typography.bubble(typeface, scale: textScale)
                )
              }
              .id(message.id)
            } else {
              // `.equatable()` : le fil se rafraîchit pour mille raisons qui ne
              // regardent pas cette bulle-là. Cf. `MessageBubbleView: Equatable`.
              bubble(for: message, at: index)
                .equatable()
                .id(message.id)
                .messageArrival(
                  .encre,
                  isFresh: freshMessageID == message.id,
                  isEnabled: !reduceMotion
                )
                // Le surlignage d'arrivée après un saut de citation : la rangée
                // s'éclaire puis s'éteint, le temps que l'œil trouve.
                .background(
                  RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(theme.accent.opacity(flashedMessageID == message.id ? 0.14 : 0))
                    .padding(-3)
                )
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }


  /// Une bulle et tout ce qu'on peut lui faire. Extraite de la boucle : le
  /// vérificateur de types s'y perdait.
  /// Le type concret, pas `some View` : `.equatable()` a besoin de savoir que
  /// c'est une `MessageBubbleView` pour se servir de son `==`.
  private func bubble(for message: ChatMessage, at index: Int) -> MessageBubbleView {
    let offers = offers.indices.contains(index) ? offers[index] : BubbleOffers()
    // « Modifier » ouvre le composer en mode correction ; c'est le magasin qui
    // choisit ensuite le chemin — automatisation Messages ou `m.replace`.
    let onEdit: (() -> Void)? = offers.edit
      ? { store.beginEditing(message) }
      : nil
    // Deux minutes, pas plus : au-delà, Messages n'a plus l'entrée du menu.
    let onUndoSend: (() -> Void)? = offers.undoViaAutomation
      ? { Task { await store.undoSendViaAutomation(messageID: message.id) } }
      : nil
    return MessageBubbleView(
      message: message,
      theme: theme,
      typeface: typeface,
      textScale: textScale,
      showsLinkPreviews: showsLinkPreviews,
      highlightQuery: highlightQuery,
      isCurrentMatch: currentMatchID == message.id,
      position: BubblePosition(index: index, count: group.messages.count),
      // Survoler une bulle, c'est la viser : ⌘R, ⌘T et ⌘⌥R agissaient sinon
      // sur le dernier message du fil, jamais sur celui qu'on regardait.
      onHoverBegan: { store.selectMessage(message.id) },
      onQuoteTap: message.replyTo?.messageID.map { targetID in { onJump(targetID) } },
      onReact: { emoji in
        Task { await store.react(messageID: message.id, emoji: emoji) }
      },
      onReply: {
        store.selectMessage(message.id)
        store.replyToSelectedMessage()
      },
      onEdit: onEdit,
      onUndoSend: onUndoSend,
      onForward: offers.forward ? { store.beginForwarding(message) } : nil,
      // Le dernier message a son « Annuler » sur la ligne de l'accusé ; seul
      // un envoi en sursis qui n'est plus le dernier garde le sien sous lui.
      onCancelPending: offers.undoSend && lastMessageID != message.id
        ? { store.undoSend(message.id) } : nil,
      onDeleteLocally: { store.deleteLocally(messageID: message.id) },
      onDeleteEverywhere: offers.deleteEverywhere
        ? { Task { await store.deleteEverywhere(messageID: message.id) } }
        : nil,
      onVotePoll: message.poll == nil ? nil : { answerID in
        Task { await store.votePoll(messageID: message.id, answerID: answerID) }
      }
    )
  }

}

extension Conversation {
  /// La même conversation, sans ce qu'un `/sync` fait bouger : de quoi
  /// donner un visage à une rangée sans la refaire à chaque aperçu.
  var faceOnly: Conversation {
    var face = self
    face.preview = ""
    face.lastMessageAt = .distantPast
    face.unreadCount = 0
    face.lastDelivery = nil
    face.lastMessageIsFromMe = false
    return face
  }
}
