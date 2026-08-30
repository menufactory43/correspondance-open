import AppKit
import SwiftUI

/// Les marges de la page, mesurées sur la largeur qu'on lui donne.
///
/// La grande marge de gauche d'iA Writer est un luxe de grande fenêtre : dans
/// une fenêtre détachée réduite à un post-it, elle mangerait la page entière.
/// La page respire quand elle est large, et se serre quand elle est étroite —
/// jamais l'inverse, jamais de largeur fixe qui déborde.
struct FocusPageMetrics: Equatable {
  var leading: CGFloat
  var trailing: CGFloat
  var top: CGFloat
  var bottom: CGFloat
  /// Fenêtre serrée : l'entête tient sur une ligne, les bannières s'effacent.
  var isCompact: Bool
  /// Une photo ne fait jamais déborder la colonne : au plus 360 points, et
  /// jamais plus que la page n'en laisse entre ses marges.
  var attachmentMaxWidth: CGFloat = 360

  /// La largeur de colonne du texte. Ce n'est qu'un plafond : sous cette
  /// largeur, la page prend ce qu'on lui laisse.
  var letterWidth: CGFloat { LayoutMetrics.letterWidth }

  static let page = FocusPageMetrics(
    leading: LayoutMetrics.pageLeading,
    trailing: Spacing.xl,
    top: LayoutMetrics.pageTopInset * 0.4,
    bottom: LayoutMetrics.pageBottomInset,
    isCompact: false
  )

  static func resolve(width: CGFloat) -> FocusPageMetrics {
    let w = max(width, 0)
    let leading: CGFloat
    switch w {
    case ..<380: leading = 14
    case ..<640: leading = 14 + (w - 380) * (40 - 14) / (640 - 380)
    case ..<900: leading = 40 + (w - 640) * (LayoutMetrics.pageLeading - 40) / (900 - 640)
    default: leading = LayoutMetrics.pageLeading
    }
    let trailing: CGFloat = w < 380 ? 12 : (w < 640 ? 16 : Spacing.xl)
    return FocusPageMetrics(
      leading: leading,
      trailing: trailing,
      top: w < 380 ? 4 : (w < 640 ? 10 : LayoutMetrics.pageTopInset * 0.4),
      bottom: w < 380 ? Spacing.sm : (w < 640 ? Spacing.lg : LayoutMetrics.pageBottomInset),
      isCompact: w < 420,
      attachmentMaxWidth: max(80, min(360, w - leading - trailing))
    )
  }
}

/// Une conversation à la fois — page zen, chrome fantôme.
struct FocusConversationView: View {
  /// La session lue par cette page. `nil` = celle de l'inbox.
  var session: ConversationSession?

  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var theme: WritingTheme { themes.theme }
  private var isWriting: Bool { store.isComposerFocused }
  private var live: ConversationSession? { session ?? store.primarySession }
  private var conversation: Conversation? {
    live.flatMap { store.conversationRow($0.conversationID) }
  }

  var body: some View {
    GeometryReader { geometry in
      page(FocusPageMetrics.resolve(width: geometry.size.width))
    }
  }

