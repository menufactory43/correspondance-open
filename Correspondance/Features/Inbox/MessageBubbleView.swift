import SwiftUI
import CorrespondanceCore

struct MessageBubbleView: View {
  let message: ChatMessage
  let theme: WritingTheme
  var typeface: WritingTypeface = .quattro
  /// L'échelle de lecture (⌘+ / ⌘−). Elle porte le corps, l'interligne et la
  /// longueur de ligne — les trois se tiennent, on ne peut pas en bouger un seul.
  var textScale: CGFloat = 1
  /// Les aperçus de liens sont-ils allumés ? (Réglages → Apparence.)
  var showsLinkPreviews: Bool = true
  /// Requête ⌘F à surligner dans le corps du message. Vide = aucun surlignage.
  var highlightQuery: String = ""
  /// Ce message est celui que la navigation ⌘F vise en ce moment.
  var isCurrentMatch: Bool = false
  /// `nil` en aperçu : la bulle est alors purement décorative.
  var onReact: ((String) -> Void)?
  var onReply: (() -> Void)?
  /// Lot M2 — modifier / annuler l'envoi d'un iMessage, via l'automatisation
  /// Accessibilité. `nil` = le réseau (ou le réglage) ne le permet pas.
  var onEdit: ((String) -> Void)?
  var onUndoSend: (() -> Void)?
  /// Supprimer la bulle — parité Beeper. « Ici » ne quitte pas la machine ;
  /// « pour tout le monde » part sur le réseau. `nil` = ce geste n'est pas offert.
  var onDeleteLocally: (() -> Void)?
  var onDeleteEverywhere: (() -> Void)?

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Le curseur est sur cette rangée : les actions rapides se montrent.
  @State private var isHovered = false
  /// Le sélecteur de réactions est ouvert — la rangée reste alors visible,
  /// même si le curseur est parti dans le popover.
  @State private var isPickingReaction = false
  /// Feuille « Modifier le message ».
  @State private var isEditing = false
  @State private var editedText = ""
  /// Suppression demandée, en attente de confirmation. Un message effacé ne
  /// revient pas : on le demande une fois, comme Beeper.
  @State private var pendingDeletion: Deletion?

  /// L'étendue d'une suppression, et ce qu'elle promet.
  enum Deletion: String, Identifiable {
    case locally
    case everywhere

    var id: String { rawValue }

    var titleFR: String {
      switch self {
      case .locally: "Supprimer ce message ici ?"
      case .everywhere: "Supprimer ce message pour tout le monde ?"
      }
    }

    var detailFR: String {
      switch self {
      case .locally:
        "Il disparaît de Correspondance, sur cette machine. Ton correspondant le garde."
      case .everywhere:
        "Il disparaît du fil, chez toi comme chez ton correspondant. C'est sans retour."
      }
    }
  }

