import CorrespondanceCore
import CorrespondanceUI
import SwiftUI

/// Une bulle du fil, à la main.
///
/// Le rendu est celui du Mac (`MessageBubbleView`) : mêmes coins, même
/// interligne dérivé du thème, même emoji nu et grand, mêmes citations, mêmes
/// pastilles de réaction, même aperçu de lien. Ce qui change tient au doigt :
/// le survol n'existe pas, donc l'appui long ouvre `MessageActionsOverlay`
/// (les smileys au-dessus, les actions en dessous) et citer se fait par
/// balayage vers la droite sur la bulle.
struct MessageBubble: View {
  let message: ChatMessage
  let theme: WritingTheme
  var typeface: WritingTypeface = .quattro
  /// Nom coloré au-dessus du groupe, en conversation de groupe.
  var senderLabel: String?
  /// Sa place dans la prise de parole : c'est elle qui resserre les coins.
  var position: BubblePosition = .alone
  var showsLinkPreviews = true
  var onReply: (() -> Void)?
  /// Voter sur le sondage de cette bulle. `nil` = sondage en lecture seule.
  var onVotePoll: ((String) -> Void)?
  /// Taper une pastille de réaction : la retirer ou la rejoindre.
  var onReact: ((String) -> Void)?
  /// L'appui long. `nil` = bulle inerte (résultat de recherche, aperçu).
  var onLongPress: (() -> Void)?
  /// Taper la citation : remonter au message cité dans le fil. `nil` = citation inerte.
  var onQuoteTap: (() -> Void)?
  /// Le délai de grâce court encore : la bulle porte un « Annuler », et rien
  /// n'est parti sur le réseau.
  var onCancelPending: (() -> Void)?
  /// Les trois gestes d'une proposition de « cc ». `nil` = carte en lecture seule.
  var onSendProposal: (() -> Void)?
  var onEditProposal: (() -> Void)?
  var onIgnoreProposal: (() -> Void)?

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// Les gens du fil : ce sont eux qui font d'un « @Nom » une mention.
  @Environment(\.mentionNames) private var mentionNames
  @State private var dragOffset: CGFloat = 0
  /// Le seuil de citation est franchi : le doigt l'a senti, on ne le redit pas.
  @State private var hasCrossedThreshold = false
  /// Le média sur lequel la visionneuse s'ouvre. `nil` = elle est fermée.
  @State private var opened: OpenedMedia?
  /// Le fichier joint dont on regarde l'aperçu Quick Look.
  @State private var previewedFile: PreviewedFile?
  @Namespace private var albumZoom