  private func page(_ metrics: FocusPageMetrics) -> some View {
    ZStack(alignment: .topLeading) {
      theme.paper.ignoresSafeArea()

      VStack(alignment: .leading, spacing: 0) {
        Spacer(minLength: metrics.top)

        if store.usingDemoData, !metrics.isCompact {
          PermissionBanner()
            .padding(.bottom, Spacing.lg)
            .opacity(isWriting ? 0 : 1)
        }

        if let conversation {
          Text(conversation.title)
            .font(Typography.toolbarPhrase(themes.typeface))
            .foregroundStyle(theme.inkTertiary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.bottom, metrics.isCompact ? Spacing.xs : Spacing.md)
            .opacity(isWriting ? 0 : 1)
            .accessibilityHidden(isWriting)

          FocusTranscriptView(session: live, metrics: metrics)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
          VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(store.isLoading ? "Chargement…" : "Rien à lire pour l’instant.")
              .font(Typography.emptyState(themes.typeface))
              .foregroundStyle(theme.inkSecondary)
            Text(store.matrixStatusFR)
              .font(Typography.meta(themes.typeface))
              .foregroundStyle(theme.inkTertiary)
            Text(store.iMessageStatusFR)
              .font(Typography.meta(themes.typeface))
              .foregroundStyle(theme.inkTertiary)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
      }
      .frame(maxWidth: metrics.letterWidth, alignment: .leading)
      .padding(.leading, metrics.leading)
      .padding(.trailing, metrics.trailing)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .animation(chromeAnimation, value: isWriting)
    }
  }

  private var chromeAnimation: Animation? {
    reduceMotion ? nil : .easeOut(duration: 0.15)
  }

}

/// Fil en prose — le brouillon est le dernier paragraphe de la page.
struct FocusTranscriptView: View {
  /// La session lue. `nil` = celle de l'inbox.
  var session: ConversationSession?
  var metrics: FocusPageMetrics = .page
  /// Faux quand la page pose elle-même le composer sous le fil — c'est le cas
  /// de la fenêtre détachée, où le composer ne doit jamais défiler hors de vue.
  var includesEditor = true

  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isShowingThread = false
  /// Faux tant que la page se met en place : à l'ouverture d'une conversation,
  /// les vingt derniers paragraphes ne doivent pas se tracer un par un.
  @State private var animatesArrivals = false
  /// Ce que la page considère comme déjà posé. Tout ce qui arrive après se
  /// trace ; ce qui est là depuis toujours paraît sans cérémonie.
  @State private var settledMessageID: String?
  /// Suppression demandée au clic droit, en attente de confirmation.
  @State private var pendingDeletion: PendingDeletion?
  /// Au lancement, la page reste blanche jusqu'à ce que la fenêtre soit peinte :
  /// construire cent paragraphes avant la première frame, c'est le rebond de
  /// trop dans le Dock. Le fil est de toute façon invisible tant qu'il n'est
  /// pas ancré en bas — il arrive donc entier, un instant plus tard, sans saut.
  @State private var awaitsFirstFrame = !LaunchGate.didPaintFirstWindow
  /// Vrai tant que le lecteur n'a pas remonté la page : c'est ce qui décide si
  /// une hauteur qui change (réaction, citation, aperçu) le garde en bas.
  @State private var isNearBottom = true

  /// Le message visé et l'étendue de sa suppression — le temps de l'alerte.
  private struct PendingDeletion: Identifiable {
    let messageID: String
    let scope: MessageBubbleView.Deletion

    var id: String { "\(messageID)|\(scope.rawValue)" }
  }

  private var theme: WritingTheme { themes.theme }
  private var isWriting: Bool { store.isComposerFocused }
  private var live: ConversationSession? { session ?? store.primarySession }
  private var conversationID: String? { live?.conversationID }
  private var thread: [ChatMessage] { awaitsFirstFrame ? [] : (live?.messages ?? []) }
  private var row: Conversation? { conversationID.flatMap { store.conversationRow($0) } }

  /// Le geste choisi dans les réglages — encre ou plume.
  private var arrival: MessageArrival { themes.messageArrival }

  /// Le geste ne joue que sur un vrai message, jamais sur une bascule de
  /// conversation. Et il ne dure que son temps : passé ce délai le paragraphe
  /// est un paragraphe comme les autres, et il ne se retracera pas si le
  /// défilement le fait renaître.
  /// Vrai pour le dernier message tant qu'il n'a pas fini de se poser. Calculé
  /// dans le corps de la vue : la ligne connaît donc son sort dès sa naissance,
  /// et sa valeur initiale suffit à lancer le geste — pas de rattrapage.
  private func isFresh(_ message: ChatMessage) -> Bool {
    animatesArrivals
      && store.didSettleInitialMatrixSync
      && message.id == thread.last?.id
      && message.id != settledMessageID
  }

