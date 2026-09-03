import CorrespondanceCore
import CorrespondanceUI
import SwiftUI
import UIKit

/// Le fil d'une conversation.
///
/// La pilule de verre (photo + nom) au centre de la barre, entre le retour et
/// le menu ; elle ouvre la fiche du fil. Messages regroupés par
/// `MessageGrouping` comme sur le Mac — un nom par prise de parole, une heure
/// par silence de cinq minutes — et le composer en bas. L'accusé de lecture
/// part à l'ouverture, comme sur le Mac.
struct ThreadView: View {
  let conversationID: String
  /// En Focus, le fil se passe de son en-tête : la barre de Focus le porte déjà.
  var showsHeader = true
  /// Focus « Trier » lit sans répondre : pas de composer.
  var showsComposer = true
  /// Replié à ce qui attend une réponse : les messages reçus depuis mon dernier
  /// mot. L'historique reste à un tap, en tête. C'est ce que Focus enlève sur
  /// iPhone, là où le Mac enlève la barre latérale.
  var foldsToPending = false
  /// Ce que Focus pose entre le fil et le composer : sa rangée de décisions.
  var accessory: AnyView?

  /// L'historique déplié — le tap sur « … messages plus tôt ».
  @State private var isUnfolded = false

  @Environment(RelayStore.self) private var store
  @Environment(ThemePreferences.self) private var themes