  var body: some View {
    HStack(spacing: 6) {
      if message.isFromMe {
        Spacer(minLength: 48)
        if isHovered || isPickingReaction { hoverActions }
      }
      VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 6) {
        if let quote = message.replyTo, !quote.isEmpty {
          quoteChip(quote)
        }

        ForEach(visibleAttachments) { attachment in
          attachmentView(attachment)
        }

        if message.isRetracted {
          retractedBubble
        } else if message.isEmojiOnly {
          emojiOnlyBody
        } else if showsTextBubble {
          Text(highlighted)
            .font(Typography.bubble(typeface, scale: textScale))
            // L'interligne de lecture : le texte ne vit plus à l'interligne nu
            // de la fonte. Dérivé du thème et du corps effectif — cf. `WritingTheme`.
            .lineSpacing(theme.bubbleLineSpacing(forBodySize: bodySize))
            .foregroundStyle(message.isFromMe ? theme.bubbleOutInk : theme.bubbleInInk)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
              RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(message.isFromMe ? theme.bubbleOut : theme.bubbleIn)
            )
        }

        if let link = previewedLink {
          LinkPreviewCard(url: link, theme: theme, typeface: typeface)
        }

        if let footnote = footnoteLabel {
          Text(footnote.text)
            .font(Typography.meta(typeface))
            .foregroundStyle(theme.inkTertiary)
            .help(footnote.help)
            .accessibilityLabel(footnote.help)
        }

        if !message.reactions.isEmpty {
          reactionRow
        }
      }
      .opacity(message.isPending ? 0.55 : 1)
      .padding(.horizontal, 4)
      .padding(.vertical, 2)
      .contentShape(Rectangle())
      // L'heure a quitté le dessous de chaque bulle (elle noyait le fil) : elle
      // reste accessible au survol, comme dans Messages.
      .help(message.sentAt.formatted(date: .abbreviated, time: .shortened))
      .accessibilityElement(children: .combine)
      .accessibilityValue(message.sentAt.formatted(date: .omitted, time: .shortened))
      .contextMenu { bubbleMenu }
      // LA LONGUEUR DE LIGNE. Le `Spacer` ne borne que la fenêtre étroite ; sur
      // un large écran une phrase traversait tout le fil, et l'œil ne retrouvait
      // plus le début de la ligne suivante. Plafond à la largeur de lettre de
      // l'app (560 pt ≈ 66 signes en Quattro 15), qui suit l'échelle : agrandir
      // le corps sans desserrer la colonne ramènerait au même nombre de signes.
      //
      // Le cadre est posé AUTOUR de la pile, pas sur le texte : il ne fait que
      // borner la largeur proposée, la pile continue d'épouser son contenu — le
      // liseré de sélection et les pastilles ne s'étirent donc pas à 560 points.
      .frame(
        maxWidth: LayoutMetrics.letterWidth * textScale,
        alignment: message.isFromMe ? .trailing : .leading
      )
      if !message.isFromMe {
        if isHovered || isPickingReaction { hoverActions }
        Spacer(minLength: 48)
      }
    }
    // Le survol de la RANGÉE entière, pas de la bulle : glisser le curseur vers
    // les boutons ne doit pas les faire disparaître sous lui. Le
    // `contentShape` est ce qui rend les Spacer sensibles — sans lui, le
    // vide à droite du message est invisible au hit-test, et traverser ce
    // vide éteignait la rangée qu'on allait cliquer.
    .contentShape(Rectangle())
    .onHover { hovering in
      if reduceMotion {
        isHovered = hovering
      } else {
        withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
      }
    }
    .alert("Modifier le message", isPresented: $isEditing) {
      TextField("Nouveau texte", text: $editedText)
      Button("Annuler", role: .cancel) {}
      Button("Modifier") { onEdit?(editedText) }
    } message: {
      Text("Messages n’autorise la modification que 15 minutes après l’envoi.")
    }
    .alert(
      pendingDeletion?.titleFR ?? "",
      isPresented: Binding(
        get: { pendingDeletion != nil },
        set: { if !$0 { pendingDeletion = nil } }
      ),
      presenting: pendingDeletion
    ) { deletion in
      Button("Supprimer", role: .destructive) {
        switch deletion {
        case .locally: onDeleteLocally?()
        case .everywhere: onDeleteEverywhere?()
        }
      }
      Button("Annuler", role: .cancel) {}
    } message: { deletion in
      Text(deletion.detailFR)
    }
  }

  /// Le corps EFFECTIF de la bulle, échelle comprise. Trois choses s'y
  /// accrochent : la police, l'interligne, la longueur de ligne.
  private var bodySize: CGFloat { Typography.bubbleSize(textScale) }

  /// « ❤️ » NU ET GRAND. Une bulle autour d'un seul emoji ne fait qu'emballer
  /// un geste dans du papier — Messages, WhatsApp et Signal l'ont tous compris.
  /// Réactions et notes de bas de bulle, elles, ne changent pas d'un pouce.
  private var emojiOnlyBody: some View {
    Text(displayText)
      .font(.system(size: 40 * textScale))
      .padding(.horizontal, 2)
      .padding(.vertical, 1)
      .accessibilityLabel(displayText)
  }

  /// L'adresse dont on montre la carte : la première du message, et seulement
  /// si le réglage est allumé et que la bulle porte bien du texte.
  private var previewedLink: URL? {
    guard showsLinkPreviews, !message.isRetracted, !message.isEmojiOnly, showsTextBubble
    else { return nil }
    return TextLinks.firstWebURL(in: displayText)
  }

  /// Réagir · répondre · tout le reste — la rangée qui n'existe qu'au survol.
  ///
  /// C'est ce qui a remplacé la sélection au clic : un état qui pilotait ⌘R
  /// devait se voir, et se voir dérangeait. Ici, aucun état ne survit au
  /// geste — les actions paraissent sous le curseur, le temps d'agir.
  private var hoverActions: some View {
    HStack(spacing: 8) {
      if onReact != nil {
        Button {
          isPickingReaction.toggle()
        } label: {
          Image(systemName: "face.smiling")
        }
        .buttonStyle(.plain)
        .help("Réagir")
        .accessibilityLabel("Réagir au message")
        // Les six réactions EN RANGÉE, comme Signal et Messages : un geste se
        // choisit d'un regard, pas en dépliant une liste.
        .popover(isPresented: $isPickingReaction, arrowEdge: .top) {
          HStack(spacing: 2) {
            ForEach(InboxStore.quickReactions, id: \.self) { emoji in
              Button {
                isPickingReaction = false
                onReact?(emoji)
              } label: {
                Text(emoji)
                  .font(.system(size: 19))
                  .padding(.horizontal, 5)
                  .padding(.vertical, 4)
                  .background(
                    // La mienne se reconnaît : cliquer dessus la retire.
                    Capsule().fill(
                      message.myReactionEmoji == emoji ? theme.selection : .clear
                    )
                  )
              }
              .buttonStyle(.plain)
              .help(message.myReactionEmoji == emoji ? "Retirer ma réaction" : "Réagir \(emoji)")
              .accessibilityLabel(
                message.myReactionEmoji == emoji ? "Retirer la réaction \(emoji)" : "Réagir \(emoji)"
              )
            }
          }
          .padding(6)
        }
      }

      if let onReply {
        Button {
          onReply()
        } label: {
          Image(systemName: "arrowshape.turn.up.left")
        }
        .buttonStyle(.plain)
        .help("Répondre en citant")
        .accessibilityLabel("Répondre en citant")
      }

      Menu {
        bubbleMenu
      } label: {
        Image(systemName: "ellipsis")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Plus d’actions")
      .accessibilityLabel("Plus d’actions")
    }
    .font(.system(size: 11, weight: .medium))
    .foregroundStyle(theme.inkSecondary)
    .padding(.horizontal, 7)
    .padding(.vertical, 4)
    .background(Capsule().fill(theme.paperSecondary))
    .overlay(Capsule().strokeBorder(theme.edge, lineWidth: 1))
    .transition(.opacity)
  }

  /// Un envoi annulé laisse sa place dans le fil, vidée : Messages fait pareil,
  /// et effacer la bulle ferait mentir la conversation.
  private var retractedBubble: some View {
    Text("Message annulé")
      .font(Typography.bubble(typeface, scale: textScale).italic())
      .foregroundStyle(theme.inkTertiary)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .strokeBorder(theme.edge, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
      )
      .accessibilityLabel("Message annulé par son auteur")
  }

  /// Mention sous la bulle : « Modifié » (historique au survol) ou l'effet reçu.
  /// Les deux ensemble tiennent sur une ligne, séparés d'un point médian.
  private var footnoteLabel: (text: String, help: String)? {
    var parts: [String] = []
    var help: [String] = []
    if message.editedAt != nil, !message.isRetracted {
      parts.append("Modifié")
      if message.editHistory.isEmpty {
        help.append("Message modifié après envoi")
      } else {
        help.append(
          "Versions précédentes :\n"
            + message.editHistory.map { "• \($0)" }.joined(separator: "\n")
        )
      }
    }
    if let effect = message.expressiveEffectName, !message.isRetracted {
      parts.append("envoyé avec \(effect)")
      help.append("Effet d’envoi : \(effect)")
    }
    guard !parts.isEmpty else { return nil }
    return (parts.joined(separator: " · "), help.joined(separator: "\n\n"))
  }

  /// Citation compacte au-dessus de la bulle : un filet, l'auteur, une ligne de texte.
  private func quoteChip(_ quote: QuotedMessage) -> some View {
    HStack(spacing: 6) {
      RoundedRectangle(cornerRadius: 1, style: .continuous)
        .fill(theme.accent.opacity(0.6))
        .frame(width: 2)
      VStack(alignment: .leading, spacing: 1) {
        if !quote.senderName.isEmpty {
          Text(quote.senderName)
            .font(Typography.meta(typeface))
            .foregroundStyle(theme.accent)
        }
        Text(quote.text)
          .font(Typography.meta(typeface))
          .foregroundStyle(theme.inkSecondary)
          .lineLimit(2)
      }
    }
    .padding(.leading, 2)
    .frame(maxWidth: 260, alignment: .leading)
    .accessibilityLabel("En réponse à \(quote.senderName) : \(quote.text)")
  }

  /// Pastilles sous la bulle : emoji, compteur au-delà d'une personne, et un liseré
  /// quand j'en fais partie. Cliquer une pastille repose (donc retire) le même emoji.
  private var reactionRow: some View {
    HStack(spacing: 4) {
      ForEach(message.reactions) { reaction in
        Button {
          onReact?(reaction.emoji)
        } label: {
          HStack(spacing: 3) {
            Text(reaction.emoji).font(.system(size: 11))
            if reaction.count > 1 {
              Text("\(reaction.count)")
                .font(Typography.meta(typeface))
                .foregroundStyle(theme.inkSecondary)
            }
          }
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(
            Capsule().fill(theme.paperSecondary)
          )
          .overlay(
            Capsule().stroke(reaction.isMine ? theme.accent : theme.edge, lineWidth: 1)
          )
        }
        .buttonStyle(.plain)
        .help(reaction.senders.isEmpty ? reaction.emoji : reaction.senders.joined(separator: ", "))
        .accessibilityLabel("\(reaction.emoji), \(reaction.count)")
      }
    }
  }

  @ViewBuilder
  private var bubbleMenu: some View {
    if let onReply {
      Button("Répondre en citant") { onReply() }
      Divider()
    }
    if onReact != nil {
      ForEach(InboxStore.quickReactions, id: \.self) { emoji in
        Button {
          onReact?(emoji)
        } label: {
          // Le même emoji déjà posé : le menu propose alors de le retirer.
          Text(message.myReactionEmoji == emoji ? "\(emoji)  Retirer" : emoji)
        }
      }
    }
    if onEdit != nil || onUndoSend != nil {
      Divider()
      if onEdit != nil {
        Button("Modifier…") {
          editedText = message.text
          isEditing = true
        }
      }
      if let onUndoSend {
        Button("Annuler l’envoi") { onUndoSend() }
      }
    }
    if !message.text.isEmpty {
      Divider()
      Button("Copier le texte") {
        Platform.copyToPasteboard(message.text)
      }
    }
    if onDeleteLocally != nil || onDeleteEverywhere != nil {
      Divider()
      if onDeleteEverywhere != nil {
        Button("Supprimer pour tout le monde…", role: .destructive) {
          pendingDeletion = .everywhere
        }
      }
      if onDeleteLocally != nil {
        Button("Supprimer ici…", role: .destructive) {
          pendingDeletion = .locally
        }
      }
    }
  }

  private var visibleAttachments: [MessageAttachment] {
    message.attachments.map(Self.repaired).filter { $0.isImage || $0.isVideo || $0.resolvedFileURL != nil }
  }

  private var displayText: String {
    let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let hasVisibleImage = message.attachments.contains {
      let repaired = Self.repaired($0)
      return repaired.isImage && repaired.resolvedFileURL != nil
    }
    if hasVisibleImage, trimmed.isEmpty || trimmed == "📷 Photo" {
      return ""
    }
    // Un audio joué sur place n'a pas besoin de son libellé de secours.
    let hasPlayableAudio = message.attachments.contains {
      let repaired = Self.repaired($0)
      return repaired.isAudio && repaired.resolvedFileURL != nil
    }
    if hasPlayableAudio, trimmed.isEmpty || trimmed == "🎤 Message audio" {
      return ""
    }
    return trimmed
  }

  private var showsTextBubble: Bool {
    !displayText.isEmpty
  }

  /// Corps du message avec les occurrences de la requête ⌘F surlignées.
  /// Le message visé par la navigation est marqué plus franchement que les autres.
  private var highlighted: AttributedString {
    var attributed = AttributedString(displayText)
    let ranges = ConversationSearch.highlightRanges(in: displayText, query: highlightQuery)
    let tint = isCurrentMatch ? theme.accent.opacity(0.55) : theme.accent.opacity(0.22)
    for range in ranges {
      guard let bounds = Range(range, in: attributed) else { continue }
      attributed[bounds].backgroundColor = message.isFromMe ? theme.paper.opacity(0.35) : tint
    }
    // Les liens par-dessus le surlignage : les deux se voient, l'un colore le fond,
    // l'autre l'encre. L'encre d'accent tient sur les deux bulles des six thèmes.
    return LinkedText.render(
      text: displayText,
      tint: message.isFromMe ? theme.bubbleOutInk : theme.accent,
      base: attributed
    )
  }

  @ViewBuilder
  private func attachmentView(_ attachment: MessageAttachment) -> some View {
    let repaired = Self.repaired(attachment)
    if repaired.isAudio, repaired.resolvedFileURL != nil {
      AudioMessageView(
        attachment: repaired,
        theme: theme,
        typeface: typeface,
        isFromMe: message.isFromMe
      )
    } else if let url = repaired.resolvedFileURL, repaired.isImage {
      AttachmentImageView(
        url: url,
        maxWidth: 280,
        maxHeight: 320,
        placeholder: theme.bubbleIn,
        border: theme.edge.opacity(0.5),
        label: repaired.filename ?? "Image"
      ) {
        unavailableImageLabel(repaired)
      }
    } else if let url = repaired.resolvedFileURL, repaired.isVideo {
      AttachmentVideoView(
        url: url,
        maxWidth: 280,
        maxHeight: 320,
        placeholder: theme.bubbleIn,
        border: theme.edge.opacity(0.5),
        label: repaired.filename ?? "Vidéo"
      )
    } else if repaired.isImage {
      unavailableImageLabel(repaired)
    } else {
      Label(repaired.filename ?? "Pièce jointe", systemImage: "paperclip")
        .font(Typography.meta)
        .foregroundStyle(theme.inkSecondary)
        .padding(10)
        .background(theme.bubbleIn, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
  }

  /// Photo qu'on ne sait pas montrer : fichier absent, ou format que le système
  /// ne décode pas. La bulle dit lequel plutôt que de laisser un trou.
  @ViewBuilder
  private func unavailableImageLabel(_ attachment: MessageAttachment) -> some View {
    Label(attachment.filename ?? "Image indisponible", systemImage: "photo")
      .font(Typography.meta)
      .foregroundStyle(theme.inkSecondary)
      .padding(10)
      .background(theme.bubbleIn, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  /// Ré-attache le fichier si le chemin en cache est périmé. L'identifiant d'une
  /// pièce jointe bridgée est son MXC : le média déjà téléchargé se retrouve sous
  /// ce nom, sans redemander quoi que ce soit au serveur.
  private static func repaired(_ attachment: MessageAttachment) -> MessageAttachment {
    if attachment.resolvedFileURL != nil { return attachment }
    var copy = attachment
    if let path = MatrixAttachmentStore.existingLocalPath(
      forMXC: attachment.id,
      contentType: attachment.contentType
    ) {
      copy.localPath = path
    }
    return copy
  }
}