  private func noteArrival(increased: Bool) {
    guard increased, animatesArrivals else { return }
    let id = thread.last?.id
    Task {
      try? await Task.sleep(for: .seconds(1.2))
      if thread.last?.id == id { settledMessageID = id }
    }
  }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        // Pile simple, et surtout pas paresseuse. Un `LazyVStack` ancré en bas
        // sur des lignes hautes et inégales — des photos — ne converge jamais :
        // il place, découvre que les hauteurs ne sont pas celles qu'il croyait,
        // retraduit l'ancre, replace, sans fin. Le fil tournait à 80 % d'un cœur
        // sans que rien ne bouge à l'écran. Le fil est borné à cent vingt
        // messages : les construire tous coûte moins cher que cette boucle.
        VStack(alignment: .leading, spacing: Spacing.md) {
          ForEach(messageGroups) { group in
            VStack(alignment: .leading, spacing: 6) {
              // Fil fusionné : la page dit d'où repart la suite, une fois par
              // bascule de réseau — jamais plus.
              if let origin = group.networkOrigin {
                Label(origin.labelFR, systemImage: origin.systemImage)
                  .font(Typography.toolbarPhrase(themes.typeface))
                  .foregroundStyle(theme.inkTertiary)
              }
              // Une page ne réannonce pas son locuteur à chaque phrase : un
              // libellé par prise de parole, et rien du tout en tête-à-tête.
              if let label = focusLabel(for: group) {
                Text(label)
                  .font(Typography.toolbarPhrase(themes.typeface))
                  .foregroundStyle(theme.inkTertiary)
              }
              ForEach(group.messages) { message in
                VStack(alignment: .leading, spacing: 6) {
                  ForEach(message.attachments) { raw in
                    let attachment = FocusAttachment.repaired(raw)
                    if let url = attachment.resolvedFileURL, attachment.isImage {
                      AttachmentImageView(
                        url: url,
                        maxWidth: metrics.attachmentMaxWidth,
                        maxHeight: 400,
                        cornerRadius: 8,
                        placeholder: theme.paperSecondary,
                        border: nil,
                        label: attachment.filename ?? "Image"
                      ) {
                        EmptyView()
                      }
                    } else if let url = attachment.resolvedFileURL, attachment.isVideo {
                      AttachmentVideoView(
                        url: url,
                        maxWidth: metrics.attachmentMaxWidth,
                        maxHeight: 400,
                        cornerRadius: 8,
                        placeholder: theme.paperSecondary,
                        border: nil,
                        label: attachment.filename ?? "Vidéo"
                      )
                    }
                  }
                  if shouldShowFocusText(message) {
                    LinkedText(text: message.text, tint: theme.accent)
                      .font(pageFont)
                      .foregroundStyle(theme.ink.opacity(message.isFromMe ? 0.72 : 1))
                      // L'interligne DE LETTRE du thème, entier : la page Focus
                      // est de la prose, et la prose se lit aérée. Il suit
                      // l'échelle comme le corps — les deux vont ensemble.
                      .lineSpacing(theme.lineSpacing(forBodySize: pageBodySize))
                  }
                }
                .opacity(message.isPending ? 0.5 : 1)
                .id(message.id)
                .frame(maxWidth: .infinity, alignment: .leading)
                .messageArrival(
                  arrival,
                  isFresh: isFresh(message),
                  isEnabled: !reduceMotion
                )
                // La page n'a pas de bulles à survoler : le clic droit est le
                // seul endroit où retirer un paragraphe sans quitter le Focus.
                .contentShape(Rectangle())
                .contextMenu { paragraphMenu(for: message) }
              }
            }
            .opacity(isWriting ? 0.34 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isWriting)
            .frame(maxWidth: .infinity, alignment: .leading)
          }

          ForEach(store.scheduledMessages(for: conversationID ?? "")) { scheduled in
            ScheduledMessageRow(message: scheduled, theme: theme, typeface: themes.typeface, isProse: true)
              .font(pageFont)
              .padding(.top, Spacing.sm)
              .opacity(isWriting ? 0.34 : 1)
          }

          if let config = store.sendLaterConfig, isPrimary {
            SendLaterBanner(config: config, theme: theme, typeface: themes.typeface)
              .padding(.top, Spacing.sm)
          }

          if includesEditor, let live {
            FocusPageEditor(session: live, theme: theme)
              .id("draft")
              .popover(
                isPresented: Binding(
                  get: { store.sendLaterPicker != nil && isPrimary },
                  set: { if !$0 { store.sendLaterPicker = nil } }
                ),
                arrowEdge: .top
              ) {
                SendLaterPicker()
              }
          } else {
            // Sans composer dans le fil, il faut tout de même une ancre en bas.
            Color.clear
              .frame(height: 1)
              .id("draft")
          }
        }
        // La grande marge basse fait respirer l'éditeur QUAND il vit dans le
        // fil ; posé dessous (fenêtre détachée, réponse rapide), elle ne
        // laisserait qu'un grand vide entre le dernier message et lui.
        .padding(.bottom, includesEditor ? metrics.bottom : Spacing.sm)
      }
      .defaultScrollAnchor(.bottom)
      .scrollIndicators(.never)
      // Remonter le fil rappelle la barre d'outils, comme un geste de retour
      // en arrière ; descendre la laisse dormir.
      .overlay(alignment: .top) {
        // Même soin qu'en Inbox : le fil se dissout sous le titre de la page
        // au lieu d'y être tranché.
        TopScrollFade(theme: theme, height: Spacing.lg, reachesWindowEdge: false)
      }
      .onScrollUp {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) {
          store.flashFocusChrome()
        }
      }
      .opacity(isShowingThread ? 1 : 0)
      .overlay {
        MacOverlayScrollerHider()
          .allowsHitTesting(false)
      }
      // Une réaction, une citation, un aperçu qui arrive après coup : la page
      // grandit sans que son compte bouge, et le bas doit tenir quand même.
      // L'ancre est le brouillon ; sous lui, la marge basse de la page fait
      // partie du « bas ».
      .keepScrolledToBottom(
        threshold: (includesEditor ? metrics.bottom : Spacing.sm) + 24,
        isNearBottom: $isNearBottom
      ) { keepBottom(proxy) }
      .onAppear { pinToBottom(proxy) }
      .task {
        guard awaitsFirstFrame else { return }
        await LaunchGate.firstWindowOnScreen()
        awaitsFirstFrame = false
        pinToBottom(proxy)
      }
      .onChange(of: thread.count) { oldCount, newCount in
        // « Répondre… » est l'ancre : on la recale sans animer, le geste se
        // joue dans le paragraphe. Animer ici ferait glisser le bas de la page.
        noteArrival(increased: newCount > oldCount)
        pinToBottom(proxy)
      }
      // Redimensionner une fenêtre détachée ne doit pas renvoyer le fil à son
      // début : le bas de la page est ce qu'on lit.
      .onChange(of: metrics) { _, _ in
        proxy.scrollTo("draft", anchor: .bottom)
      }
      .onChange(of: conversationID) { _, _ in
        isShowingThread = false
        animatesArrivals = false
        settledMessageID = thread.last?.id
        isNearBottom = true
        pinToBottom(proxy)
      }
      .alert(
        pendingDeletion?.scope.titleFR ?? "",
        isPresented: Binding(
          get: { pendingDeletion != nil },
          set: { if !$0 { pendingDeletion = nil } }
        ),
        presenting: pendingDeletion
      ) { deletion in
        Button("Supprimer", role: .destructive) {
          switch deletion.scope {
          case .locally:
            store.deleteLocally(messageID: deletion.messageID)
          case .everywhere:
            Task { await store.deleteEverywhere(messageID: deletion.messageID) }
          }
        }
        Button("Annuler", role: .cancel) {}
      } message: { deletion in
        Text(deletion.scope.detailFR)
      }
    }
  }

  /// Clic droit sur un paragraphe : copier, et les deux suppressions — les mêmes
  /// qu'en Inbox, avec la même confirmation.
  @ViewBuilder
  private func paragraphMenu(for message: ChatMessage) -> some View {
    if !message.text.isEmpty {
      Button("Copier le texte") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
      }
      Divider()
    }
    if store.canDeleteEverywhere(message) {
      Button("Supprimer pour tout le monde…", role: .destructive) {
        pendingDeletion = PendingDeletion(messageID: message.id, scope: .everywhere)
      }
    }
    Button("Supprimer ici…", role: .destructive) {
      pendingDeletion = PendingDeletion(messageID: message.id, scope: .locally)
    }
  }

  /// Si on lisait le bas, on y reste — dans la même passe, sans animer : rien
  /// ne doit défiler à l'écran. Remonter d'un cran libère l'ancre.
  private func keepBottom(_ proxy: ScrollViewProxy) {
    guard isNearBottom else { return }
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) { proxy.scrollTo("draft", anchor: .bottom) }
  }

  private func pinToBottom(_ proxy: ScrollViewProxy) {
    proxy.scrollTo("draft", anchor: .bottom)
    DispatchQueue.main.async {
      proxy.scrollTo("draft", anchor: .bottom)
      // Tant que le fil n'est pas arrivé, rien n'est « posé » ni à montrer.
      guard !awaitsFirstFrame else { return }
      isShowingThread = true
      // Ce qui est à l'écran à l'ouverture est déjà posé.
      settledMessageID = thread.last?.id
      animatesArrivals = true
    }
  }

  /// Le corps effectif de la page — échelle comprise. L'interligne s'y accroche.
  private var pageBodySize: CGFloat { theme.bodySize * themes.textScale }

  private var pageFont: Font {
    Typography.letterBody(themes.typeface, size: pageBodySize)
  }

  private var isGroup: Bool { row?.isGroup == true }

  /// Vrai quand cette page est celle de l'inbox : les états partagés (envoyer
  /// plus tard, recherche dans le fil) ne valent que pour elle.
  private var isPrimary: Bool { live != nil && live === store.primarySession }

  private var messageGroups: [MessageGroup] {
    MessageGrouping.groups(
      for: thread,
      showsSenderNames: isGroup,
      showsNetworkOrigin: isMergedThread
    )
  }

  private var isMergedThread: Bool {
    guard let id = conversationID else { return false }
    return store.isMerged(id)
  }

  /// En groupe, chaque prise de parole s'annonce une fois ; en tête-à-tête, la
  /// page se lit comme une lettre — l'encre plus pâle dit déjà que c'est moi.
  private func focusLabel(for group: MessageGroup) -> String? {
    guard isGroup else { return nil }
    return group.isFromMe ? "Toi" : group.senderLabel
  }
}