  @State private var isShowingInfo = false
  /// La bulle sous appui long, et le nom qu'elle portait dans le fil.
  @State private var focused: FocusedMessage?
  /// Le texte d'une bulle ouvert pour en sélectionner quelques mots.
  @State private var selectingText: SelectedText?
  /// Vrai tant que le bas du fil est à l'écran : le chevron n'a alors rien à faire.
  @State private var isNearBottom = true
  /// La position pilotable du fil, pour compenser le clavier qui pousse par le bas.
  @State private var scrollPosition = ScrollPosition()
  /// Le dernier relevé de géométrie : de quoi calculer le bas du fil en points.
  /// `scrollTo(edge: .bottom)` ne bouge pas avec une pile paresseuse — on vise
  /// un décalage concret à la place.
  @State private var metrics = ScrollMetrics()
  /// La bulle vers laquelle on vient de sauter depuis une citation — surlignée un instant.
  @State private var flashedMessageID: String?
  /// L'instant où le fil s'est ouvert : ce qui était là avant est déjà posé,
  /// ce qui arrive après prend l'encre — mes propres envois compris.
  @State private var openedAt = Date()
  /// Le dernier message dont l'encre a fini de prendre : le défilement peut
  /// refaire naître sa rangée, elle ne se retracera pas.
  @State private var settledMessageID: String?
  /// Ce qui est arrivé pendant qu'on lisait plus haut.
  @State private var missedCount = 0
  /// Les gens du fil, relus à son ouverture : le champ en fait le menu « @ »,
  /// les bulles y reconnaissent les « @Nom » posés.
  @State private var members: [RelayStore.ThreadMember] = []

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.horizontalSizeClass) private var sizeClass

  private var theme: WritingTheme { themes.theme }
  private var typeface: WritingTypeface { themes.typeface }

  private var conversation: Conversation? { store.conversation(conversationID) }

  private struct FocusedMessage: Equatable {
    var message: ChatMessage
    var senderLabel: String?
  }

  struct SelectedText: Identifiable {
    let text: String
    var id: String { text }
  }

  /// Le clavier est levé : le composer se pose dessus, sans la marge de
  /// l'indicateur d'accueil sous lui.
  @State private var isKeyboardUp = false

  /// En compact, le fil prend l'écran et la barre d'onglets s'efface.
  private var hidesTabBar: Bool { showsHeader && sizeClass == .compact }

  var body: some View {
    thread
      .background(theme.paper.ignoresSafeArea())
      .safeAreaInset(edge: .bottom, spacing: 0) {
        VStack(spacing: 0) {
          if let accessory { accessory }
          if showsComposer {
            ThreadComposer(conversationID: conversationID, members: members)
          }
        }
        // Le fil ignore la zone sûre du bas (voir plus bas) : c'est donc au
        // composer de garder la marge de l'indicateur d'accueil — sauf sur
        // le clavier, qui la remplace.
        .padding(.bottom, hidesTabBar && !isKeyboardUp ? Self.homeIndicatorInset : 0)
      }
      // La barre d'onglets s'efface AVEC la poussée : le temps de la
      // transition, l'encart du bas passait de 140 à 91 points, et la pile
      // paresseuse ré-estimait tout le fil à cet instant — sur un groupe de
      // 130 messages, la hauteur sautait de 14 000 à 20 000 points, le
      // décalage suivait vers des rangées pas encore posées, et l'écran
      // restait vide une seconde. Le fil ne regarde donc plus la zone sûre du
      // bas : barre ou pas, son encart ne bouge pas.
      .ignoresSafeArea(.container, edges: hidesTabBar ? .bottom : [])
      .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
        isKeyboardUp = true
      }
      .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
        isKeyboardUp = false
      }
      .overlay {
        if let focused {
          MessageActionsOverlay(
            message: focused.message,
            conversationID: conversationID,
            senderLabel: focused.senderLabel,
            onSelectText: { selectingText = SelectedText(text: $0) }
          ) {
            self.focused = nil
          }
          .transition(.opacity)
        }
      }
      .sensoryFeedback(.impact(weight: .medium), trigger: focused != nil) { _, new in new }
      // Le nom du fil est dans la pilule : la barre n'a pas de titre à elle.
      .navigationTitle("")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { toolbar }
      .toolbar(focused == nil ? .visible : .hidden, for: .navigationBar)
      // Un fil ouvert en compact prend tout l'écran : la barre d'onglets
      // s'efface, sinon elle recouvre le composer. En regular, elle vit en
      // haut, à côté de la liste — elle reste.
      .toolbar(showsHeader && sizeClass == .compact ? .hidden : .automatic, for: .tabBar)
      .toolbarBackground(.hidden, for: .navigationBar)
      .sheet(item: $selectingText) { selected in
        SelectTextSheet(text: selected.text)
          .environment(themes)
      }
      .sheet(isPresented: $isShowingInfo) {
        ThreadInfoSheet(conversationID: conversationID)
          .environment(store)
          .environment(themes)
      }
      .sheet(isPresented: Binding(
        get: { store.forwardingMessage != nil },
        set: { if !$0 { store.cancelForwarding() } }
      )) {
        if let message = store.forwardingMessage {
          ForwardSheet(message: message)
            .environment(store)
            .environment(themes)
        }
      }
      .task(id: conversationID) {
        openedAt = Date()
        await store.open(conversationID: conversationID)
      }
      .task(id: conversationID) { members = await store.members(conversationID) }
      // Les gens du fil descendent jusqu'aux bulles : c'est ce qui fait d'un
      // « @Nom » une mention plutôt qu'un mot comme les autres.
      .environment(\.mentionNames, MentionHighlight.withAgents(members.map(\.name)))
      .task(id: store.pendingJumpMessageID) {
        guard let target = store.pendingJumpMessageID else { return }
        await consumeJump(target)
      }
  }

  @ToolbarContentBuilder
  private var toolbar: some ToolbarContent {
    if showsHeader, let conversation {
      ToolbarItem(placement: .principal) {
        Button {
          isShowingInfo = true
        } label: {
          ThreadPillHeader(conversation: conversation, theme: theme, typeface: typeface)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Ouvre la fiche de la conversation")
      }
    }
    ToolbarItem(placement: .topBarTrailing) {
      Menu {
        Button {
          store.toggleArchived(conversationID)
        } label: {
          Label(
            store.isArchived(conversationID) ? "Désarchiver" : "Archiver",
            systemImage: store.isArchived(conversationID) ? "tray.and.arrow.up" : "archivebox"
          )
        }
        Button {
          store.togglePinned(conversationID)
        } label: {
          Label(
            store.isPinned(conversationID) ? "Désépingler" : "Épingler",
            systemImage: store.isPinned(conversationID) ? "pin.slash" : "pin"
          )
        }
        Button {
          store.toggleMuted(conversationID)
        } label: {
          Label(
            store.isMuted(conversationID) ? "Réactiver les notifications" : "Mettre en muet",
            systemImage: store.isMuted(conversationID) ? "bell" : "bell.slash"
          )
        }
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .accessibilityLabel("Actions de la conversation")
    }
  }

  // MARK: - Le fil

  private var thread: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 10) {
        if store.isLoadingOlder {
          ProgressView()
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        Color.clear.frame(height: 4)

        if let hidden = foldedAwayCount, hidden > 0 {
          Button {
            withAnimation(.easeOut(duration: 0.2)) { isUnfolded = true }
          } label: {
            Label("\(hidden) messages plus tôt", systemImage: "chevron.down")
              .font(Typography.meta(typeface))
              .foregroundStyle(theme.inkSecondary)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 7)
              .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                  .fill(theme.paperSecondary.opacity(0.7))
              )
          }
          .buttonStyle(.plain)
          .accessibilityHint("Déplie l'historique de la conversation")
        }

        ForEach(groups) { group in
          if let separator = group.timeSeparator {
            timeSeparator(separator, network: group.networkOrigin)
          }
          // La photo de l'auteur dans la marge d'une prise de parole reçue,
          // comme sur le Mac : sur le bord bas de la dernière bulle, pas sous
          // ce qui la suit — cf. `VerticalAlignment.bubbleBottom`.
          HStack(alignment: .bubbleBottom, spacing: 8) {
            if !group.isFromMe, let first = group.messages.first, !first.isSystemEvent {
              MessageAvatarView(
                message: first,
                conversation: conversation,
                size: 26,
                theme: theme
              )
            }
            VStack(alignment: group.isFromMe ? .trailing : .leading, spacing: 3) {
              ForEach(Array(group.messages.enumerated()), id: \.element.id) { index, message in
                if let text = message.systemEventText {
                  systemEvent(text)
                } else {
                  MessageBubble(
                    message: message,
                    theme: theme,
                    typeface: typeface,
                    senderLabel: index == 0 ? group.senderLabel : nil,
                    position: BubblePosition(index: index, count: group.messages.count),
                    onReply: { store.setReplyTarget(message.id, conversationID: conversationID) },
                    onVotePoll: message.poll == nil ? nil : { (answerID: String) in
                      let fil = conversationID
                      let bulle = message.id
                      Task { @MainActor in
                        await store.votePoll(conversationID: fil, messageID: bulle, answerID: answerID)
                      }
                    },
                    onReact: { emoji in
                      Task { await store.react(conversationID: conversationID, messageID: message.id, emoji: emoji) }
                    },
                    onLongPress: message.isAgentProposal ? nil : {
                      withAnimation(.easeOut(duration: 0.18)) {
                        focused = FocusedMessage(message: message, senderLabel: group.senderLabel)
                      }
                    },
                    onQuoteTap: message.replyTo?.messageID.map { targetID in
                      { jumpTo(targetID) }
                    },
                    // Le dernier message a son « Annuler » sur la ligne de
                    // l'accusé ; seul un envoi en sursis qui n'est plus le
                    // dernier garde le sien sous lui.
                    onCancelPending: store.canUndoSend(message.id) && messages.last?.id != message.id
                      ? { store.undoSend(message.id) }
                      : nil,
                    onSendProposal: {
                      Task { await store.sendAgentProposal(message, conversationID: conversationID) }
                    },
                    onEditProposal: { store.editAgentProposal(message, conversationID: conversationID) },
                    onIgnoreProposal: { store.ignoreAgentProposal(message, conversationID: conversationID) }
                  )
                  .id(message.id)
                  .messageArrival(.encre, isFresh: isFresh(message), isEnabled: !reduceMotion)
                  // Le surlignage d'arrivée après un saut de citation : toute
                  // la rangée s'éclaire puis s'éteint, le temps que l'œil trouve.
                  .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                      .fill(theme.accent.opacity(flashedMessageID == message.id ? 0.14 : 0))
                      .padding(-3)
                  )
                }
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: group.isFromMe ? .trailing : .leading)
        }

        // Les trois points, au bas du fil, là où la bulle apparaîtra.
        if let typing = store.typingLabel(conversationID) {
          TypingBubble(
            name: conversation?.isGroup == true ? typing : nil,
            accessibilityLabel: typing,
            theme: theme,
            typeface: typeface,
            cornerRadius: 18
          )
          .padding(.leading, 6)
          .transition(.opacity)
        }

        // « Annuler » vit sur CETTE ligne, pas sous la bulle : la ligne est là
        // de « Envoi… » à « Vu », à hauteur constante — un bouton qui prenait
        // une ligne sous la bulle puis s'en allait faisait sauter tout le fil,
        // ancré en bas, à chaque changement d'état.
        if let receipt = readReceiptLabel {
          HStack(spacing: 3) {
            if let last = messages.last, store.canUndoSend(last.id) {
              Button("Annuler") { store.undoSend(last.id) }
                .buttonStyle(.plain)
                .font(Typography.meta(typeface))
                .foregroundStyle(theme.accent)
                .accessibilityLabel("Annuler l'envoi de ce message")
              Text("·").font(Typography.meta(typeface)).padding(.horizontal, 2)
            }
            Text(receipt)
              .font(Typography.meta(typeface))
          }
          .foregroundStyle(theme.inkTertiary)
          .frame(maxWidth: .infinity, alignment: .trailing)
          .padding(.trailing, 6)
          .animation(nil, value: receipt)
          .accessibilityLabel("Dernier message \(receipt)")
        }

        Color.clear.frame(height: 8)
      }
      .padding(.horizontal, Spacing.sm)
    }
    .scrollDismissesKeyboard(.interactively)
    .defaultScrollAnchor(.bottom, for: .initialOffset)
    // Le bas reste le bas quand le contenu change de taille. Sans ça, la pile
    // paresseuse ouvrait le fil sur du vide dès la vingtaine de messages : elle
    // ESTIME les rangées qu'elle n'a pas mesurées, le fil se posait au bas de
    // cette estimation, puis la hauteur réelle — plus courte — laissait le
    // décalage au-delà du dernier message. Plus rien à l'écran, donc plus rien
    // à mesurer, donc plus de correction : un balayage seul en sortait.
    // Seulement quand on lit le bas : plus haut, une arrivée ne doit pas tirer.
    .defaultScrollAnchor(isNearBottom ? .bottom : nil, for: .sizeChanges)
    .scrollPosition($scrollPosition)
    // Quand le bas se rétrécit — clavier qui s'ouvre, citation ou pièces
    // jointes qui coiffent le champ — le fil remonte d'autant : ce qu'on
    // lisait reste sous les yeux au lieu de passer sous le composer.
    // (Près du bas, c'est l'autre chemin : on recolle à l'ancre.)
    .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
      ScrollMetrics(
        offsetY: geometry.contentOffset.y,
        insetTop: geometry.contentInsets.top,
        insetBottom: geometry.contentInsets.bottom,
        contentHeight: geometry.contentSize.height,
        visibleHeight: geometry.visibleRect.height,
        visibleMaxY: geometry.visibleRect.maxY
      )
    } action: { old, new in
      metrics = new
      let delta = new.insetBottom - old.insetBottom
      if delta > 0, !isNearBottom {
        scrollPosition.scrollTo(y: new.offsetY + delta + new.insetTop)
      }
      // Et quand le bas se libère — citation retirée, clavier rangé — le
      // décalage, lui, ne bouge pas : le fil reste garé SOUS son propre bas,
      // du vide entre le dernier message et le composer, jusqu'à ce qu'un
      // doigt le fasse rebondir. On le recolle nous-mêmes, sans animation :
      // la pilule qui se replie fait déjà le mouvement.
      if delta < 0, new.distanceToBottom < -1 {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { scrollPosition.scrollTo(y: new.bottomScrollTarget) }
      }
      let nearBottom = !new.isScrollable || new.distanceToBottom <= 60
      if nearBottom != isNearBottom {
        if nearBottom { missedCount = 0 }
        withAnimation(.easeOut(duration: 0.2)) { isNearBottom = nearBottom }
      }
      // Remonter jusqu'en haut, c'est demander la suite : le Relais complète
      // au-dessus et la lecture ne bouge pas d'un pouce.
      if new.isScrollable, new.distanceToTop <= 400, !isFolded { Task { await loadOlder() } }
    }
    // Le chevron au-dessus du bouton d'envoi : il n'apparaît que lorsqu'on
    // a quitté le bas du fil, et un appui y ramène.
    .overlay(alignment: .bottomTrailing) {
      // Pas pendant qu'on parle : le guide du verrou monte à cet endroit-là.
      if !isNearBottom, !store.recorder.isRecording, !store.isHoldingMic {
        ScrollToBottomButton(unreadCount: missedCount, theme: theme) {
          scrollToBottom(duration: 0.3)
        }
        .padding(.trailing, Spacing.sm)
        .padding(.bottom, 10)
      }
    }
    // `initial: true` : à l'ouverture aussi. Le fil de démonstration a ses
    // messages avant d'être à l'écran — sans ce premier appel, personne ne
    // corrigeait le placement de l'ancre.
    .onChange(of: messages.last?.id, initial: true) { old, new in
      // Ce qui arrive alors qu'on lit plus haut se compte : la pilule ↓ le dit.
      if old != nil, old != new, !isNearBottom { missedCount += 1 }
      // L'encre a pris : passé le geste, la bulle est une bulle comme les autres.
      if let new {
        Task { @MainActor in
          try? await Task.sleep(for: .seconds(1.2))
          if messages.last?.id == new { settledMessageID = new }
        }
      }
      // Ce qui arrive pendant qu'on relit plus haut ne nous ramène pas de
      // force en bas : la pilule ↓ le dit, et on y va quand on veut. Mes
      // propres envois, eux, se suivent toujours.
      guard isNearBottom || new == nil || messages.last?.isFromMe == true else { return }
      // Le fil qui s'ouvre ou se remplit : l'ancre initiale l'a déjà posé en
      // bas presque toujours. On vérifie sans bouger, et on ne recolle que si
      // c'est faux — d'un coup, sans animation. Avant, un trajet animé vers le
      // dernier message partait d'un bas déjà atteint, traversait le vide des
      // rangées estimées, puis revenait : les bulles paraissaient,
      // disparaissaient, reparaissaient à chaque ouverture.
      let isOpening = old == nil
      // Un souffle : la bulle qui vient d'arriver doit être mesurée avant
      // qu'on sache où est le nouveau bas.
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(80))
        if isOpening {
          guard abs(metrics.distanceToBottom) > 60 else { return }
          scrollToBottom(duration: 0)
        } else {
          scrollToBottom()
        }
      }
    }
    // Le clavier qui s'ouvre masque le bas du fil : si l'on y était, on y
    // reste — le dernier message vient se poser au-dessus du composer.
    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
      guard isNearBottom else { return }
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(80))
        scrollToBottom()
      }
    }
  }

  /// Ramène au dernier message, en visant le décalage réel du bas du fil.
  ///
  /// La pile paresseuse ESTIME la hauteur des rangées pas encore mesurées :
  /// la première visée peut atterrir court quand une grande bulle se
  /// matérialise en route. On recolle donc jusqu'à toucher le bas.
  private func scrollToBottom(duration: Double = 0.25) {
    // Durée nulle : un saut sec, sans transaction animée — une animation de
    // zéro seconde passe encore par une interpolation visible.
    var transaction = Transaction(animation: duration > 0 ? .easeOut(duration: duration) : nil)
    transaction.disablesAnimations = duration <= 0
    withTransaction(transaction) {
      // Viser LE DERNIER MESSAGE, pas un décalage en points : la pile
      // paresseuse ESTIME les rangées qu'elle n'a pas mesurées, et une bulle
      // qui se révèle plus petite que son estimation (une photo absente,
      // réduite à une ligne) laissait le fil garé SOUS son propre bas — écran
      // vide, et une hauteur de contenu périmée qui prétendait le contraire.
      // Viser un identifiant force la matérialisation de la rangée visée.
      if let last = messages.last?.id {
        scrollPosition.scrollTo(id: last, anchor: .bottom)
      } else {
        scrollPosition.scrollTo(y: metrics.bottomScrollTarget)
      }
    }
    Task { @MainActor in
      for _ in 0..<3 {
        try? await Task.sleep(for: .milliseconds(Int(duration * 1000) + 80))
        // Dans les DEUX sens : une rangée plus petite que son estimation — un
        // vocal, une photo absente — laissait le fil garé SOUS son propre bas,
        // écran vide, et la correction ne regardait que le manque.
        guard abs(metrics.distanceToBottom) > 60 else { return }
        var fix = Transaction(animation: duration > 0 ? .easeOut(duration: 0.15) : nil)
        fix.disablesAnimations = duration <= 0
        withTransaction(fix) { scrollPosition.scrollTo(y: metrics.bottomScrollTarget) }
      }
    }
  }

  /// L'encre ne prend que sur une VRAIE arrivée : le dernier message, posté
  /// après l'ouverture du fil, et pas depuis assez longtemps pour être déjà vu.
  /// Ce qu'on trouve en ouvrant une conversation paraît sans cérémonie.
  private func isFresh(_ message: ChatMessage) -> Bool {
    message.id == messages.last?.id
      && message.id != settledMessageID
      && message.sentAt > openedAt
      && MessageArrivalPolicy.isNewArrival(sentAt: message.sentAt)
  }

  /// Une page de plus au-dessus, sans perdre sa page : on vise l'ancien
  /// premier message par le haut, sans animation — comme le Mac le fait avec
  /// « Voir les messages précédents ».
  private func loadOlder() async {
    guard !store.isLoadingOlder, let anchor = messages.first?.id else { return }
    await store.loadOlder(conversationID: conversationID)
    guard messages.first?.id != anchor else { return }
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) { scrollPosition.scrollTo(id: anchor, anchor: .top) }
  }

  /// Un résultat de recherche vise un message : le fil s'y rend. S'il est hors
  /// de la fenêtre chargée, on va d'abord le chercher — comme le Mac élargit
  /// la sienne pour ⌘F.
  private func consumeJump(_ messageID: String) async {
    // La recherche part de la fiche du fil : elle se referme avec elle,
    // sinon on sauterait derrière une feuille.
    isShowingInfo = false
    if !messages.contains(where: { $0.id == messageID }) {
      await store.loadOlder(conversationID: conversationID)
    }
    // Le fil vient de s'ouvrir : il se pose d'abord en bas. On saute après.
    try? await Task.sleep(for: .milliseconds(350))
    guard store.pendingJumpMessageID == messageID else { return }
    store.pendingJumpMessageID = nil
    jumpTo(messageID)
  }

  /// Le saut vers un message cité : on y va, on le surligne, l'éclat s'éteint.
  private func jumpTo(_ messageID: String) {
    guard messages.contains(where: { $0.id == messageID }) else { return }
    withAnimation(.easeInOut(duration: 0.3)) { scrollPosition.scrollTo(id: messageID, anchor: .center) }
    withAnimation(.easeOut(duration: 0.2)) { flashedMessageID = messageID }
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(1.2))
      guard flashedMessageID == messageID else { return }
      withAnimation(.easeOut(duration: 0.5)) { flashedMessageID = nil }
    }
  }

  /// La marge de l'indicateur d'accueil, lue sur la fenêtre : elle ne compte
  /// que lui, jamais la barre d'onglets.
  private static var homeIndicatorInset: CGFloat {
    UIApplication.shared.connectedScenes
      .compactMap { ($0 as? UIWindowScene)?.keyWindow }
      .first?.safeAreaInsets.bottom ?? 0
  }

  /// Ce qu'on relève du défilement, via `visibleRect` — exprimé dans les
  /// coordonnées du contenu, donc sans décoder la composition des encarts.
  ///
  /// Calibré au simulateur (test d'interface du chevron) :
  /// - au repos en bas du fil, `visibleRect.maxY = contentHeight + insetBottom` ;
  /// - `scrollTo(y: X)` pose `contentOffset.y` à `X - insetTop` — sa cible se
  ///   donne donc dans un repère décalé de l'encart du haut.
  private struct ScrollMetrics: Equatable {
    var offsetY: CGFloat = 0
    var insetTop: CGFloat = 0
    var insetBottom: CGFloat = 0
    var contentHeight: CGFloat = 0
    var visibleHeight: CGFloat = 0
    var visibleMaxY: CGFloat = 0

    /// Ce qui reste à descendre. Zéro quand on est posé en bas.
    var distanceToBottom: CGFloat { contentHeight - visibleMaxY + insetBottom }
    /// Ce qui reste à remonter. Zéro quand on touche le premier message.
    var distanceToTop: CGFloat { visibleMaxY - visibleHeight }
    /// La cible `scrollTo(y:)` qui repose le dernier message sur le composer.
    var bottomScrollTarget: CGFloat { offsetY + distanceToBottom + insetTop }
    /// Un fil qui tient à l'écran n'a pas de bas où descendre.
    var isScrollable: Bool { contentHeight > visibleHeight - insetTop - insetBottom }
  }

  private var allMessages: [ChatMessage] { store.visibleMessages(conversationID) }
  private var isFolded: Bool { foldsToPending && !isUnfolded }

  /// Le fil tel qu'on le montre : entier, ou replié à ce qui suit mon dernier
  /// message. Sans mot de moi, tout le fil attend — on le garde entier.
  private var messages: [ChatMessage] {
    guard isFolded, let cut = allMessages.lastIndex(where: \.isFromMe) else { return allMessages }
    return Array(allMessages[cut...])
  }

  /// Ce que le pli cache. `nil` quand rien n'est plié.
  private var foldedAwayCount: Int? {
    guard isFolded else { return nil }
    return allMessages.count - messages.count
  }

  private var groups: [MessageGroup] { store.groups(conversationID, messages: messages) }

  /// « Vu » sous le dernier message sortant — quand le réseau l'expose.
  /// Signal et WhatsApp ne le donnent pas : on n'affiche alors rien plutôt
  /// qu'un état inventé.
  private var readReceiptLabel: String? {
    guard let last = messages.last, last.isFromMe else { return nil }
    // Un envoi en sursis n'a pas encore d'accusé : la ligne dit « Envoi… »
    // dès la bulle, pour ne pas apparaître après coup.
    let delivery = conversation?.lastDelivery
      ?? (last.isPending || store.canUndoSend(last.id) ? MessageDelivery.sending : .sent)
    // Dans un groupe, le détail des lecteurs remplace le « Vu » anonyme.
    if delivery == .read, let seenBy = store.seenByLabel(conversationID) { return seenBy }
    return delivery.labelFR
  }

  private func timeSeparator(_ date: Date, network: MessageNetwork?) -> some View {
    let time = date.formatted(
      Calendar.current.isDateInToday(date)
        ? Date.FormatStyle().hour().minute()
        : Date.FormatStyle().day().month(.abbreviated).hour().minute()
    )
    return Text(network.map { "\(time) · \($0.labelFR)" } ?? time)
      .font(Typography.meta(typeface))
      .foregroundStyle(theme.inkTertiary)
      .frame(maxWidth: .infinity, alignment: .center)
      .padding(.vertical, 8)
  }

  private func systemEvent(_ text: String) -> some View {
    Text(text)
      .font(Typography.meta(typeface))
      .foregroundStyle(theme.inkTertiary)
      .multilineTextAlignment(.center)
      .frame(maxWidth: .infinity, alignment: .center)
      .padding(.vertical, 6)
  }
}