  struct PreviewedFile: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
  }

  private var bodySize: CGFloat { Typography.bubbleSize() }

  /// Les quatre rayons de cette bulle-là. Cf. `BubbleShape`.
  private var corners: BubbleCorners {
    BubbleShape.corners(isFromMe: message.isFromMe, position: position, radius: 18)
  }

  var body: some View {
    // Une proposition n'est pas une bulle : ni auteur, ni balayage pour citer,
    // ni appui long. C'est une carte, et elle ne quitte pas cet appareil.
    if let proposal = message.agentProposal {
      AgentProposalCard(
        proposal: proposal,
        theme: theme,
        typeface: typeface,
        onSend: onSendProposal,
        onEdit: onEditProposal,
        onIgnore: onIgnoreProposal
      )
      .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      bubble
    }
  }

  private var bubble: some View {
    VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 4) {
      if let senderLabel, !message.isFromMe {
        Text(senderLabel)
          .font(Typography.meta(typeface))
          .fontWeight(.semibold)
          .foregroundStyle(SenderTint.color(for: senderLabel, theme: theme))
          .padding(.leading, 14)
          .accessibilityHidden(true)
      }

      HStack(spacing: 0) {
        if message.isFromMe { Spacer(minLength: 44) }
        bubbleStack
        if !message.isFromMe { Spacer(minLength: 44) }
      }
    }
    // La flèche paraît dans la marge libérée, dès que le geste est franc.
    .overlay(alignment: .leading) {
      Image(systemName: "arrowshape.turn.up.left")
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(theme.inkTertiary)
        .opacity(min(max((dragOffset - 20) / 14, 0), 1))
        .offset(x: -26)
        .accessibilityHidden(true)
    }
    .offset(x: dragOffset)
    .gesture(replyDrag)
    // Le seuil se sent sous le doigt : une fois par geste, à son franchissement.
    .sensoryFeedback(.impact(weight: .light), trigger: hasCrossedThreshold) { _, new in new }
    .frame(maxWidth: .infinity, alignment: message.isFromMe ? .trailing : .leading)
  }

  private var bubbleStack: some View {
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
            onOpen: { opened = OpenedMedia($0) }
          )
          .matchedTransitionSource(id: "album", in: albumZoom)
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
            cornerRadius: 16
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
          Text(displayText)
            .font(.system(size: 44))
            .padding(.horizontal, 2)
            .accessibilityLabel(displayText)
        } else if showsTextBubble {
          Text(highlighted)
            .font(Typography.bubble(typeface))
            .lineSpacing(theme.bubbleLineSpacing(forBodySize: bodySize))
            .foregroundStyle(message.isFromMe ? theme.bubbleOutInk : theme.bubbleInInk)
            // Un mot plus long que la bulle — un chemin, une URL — : sans ceci,
            // `Text` tronque la ligne d'une ellipse au lieu de couper le mot.
            .fixedSize(horizontal: false, vertical: true)
            // Pas de sélection de texte : elle prendrait l'appui long, qui
            // ouvre les actions — et « Copier le texte » y est.
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
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
            emojiSize: 13,
            showsSendersOnLongPress: true,
            onTap: onReact
          )
          .offset(x: message.isFromMe ? -8 : 8, y: ReactionPills.overhang)
        }
      }
      // C'est CE bord-là que le visage du groupe regarde — cf. `.bubbleBottom`.
      .bubbleBottomGuide(position)
      // Le débord se réserve, sinon la suite passerait par-dessus.
      .padding(.bottom, message.reactions.isEmpty ? 0 : ReactionPills.overhang)

      // Une bulle reçue dans une autre langue porte « Traduire » — sur
      // l'iPhone, sans réseau : cf. `TextTranslator`.
      #if canImport(Translation)
      if !message.isFromMe, showsTextBubble, !message.isRetracted,
         let source = TextTranslator.foreignLanguage(of: displayText) {
        IncomingTranslationSlot(
          messageID: message.id, text: displayText, source: source,
          conversationID: message.conversationID, theme: theme, typeface: typeface,
          font: Typography.bubble(typeface)
        )
      }
      #endif

      if let onCancelPending {
        Button("Annuler", action: onCancelPending)
          .buttonStyle(.plain)
          .font(Typography.meta(typeface))
          .foregroundStyle(theme.accent)
          .accessibilityLabel("Annuler l'envoi de ce message")
      }

      if let footnote = footnoteLabel {
        Text(footnote)
          .font(Typography.meta(typeface))
          .foregroundStyle(theme.inkTertiary)
      }

    }
    .opacity(message.isPending ? 0.55 : 1)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLine)
    // LA LONGUEUR DE LIGNE, comme sur le Mac : sans plafond, une phrase
    // traverserait tout un iPad et l'œil ne retrouverait plus le début de la
    // ligne suivante. Le cadre borne la largeur PROPOSÉE, la pile continue
    // d'épouser son contenu — les pastilles ne s'étirent donc pas.
    .frame(
      maxWidth: 520,
      alignment: message.isFromMe ? .trailing : .leading
    )
    .onLongPressGesture(minimumDuration: 0.35) {
      onLongPress?()
    }
    .accessibilityAction(named: "Actions du message") { onLongPress?() }
    .fullScreenCover(item: $opened) { start in
      MediaViewer(media: albumMedia.isEmpty ? visibleAttachments : albumMedia, startAt: start.id)
        .navigationTransition(.zoom(sourceID: "album", in: albumZoom))
    }
    .sheet(item: $previewedFile) { file in
      FilePreview(url: file.url)
        .ignoresSafeArea()
    }
  }

  // MARK: - Gestes

  /// Répondre en citant se fait par balayage vers la droite sur la bulle — le
  /// geste de WhatsApp, de Signal et de Beeper. Le retour au repos est animé,
  /// sauf sous « Réduire les animations ».
  private var replyDrag: some Gesture {
    DragGesture(minimumDistance: 18)
      .onChanged { value in
        guard onReply != nil, value.translation.width > 0 else { return }
        dragOffset = min(value.translation.width * 0.5, 56)
        if dragOffset > Self.replyThreshold { hasCrossedThreshold = true }
      }
      .onEnded { _ in
        let triggered = dragOffset > Self.replyThreshold
        hasCrossedThreshold = false
        if reduceMotion { dragOffset = 0 }
        else { withAnimation(.spring(duration: 0.28)) { dragOffset = 0 } }
        if triggered { onReply?() }
      }
  }

  /// Au-delà, le geste vaut citation.
  private static let replyThreshold: CGFloat = 34

  // MARK: - Morceaux

  private var retractedBubble: some View {
    Text("Message annulé")
      .font(Typography.bubble(typeface).italic())
      .foregroundStyle(theme.inkTertiary)
      .padding(.horizontal, 13)
      .padding(.vertical, 9)
      .background(
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .strokeBorder(theme.edge, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
      )
      .accessibilityLabel("Message annulé par son auteur")
  }

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
    // Le trait d'accent n'a pas de hauteur à lui : sans ce garde-fou, il
    // prend toute celle qu'on lui propose et la citation avale la bulle —
    // le texte du message se tronquait derrière elle. Même parade que le
    // composer.
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityLabel("En réponse à \(quote.senderName) : \(quote.text)")

    if let onQuoteTap {
      Button(action: onQuoteTap) { content }
        .buttonStyle(.plain)
        .accessibilityHint("Va au message cité")
    } else {
      content
    }
  }

  private var footnoteLabel: String? {
    var parts: [String] = []
    if message.editedAt != nil, !message.isRetracted { parts.append("Modifié") }
    if let effect = message.expressiveEffectName, !message.isRetracted {
      parts.append("envoyé avec \(effect)")
    }
    if let aside = message.agentAside { parts.append(aside.footnoteFR) }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
        maxWidth: 300,
        maxHeight: 420,
        cornerRadius: 16,
        placeholder: theme.bubbleIn,
        label: repaired.filename ?? "image animée"
      )
    } else if let url = repaired.resolvedFileURL, repaired.isImage {
      // En grand : sur un écran de téléphone, une photo de 280 points est un
      // timbre. On la laisse prendre la largeur utile de la bulle.
      AttachmentImageView(
        url: url,
        maxWidth: 300,
        maxHeight: 420,
        cornerRadius: 16,
        placeholder: theme.bubbleIn,
        border: theme.edge.opacity(0.5),
        label: repaired.filename ?? "Image"
      ) {
        unavailable(repaired, systemImage: "photo")
      }
      .onTapGesture { opened = OpenedMedia(0) }
      .accessibilityAddTraits(.isButton)
    } else if let url = repaired.resolvedFileURL, repaired.isVideo {
      StableVideoPlayer(url: url)
        .frame(width: Self.mediaWidth, height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(theme.edge.opacity(0.5), lineWidth: 1)
        )
        .accessibilityLabel(repaired.filename ?? "Vidéo")
    } else if repaired.isImage {
      unavailable(repaired, systemImage: "photo")
    } else {
      AttachmentFileCard(
        attachment: repaired,
        theme: theme,
        typeface: typeface,
        onOpen: repaired.resolvedFileURL.map { url in { previewedFile = PreviewedFile(url: url) } }
      )
    }
  }

  private func unavailable(_ attachment: MessageAttachment, systemImage: String) -> some View {
    Label(attachment.filename ?? "Pièce jointe", systemImage: systemImage)
      .font(Typography.meta(typeface))
      .foregroundStyle(theme.inkSecondary)
      .padding(10)
      .background(theme.bubbleIn, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  // MARK: - Texte

  /// La largeur d'une photo dans une bulle — celle de la mosaïque aussi : un
  /// album ne prend pas plus de place qu'une photo seule.
  private static let mediaWidth: CGFloat = 300

  private var visibleAttachments: [MessageAttachment] {
    message.attachments.map(Self.repaired).filter {
      $0.isImage || $0.isVideo || $0.resolvedFileURL != nil
    }
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

  private var displayText: String {
    let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let hasVisibleImage = message.attachments.contains {
      let repaired = Self.repaired($0)
      return repaired.isImage && repaired.resolvedFileURL != nil
    }
    if hasVisibleImage, trimmed.isEmpty || trimmed == "📷 Photo" { return "" }
    let hasPlayableAudio = message.attachments.contains {
      let repaired = Self.repaired($0)
      return repaired.isAudio && repaired.resolvedFileURL != nil
    }
    if hasPlayableAudio, trimmed.isEmpty || trimmed == "🎤 Message audio" { return "" }
    return trimmed
  }

  private var showsTextBubble: Bool { !displayText.isEmpty }

  private var previewedLink: URL? {
    guard showsLinkPreviews, !message.isRetracted, !message.isEmojiOnly, showsTextBubble,
          sharedPost == nil
    else { return nil }
    // L'aperçu livré par le réseau désigne son adresse ; sinon la première du texte.
    if let bridged = message.linkPreview, bridgedPreview != nil, let url = bridged.webURL { return url }
    return TextLinks.firstWebURL(in: displayText)
  }

  /// L'aperçu déjà produit côté réseau, s'il a de quoi faire une carte.
  private var bridgedPreview: LinkPreview? { message.linkPreview?.asLinkPreview }

  private var highlighted: AttributedString {
    LinkedText.render(
      text: displayText,
      tint: message.isFromMe ? theme.bubbleOutInk : theme.accent,
      mentions: mentionNames,
      // Sur ma bulle la bande s'éclaircit, sur celle d'en face elle prend
      // l'accent : la mention se voit sans que l'encre du corps change.
      mentionBand: message.isFromMe ? theme.paper.opacity(0.24) : theme.accent.opacity(0.14)
    )
  }

  private var accessibilityLine: String {
    var parts: [String] = []
    if let senderLabel, !message.isFromMe { parts.append(senderLabel) }
    parts.append(message.isFromMe ? "Moi" : "Reçu")
    parts.append(message.sidebarPreviewText)
    parts.append(message.sentAt.formatted(date: .omitted, time: .shortened))
    for reaction in message.reactions { parts.append("\(reaction.emoji) \(reaction.count)") }
    return parts.joined(separator: ", ")
  }

  /// La pièce jointe avec son chemin local retrouvé dans le cache, si elle y est.
  static func repaired(_ attachment: MessageAttachment) -> MessageAttachment {
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