/// Au repos / à la pause : photo + envoyer. Pendant la frappe : une feuille.
struct FocusPageEditor: View {
  /// Le brouillon écrit ici est celui de CETTE session — l'inbox et une fenêtre
  /// détachée n'écrivent jamais dans la même page.
  var session: ConversationSession
  var theme: WritingTheme
  /// Appelé quand le message est bel et bien parti — la réponse rapide s'en
  /// sert pour se refermer derrière lui.
  var onSent: (() -> Void)?

  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @FocusState private var isFocused: Bool
  @State private var isActivelyTyping = false
  @State private var idleTask: Task<Void, Never>?
  @State private var isTrayExpanded = false

  private var text: Binding<String> { Bindable(session).draftText }
  private var isSending: Bool { session.isSending }
  /// « Plus tard » n'est posé que sur le composer de l'inbox.
  private var isScheduling: Bool { store.sendLaterConfig != nil && isPrimary }

  private var canSend: Bool { session.canSend }

  private var isPrimary: Bool { session === store.primarySession }

  private func onAttach() { store.pickAttachments(into: session) }
  /// « Plus tard » appartient à l'inbox : hors d'elle, le tiroir ne le propose pas.
  private var onSendLater: (() -> Void)? {
    isPrimary ? { store.toggleSendLaterPicker() } : nil
  }
  private func onSend() {
    Task {
      await store.send(session: session)
      // Un envoi refusé remet le brouillon en place : on ne prévient que du départ.
      if !session.canSend { onSent?() }
    }
  }

