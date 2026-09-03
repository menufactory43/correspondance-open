import AppKit
import SwiftUI
import CorrespondanceCore
import CorrespondanceUI

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
  /// Sa place dans la prise de parole : c'est elle qui resserre les coins.
  var position: BubblePosition = .alone
  /// Le curseur entre sur la rangée. Aucun état visible ne s'ensuit : c'est
  /// seulement ce qui dit à ⌘R, ⌘T et ⌘⌥R quelle bulle on est en train de viser.
  var onHoverBegan: (() -> Void)?
  /// Taper la citation : remonter au message cité. `nil` = citation inerte.
  var onQuoteTap: (() -> Void)?
  /// `nil` en aperçu : la bulle est alors purement décorative.
  var onReact: ((String) -> Void)?
  var onReply: (() -> Void)?
  /// « Modifier… » : la bulle descend dans le composer, qui passe en mode
  /// correction. `nil` = le réseau (ou le réglage) ne le permet pas.
  var onEdit: (() -> Void)?
  /// « Annuler l'envoi » d'un iMessage (≤ 2 min), via l'automatisation.
  var onUndoSend: (() -> Void)?
  /// « Transférer… » : le sélecteur de fil s'ouvre sur cette bulle.
  var onForward: (() -> Void)?
  /// Le délai de grâce court encore : la bulle porte un « Annuler » cliquable,
  /// et rien n'est encore parti sur le réseau.
  var onCancelPending: (() -> Void)?
  /// Supprimer la bulle — parité Beeper. « Ici » ne quitte pas la machine ;
  /// « pour tout le monde » part sur le réseau. `nil` = ce geste n'est pas offert.
  var onDeleteLocally: (() -> Void)?
  var onDeleteEverywhere: (() -> Void)?
  /// Voter sur le sondage de cette bulle. `nil` = sondage en lecture seule.
  var onVotePoll: ((String) -> Void)?

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// Les gens du fil : ce sont eux qui font d'un « @Nom » une mention.
  @Environment(\.mentionNames) private var mentionNames

  /// Le curseur est sur cette rangée : les actions rapides se montrent.
  @State private var isHovered = false
  /// Le sélecteur de réactions est ouvert — la rangée reste alors visible,
  /// même si le curseur est parti dans le popover.
  @State private var isPickingReaction = false
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

        // Le corps SEUL — pièces jointes, bulle, carte de lien. C'est lui que
        // les pastilles mordent : accrochées à la pile entière, elles se
        // seraient posées sous « Modifié » au lieu du coin de la bulle.
        VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 6) {
          if let album {
            MediaAlbumView(
              media: albumMedia,
              layout: album,
              width: Self.mediaWidth,
              corners: corners,
              theme: theme,
              onOpen: openMedia
            )
          }
          ForEach(stackedAttachments) { attachment in
            attachmentView(attachment)
          }

          if let post = sharedPost {
            SharedPostCard(
              post: post,
              theme: theme,
              typeface: typeface,
              width: Self.mediaWidth,
              cornerRadius: 12
            )
          } else if let poll = message.poll {
            PollView(
              poll: poll,
              theme: theme,
              typeface: typeface,
              isFromMe: message.isFromMe,
              onVote: onVotePoll
            )
          } else if message.isRetracted {
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
              // Un mot plus long que la bulle — un chemin, une URL — : sans
              // ceci, `Text` tronque la ligne d'une ellipse au lieu de couper
              // le mot. On lui rend sa hauteur libre, il replie.
              .fixedSize(horizontal: false, vertical: true)
              .padding(.horizontal, 12)
              .padding(.vertical, 8)
              .background(corners.shape.fill(message.isFromMe ? theme.bubbleOut : theme.bubbleIn))
          }

          if let link = previewedLink {
            LinkPreviewCard(url: link, theme: theme, typeface: typeface, bridged: bridgedPreview)
          }
        }
        // Les pastilles MORDENT le coin bas de la bulle, du côté opposé à
        // l'expéditeur : à moitié dedans, à moitié dehors, comme Messages.
        .overlay(alignment: message.isFromMe ? .bottomLeading : .bottomTrailing) {
          if !message.reactions.isEmpty {
            ReactionPills(
              reactions: message.reactions,
              theme: theme,
              typeface: typeface,
              emojiSize: 11,
              onTap: onReact
            )
            .offset(x: message.isFromMe ? -8 : 8, y: ReactionPills.overhang)
          }
        }
        // C'est CE bord-là que le visage du groupe regarde — cf. `.bubbleBottom`.
        .bubbleBottomGuide(position)
        // Le débord se réserve, sinon la suite passerait par-dessus.
        .padding(.bottom, message.reactions.isEmpty ? 0 : ReactionPills.overhang)

        // Une bulle reçue dans une autre langue que celle du Mac porte
        // « Traduire » — ou sa traduction d'emblée si le fil le demande. Sur
        // cet appareil, sans réseau : cf. `TextTranslator`.
        #if canImport(Translation)
        if !message.isFromMe, showsTextBubble, !message.isRetracted,
           let source = TextTranslator.foreignLanguage(of: displayText) {
          IncomingTranslationSlot(
            messageID: message.id,
            text: displayText,
            source: source,
            conversationID: message.conversationID,
            theme: theme,
            typeface: typeface,
            font: Typography.bubble(typeface, scale: textScale)
          )
        }
        #endif

        if let onCancelPending {
          Button("Annuler", action: onCancelPending)
            .buttonStyle(.plain)
            .font(Typography.meta(typeface))
            .foregroundStyle(theme.accent)
            .help("Ce message n’est pas encore parti")
            .accessibilityLabel("Annuler l’envoi de ce message")
        }

        if let footnote = footnoteLabel {
          Text(footnote.text)
            .font(Typography.meta(typeface))
            .foregroundStyle(theme.inkTertiary)
            .help(footnote.help)
            .accessibilityLabel(footnote.help)
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
      .contextMenu { bubbleMenu(full: true) }
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
      if hovering { onHoverBegan?() }
      if reduceMotion {
        isHovered = hovering
      } else {
        withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
      }
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

  /// Les quatre rayons de cette bulle-là. Cf. `BubbleShape`.
  private var corners: BubbleCorners {
    BubbleShape.corners(isFromMe: message.isFromMe, position: position, radius: 14)
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
    guard showsLinkPreviews, !message.isRetracted, !message.isEmojiOnly, showsTextBubble,
          sharedPost == nil
    else { return nil }
    // L'aperçu livré par le réseau désigne son adresse ; sinon la première du texte.
    if let bridged = message.linkPreview, bridgedPreview != nil, let url = bridged.webURL { return url }
    // Le même mémo que le corps : le détecteur ne repasse pas sur la bulle.
    return LinkedText.firstWebURL(in: displayText)
  }

  /// L'aperçu déjà produit côté réseau, s'il a de quoi faire une carte.
  private var bridgedPreview: LinkPreview? { message.linkPreview?.asLinkPreview }

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
        bubbleMenu(full: false)
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
    if let aside = message.agentAside {
      parts.append(aside.footnoteFR)
      help.append("Ce message nomme un agent : il n’est pas parti sur le réseau. Seuls toi et l’agent le voient.")
    }
    guard !parts.isEmpty else { return nil }
    return (parts.joined(separator: " · "), help.joined(separator: "\n\n"))
  }

  /// Citation compacte au-dessus de la bulle : un filet, l'auteur, une ligne de
  /// texte — et le chemin de retour vers l'original, comme sur l'iPhone.
  @ViewBuilder
  private func quoteChip(_ quote: QuotedMessage) -> some View {
    let content = HStack(spacing: 6) {
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
          // Quatre lignes : assez pour relire ce à quoi on répond — un ordre
          // à @cc, une phrase entière — sans transformer la citation en fil.
          .lineLimit(4)
      }
    }
    .padding(.leading, 2)
    .frame(maxWidth: 420, alignment: message.isFromMe ? .trailing : .leading)
    .accessibilityLabel("En réponse à \(quote.senderName) : \(quote.text)")

    if let onQuoteTap {
      Button(action: onQuoteTap) { content }
        .buttonStyle(.plain)
        // Le doigt dit que ça mène quelque part — le seul indice, la citation
        // ne changeant pas d'aspect.
        .onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }
        .help("Aller au message cité")
        .accessibilityHint("Va au message cité")
    } else {
      content
    }
  }

  /// Le menu de la bulle. `full` : le clic droit, seul chemin clavier vers
  /// réagir et répondre, les porte ; le « … » de la rangée de survol non — les
  /// deux boutons sont déjà à sa gauche, les répéter ne faisait que rallonger.
  @ViewBuilder
  private func bubbleMenu(full: Bool) -> some View {
    if full {
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
    }
    if onEdit != nil || onUndoSend != nil || onForward != nil {
      Divider()
      if let onEdit {
        Button("Modifier…") { onEdit() }
      }
      if let onForward {
        Button("Transférer…") { onForward() }
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

  /// La largeur d'une photo dans une bulle du Mac — celle de la mosaïque aussi :
  /// un album ne prend pas plus de place qu'une photo seule.
  private static let mediaWidth: CGFloat = 280

  private var visibleAttachments: [MessageAttachment] {
    message.attachments.map(Self.repaired).filter { $0.isImage || $0.isVideo || $0.resolvedFileURL != nil }
  }

  /// Ce qui entre dans la mosaïque : photos et vidéos. Un GIF se joue, un vocal
  /// s'écoute, un fichier s'ouvre — tous les trois restent empilés.
  private var albumMedia: [MessageAttachment] {
    visibleAttachments.filter { ($0.isImage || $0.isVideo) && !$0.isGIF }
  }

  private var album: MediaAlbumLayout? {
    sharedPost == nil ? MediaAlbumLayout.plan(count: albumMedia.count) : nil
  }

  private var stackedAttachments: [MessageAttachment] {
    guard album != nil else { return sharedPost == nil ? visibleAttachments : [] }
    let inAlbum = Set(albumMedia.map(\.id))
    return visibleAttachments.filter { !inAlbum.contains($0.id) }
  }

  /// Le post partagé que porte ce message, son média raccroché au cache.
  private var sharedPost: SharedPost? {
    guard var post = SharedPost.parse(message) else { return nil }
    post.media = post.media.map(Self.repaired)
    return post
  }

  /// Les médias d'un message dans l'ordre de son album, chemins recollés au
  /// cache : ce que Quick Look ouvrirait. Espace, dans le fil, s'en sert sur la
  /// bulle survolée sans passer par la mosaïque.
  static func quickLookURLs(for message: ChatMessage) -> [URL] {
    message.attachments
      .map(repaired)
      .filter { ($0.isImage || $0.isVideo) && !$0.isGIF }
      .compactMap(\.resolvedFileURL)
  }

  /// Quick Look sur le média touché, les autres du message à portée de flèche.
  private func openMedia(at index: Int) {
    let urls = albumMedia.compactMap(\.resolvedFileURL)
    guard albumMedia.indices.contains(index),
          let tapped = albumMedia[index].resolvedFileURL,
          let start = urls.firstIndex(of: tapped)
    else { return }
    QuickLookPanel.open(urls: urls, startAt: start)
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

  /// La bande sous un « @Nom ». Sur ma bulle, elle s'éclaircit ; sur celle
  /// d'en face, elle prend l'accent — dans les deux cas la mention se voit
  /// sans que l'encre du corps change.
  private var mentionBand: Color {
    message.isFromMe ? theme.paper.opacity(0.24) : theme.accent.opacity(0.14)
  }

  /// Corps du message avec les occurrences de la requête ⌘F surlignées.
  /// Le message visé par la navigation est marqué plus franchement que les autres.
  private var highlighted: AttributedString {
    let ranges = ConversationSearch.highlightRanges(in: displayText, query: highlightQuery)
    // Hors recherche, le corps passe par le lecteur de Markdown : les plages de
    // surlignage, elles, désignent le texte nu et lui passent devant.
    guard !ranges.isEmpty else {
      return LinkedText.render(
        text: displayText,
        tint: message.isFromMe ? theme.bubbleOutInk : theme.accent,
        mentions: mentionNames,
        mentionBand: mentionBand
      )
    }
    var attributed = AttributedString(displayText)
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
      base: attributed,
      mentions: mentionNames,
      mentionBand: mentionBand
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
    } else if let url = repaired.resolvedFileURL, repaired.isGIF {
      // Un GIF se joue : montrer sa première trame, ce serait le rater.
      AnimatedImageView(
        url: url,
        maxWidth: 280,
        maxHeight: 320,
        cornerRadius: 12,
        placeholder: theme.bubbleIn,
        label: repaired.filename ?? "image animée"
      )
    } else if let url = repaired.resolvedFileURL, repaired.isImage {
      AttachmentImageView(
        url: url,
        maxWidth: Self.mediaWidth,
        maxHeight: 320,
        placeholder: theme.bubbleIn,
        border: theme.edge.opacity(0.5),
        label: repaired.filename ?? "Image"
      ) {
        unavailableImageLabel(repaired)
      }
      .onTapGesture { QuickLookPanel.open(urls: [url]) }
      .help("Ouvrir en grand")
      .accessibilityAddTraits(.isButton)
    } else if let url = repaired.resolvedFileURL, repaired.isVideo {
      AttachmentVideoView(
        url: url,
        maxWidth: Self.mediaWidth,
        maxHeight: 320,
        placeholder: theme.bubbleIn,
        border: theme.edge.opacity(0.5),
        label: repaired.filename ?? "Vidéo"
      )
    } else if repaired.isImage {
      unavailableImageLabel(repaired)
    } else {
      AttachmentFileCard(
        attachment: repaired,
        theme: theme,
        typeface: typeface,
        onOpen: repaired.resolvedFileURL.map { url in { QuickLookPanel.open(urls: [url]) } }
      )
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

/// Une bulle ne dépend que de son message et de la façon de l'écrire. Sans ce
/// `==`, SwiftUI compare la vue champ par champ, tombe sur les fermetures
/// d'action — jamais égales entre elles — et conclut que TOUTE bulle a changé :
/// le moindre rafraîchissement du fil (« Alice écrit… », un accusé de lecture)
/// refaisait le corps et la mise en page des quatre cents bulles d'un groupe.
/// On ne compare donc pas les fermetures, on compare ce qu'elles offrent :
/// l'action est-elle proposée ou non. Leur contenu, lui, ne capture que le
/// magasin et l'identifiant du message — deux choses qui ne bougent pas.
extension MessageBubbleView: Equatable {
  nonisolated static func == (lhs: MessageBubbleView, rhs: MessageBubbleView) -> Bool {
    lhs.message == rhs.message
      && lhs.theme == rhs.theme
      && lhs.typeface == rhs.typeface
      && lhs.textScale == rhs.textScale
      && lhs.showsLinkPreviews == rhs.showsLinkPreviews
      && lhs.highlightQuery == rhs.highlightQuery
      && lhs.isCurrentMatch == rhs.isCurrentMatch
      && lhs.position == rhs.position
      && (lhs.onQuoteTap == nil) == (rhs.onQuoteTap == nil)
      && (lhs.onReact == nil) == (rhs.onReact == nil)
      && (lhs.onReply == nil) == (rhs.onReply == nil)
      && (lhs.onEdit == nil) == (rhs.onEdit == nil)
      && (lhs.onUndoSend == nil) == (rhs.onUndoSend == nil)
      && (lhs.onForward == nil) == (rhs.onForward == nil)
      && (lhs.onCancelPending == nil) == (rhs.onCancelPending == nil)
      && (lhs.onDeleteLocally == nil) == (rhs.onDeleteLocally == nil)
      && (lhs.onDeleteEverywhere == nil) == (rhs.onDeleteEverywhere == nil)
      && (lhs.onVotePoll == nil) == (rhs.onVotePoll == nil)
  }
}