/// La pilule au centre de la barre : la photo du fil (mosaïque des membres
/// pour un groupe, pastille du réseau) et son nom, dans une capsule de verre.
struct ThreadPillHeader: View {
  let conversation: Conversation
  let theme: WritingTheme
  var typeface: WritingTypeface = .quattro

  var body: some View {
    HStack(spacing: 7) {
      ConversationAvatar(conversation: conversation, size: 26, theme: theme)
      Text(conversation.title)
        .font(Typography.body(typeface, size: 15))
        .fontWeight(.medium)
        .foregroundStyle(theme.ink)
        .lineLimit(1)
        .frame(maxWidth: 180)
      // Ce que la conversation est vraiment, sans avoir à ouvrir la fiche.
      // iMessage est laissé de côté : il n'a pas de salon Matrix, et sa
      // confidentialité est celle d'Apple — nous n'en savons rien.
      if conversation.network != .iMessage {
        ConfidentialiteBadge(
          conversation.confidentialite,
          teinte: conversation.privacy.showsClosedLock ? theme.accent : theme.inkTertiary,
          taille: 10
        )
      }
    }
    .padding(.leading, 5)
    .padding(.trailing, 12)
    .padding(.vertical, 5)
    .glassSurface(cornerRadius: 18, fallbackFill: theme.sidebar, border: theme.edge, isInteractive: true)
    .contentShape(Capsule())
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(conversation.title), \(conversation.network.labelFR), \(conversation.confidentialite.libelleFR)")
  }
}