  private var showsChrome: Bool { !isActivelyTyping }

  private var pageBodySize: CGFloat { theme.bodySize * themes.textScale }

  private var pageFont: Font {
    Typography.letterBody(themes.typeface, size: pageBodySize)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if !session.pendingAttachmentPaths.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 8) {
            ForEach(Array(session.pendingAttachmentPaths.enumerated()), id: \.offset) { index, path in
              ZStack(alignment: .topTrailing) {
                if let img = NSImage(contentsOfFile: path) {
                  Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                Button {
                  session.pendingAttachmentPaths.remove(at: index)
                } label: {
                  Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white, .black.opacity(0.55))
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
              }
            }
          }
        }
      }

      HStack(alignment: .top, spacing: 8) {
        TextField(showsChrome ? "Répondre…" : "", text: text, axis: .vertical)
          .textFieldStyle(.plain)
          .font(pageFont)
          // Même interligne que la prose qu'on relit juste au-dessus.
          .lineSpacing(theme.lineSpacing(forBodySize: pageBodySize))
          .foregroundStyle(theme.ink)
          .lineLimit(1...20)
          .focused($isFocused)
          .frame(maxWidth: .infinity, alignment: .leading)
          // Avant « Entrée = envoyer » et « Échap = quitter » : le menu « @ » a la main.
          .mentionMenu(text: text, session: session, theme: theme, font: pageFont)
          .onKeyPress(.return) {
            if NSEvent.modifierFlags.contains(.shift) { return .ignored }
            guard canSend, !isSending else { return .handled }
            endTyping()
            onSend()
            return .handled
          }
          .onKeyPress(.escape) {
            isFocused = false
            endTyping()
            return .handled
          }

        ComposerPlusTray(
          theme: theme,
          isScheduling: isScheduling,
          iconSize: 18,
          isExpanded: $isTrayExpanded,
          onAttach: onAttach,
          onSendLater: onSendLater
        )
        .opacity(showsChrome ? 1 : 0)
        .allowsHitTesting(showsChrome)

        sendButton
          .opacity(showsChrome ? 1 : 0)
          .allowsHitTesting(showsChrome)
      }
    }
    .padding(.top, 8)
    .overlay(alignment: .top) {
      Rectangle()
        .fill(theme.edge.opacity(0.55))
        .frame(height: 1)
        .opacity(showsChrome ? 1 : 0)
    }
    .onChange(of: session.draftText) { _, newValue in
      if isTrayExpanded { isTrayExpanded = false }
      guard isFocused, !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return
      }
      noteTyping()
    }
    .onChange(of: isFocused) { _, focused in
      if !focused { endTyping() }
    }
    .onDisappear {
      idleTask?.cancel()
      store.isComposerFocused = false
    }
  }

  private var sendButton: some View {
    Button {
      endTyping()
      onSend()
    } label: {
      Image(systemName: isScheduling ? "clock.badge.checkmark" : "arrow.up")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(canSend ? theme.paper : theme.inkTertiary.opacity(0.45))
        .frame(width: 28, height: 28)
        .background(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(canSend ? theme.accent : theme.inkTertiary.opacity(0.12))
        )
    }
    .buttonStyle(.plain)
    .disabled(!canSend || isSending)
    .help(isScheduling ? "Programmer l’envoi" : "Envoyer")
    .accessibilityLabel(isScheduling ? "Programmer l’envoi" : "Envoyer")
  }

  private func noteTyping() {
    isActivelyTyping = true
    store.isComposerFocused = true
    idleTask?.cancel()
    idleTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 1_100_000_000)
      guard !Task.isCancelled else { return }
      isActivelyTyping = false
      store.isComposerFocused = false
    }
  }

  private func endTyping() {
    idleTask?.cancel()
    isActivelyTyping = false
    store.isComposerFocused = false
  }
}

private enum FocusAttachment {
  /// Ré-attache le fichier si le chemin en cache est périmé. L'identifiant d'une
  /// pièce jointe bridgée est son MXC : le média déjà téléchargé se retrouve sous
  /// ce nom, sans redemander quoi que ce soit au serveur.
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

private func shouldShowFocusText(_ message: ChatMessage) -> Bool {
  let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return false }
  let hasVisibleImage = message.attachments.contains {
    let repaired = FocusAttachment.repaired($0)
    return repaired.isImage && repaired.resolvedFileURL != nil
  }
  if hasVisibleImage, trimmed == "📷 Photo" { return false }
  return true
}

/// SwiftUI pose souvent l’overlay *à côté* du NSScrollView, pas dedans.
/// On cherche frères + ancêtres, et on re-masque pendant le geste.
private struct MacOverlayScrollerHider: NSViewRepresentable {
  func makeNSView(context: Context) -> OverlayScrollerHiderView {
    OverlayScrollerHiderView()
  }

  func updateNSView(_ nsView: OverlayScrollerHiderView, context: Context) {
    nsView.hideNearbyScrollers()
  }
}

private final class OverlayScrollerHiderView: NSView {
  private var tokens: [NSObjectProtocol] = []

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    hideNearbyScrollers()
    startObserving()
  }

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    hideNearbyScrollers()
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    super.viewWillMove(toWindow: newWindow)
    if newWindow == nil { stopObserving() }
  }

  func hideNearbyScrollers() {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      var current: NSView? = self
      while let view = current {
        Self.mute(in: view)
        current = view.superview
      }
    }
  }

  private static func mute(in view: NSView) {
    if let scroll = view as? NSScrollView {
      mute(scroll)
    }
    if view is NSScroller {
      view.alphaValue = 0
      view.isHidden = true
    }
    for sub in view.subviews {
      if let scroll = sub as? NSScrollView {
        mute(scroll)
      }
      if sub is NSScroller {
        sub.alphaValue = 0
        sub.isHidden = true
      }
    }
  }

  private static func mute(_ scroll: NSScrollView) {
    scroll.scrollerStyle = .overlay
    scroll.autohidesScrollers = true
    for scroller in [scroll.verticalScroller, scroll.horizontalScroller].compactMap({ $0 }) {
      scroller.wantsLayer = true
      scroller.alphaValue = 0
      scroller.isHidden = true
      scroller.layer?.opacity = 0
      scroller.isEnabled = false
    }
  }

  private func startObserving() {
    stopObserving()
    let nc = NotificationCenter.default
    tokens.append(nc.addObserver(
      forName: NSScrollView.didLiveScrollNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.hideNearbyScrollers() }
    })
    tokens.append(nc.addObserver(
      forName: NSView.boundsDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] note in
      guard note.object is NSClipView else { return }
      Task { @MainActor in self?.hideNearbyScrollers() }
    })
  }

  private func stopObserving() {
    let nc = NotificationCenter.default
    tokens.forEach { nc.removeObserver($0) }
    tokens.removeAll()
  }
}
