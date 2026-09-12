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
///
/// Le fil s'ouvre sur le PREMIER MESSAGE NON LU, pas sur le dernier : c'est le
/// choix de Signal, et la seule ouverture qui ne demande pas de remonter pour
/// lire ce qu'on vient justement ouvrir. Le chevron en bas à droite porte alors
/// le compte de ce qui attend dessous, et y mène d'un appui. Le défilement
/// lui-même est du UIKit : voir `ThreadList`.
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
  /// Ce que la liste dit d'elle-même : où l'on en est, ce qui attend dessous.
  @State private var listState = ThreadListState()
  /// La poignée du fil : c'est par elle qu'on lui demande d'aller quelque part.
  @State private var list = ThreadListProxy()
  /// La bulle vers laquelle on vient de sauter depuis une citation — surlignée un instant.
  @State private var flashedMessageID: String?
  /// L'instant où le fil s'est ouvert : ce qui était là avant est déjà posé,
  /// ce qui arrive après prend l'encre — mes propres envois compris.
  @State private var openedAt = Date()
  /// Le dernier message dont l'encre a fini de prendre : le défilement peut
  /// refaire naître sa rangée, elle ne se retracera pas.
  @State private var settledMessageID: String?
  /// Ce qui a déjà pris l'encre, par empreinte : la bulle optimiste et la
  /// copie du Relais qui la remplace ne jouent qu'une fois.
  private let inkLedger = MessageArrivalLedger()
  /// Ce qui n'était pas lu à l'ouverture, gelé par le store avant que l'accusé
  /// de lecture ne l'efface. C'est lui qui pose la barre et ouvre le fil.
  @State private var unreadOnOpen = 0
  /// Où le fil doit se poser — `nil` tant qu'on ne le sait pas encore.
  ///
  /// Le compte des non-lus se relève à l'ouverture, et la liste peut avoir
  /// déjà des rangées à montrer avant : sans ce « je ne sais pas », elle se
  /// posait en bas par défaut, et la barre arrivait trop tard pour servir.
  @State private var opening: ThreadListOpening?
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
      .toolbar(hidesTabBar ? .hidden : .automatic, for: .tabBar)
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
        inkLedger.reset()
        // Avant le moindre `await` : passé lui, un accusé de lecture a pu
        // partir et le compte ne vaut plus rien.
        store.noteUnreadOnOpen(conversationID)
        unreadOnOpen = store.unreadCountOnOpen(conversationID)
        opening = unreadOnOpen > 0 ? .unreadMark : .bottom
        await store.open(conversationID: conversationID)
      }
      .task(id: conversationID) { members = await store.members(conversationID) }
      .onDisappear {
        // La barre s'oublie en quittant : y revenir ne doit pas ressusciter
        // des non-lus d'il y a une heure.
        store.forgetUnreadMark(conversationID)
      }
      // Mon envoi : la hauteur qu'il ajoute se rattrape en glissant, pas d'un
      // bloc. C'est le seul moment où le fil doit se voir bouger.
      .onChange(of: store.lastSent) { _, sent in
        guard sent?.conversationID == conversationID else { return }
        list.expectOwnSend()
      }
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
    ThreadList(
      rows: rows,
      styleToken: styleToken,
      // Le fil s'ouvre sur ce qui attend, pas sur ce qu'on a déjà lu.
      opensOn: opening,
      // Un saut de file : la liste renvoie son état PENDANT que SwiftUI se
      // met à jour, et y écrire tout de suite serait modifier l'état d'une
      // vue en cours de dessin.
      onStateChange: { new in Task { @MainActor in listState = new } },
      onReachTop: { Task { await loadOlder() } },
      proxy: list,
      content: { row($0) }
    )
    // Un fil par conversation : changer de fil dans la colonne de détail doit
    // redonner une liste neuve, pas celle du précédent posée à sa place.
    .id(conversationID)
    // Le chevron au-dessus du bouton d'envoi : il n'apparaît que lorsqu'on a
    // quitté le bas du fil, porte le compte de ce qui attend dessous, et un
    // appui y mène.
    .overlay(alignment: .bottomTrailing) {
      // Pas pendant qu'on parle : le guide du verrou monte à cet endroit-là.
      if !listState.isNearBottom, !store.recorder.isRecording, !store.isHoldingMic {
        ScrollToBottomButton(unreadCount: listState.unreadBelow, theme: theme) {
          list.scrollToBottom()
        }
        .padding(.trailing, Spacing.sm)
        .padding(.bottom, 10)
        .transition(.opacity)
      }
    }
    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: listState.isNearBottom)
  }

  // MARK: - Les rangées

  /// Le fil mis à plat. Les drapeaux qui viennent du store — « Annuler »
  /// encore possible, bulle surlignée — entrent DANS la rangée : c'est leur
  /// changement qui fait se refaire la cellule, la liste ne relit pas le store.
  private var rows: [ThreadRow] {
    var built = ThreadRows.rows(
      groups: groups,
      messages: messages,
      unreadCount: unreadOnOpen,
      isLoadingOlder: store.isLoadingOlder,
      foldedAwayCount: foldedAwayCount,
      typingLabel: store.typingLabel(conversationID),
      receiptLabel: readReceiptLabel
    )
    let lastID = messages.last?.id
    for index in built.indices {
      guard case .bubble(var bubble) = built[index].kind else { continue }
      // Le dernier message a son « Annuler » sur la ligne de l'accusé ; seul
      // un envoi en sursis qui n'est plus le dernier garde le sien sous lui.
      bubble.canCancelPending =
        store.canUndoSend(bubble.message.id) && lastID != bubble.message.id
      bubble.isFlashed = flashedMessageID == bubble.message.id
      built[index].kind = .bubble(bubble)
    }
    return built
  }

  /// Ce qui change l'aspect de toutes les rangées à la fois. La liste ne
  /// redessine une cellule posée que là-dessus, ou sur un changement de rangée.
  private var styleToken: Int {
    var hasher = Hasher()
    hasher.combine(themes.themeID)
    hasher.combine(themes.typeface)
    hasher.combine(theme.isDark)
    hasher.combine(members.map(\.name))
    hasher.combine(reduceMotion)
    return hasher.finalize()
  }

  @ViewBuilder
  private func row(_ row: ThreadRow) -> some View {
    Group {
      switch row.kind {
      case .loadingOlder:
        ProgressView()
          .frame(maxWidth: .infinity)
          .padding(.vertical, 6)
      case .foldedHeader(let hidden):
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
        .padding(.top, 4)
      case .timeSeparator(let date, let network):
        timeSeparator(date, network: network)
      case .unreadMark(let count):
        unreadMark(count)
      case .systemEvent(let text):
        systemEvent(text)
      case .bubble(let bubble):
        bubbleRow(bubble)
      case .typing(let name):
        TypingBubble(
          name: conversation?.isGroup == true ? name : nil,
          accessibilityLabel: name ?? "",
          theme: theme,
          typeface: typeface,
          cornerRadius: 18
        )
        .padding(.leading, 6)
        .padding(.top, 10)
      case .receipt(let label):
        // « Annuler » vit sur CETTE ligne, pas sous la bulle : la ligne est là
        // de « Envoi… » à « Vu », à hauteur constante — un bouton qui prenait
        // une ligne sous la bulle puis s'en allait faisait sauter tout le fil.
        HStack(spacing: 3) {
          if let last = messages.last, store.canUndoSend(last.id) {
            Button("Annuler") { store.undoSend(last.id) }
              .buttonStyle(.plain)
              .font(Typography.meta(typeface))
              .foregroundStyle(theme.accent)
              .accessibilityLabel("Annuler l'envoi de ce message")
            Text("·").font(Typography.meta(typeface)).padding(.horizontal, 2)
          }
          Text(label)
            .font(Typography.meta(typeface))
        }
        .foregroundStyle(theme.inkTertiary)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 6)
        .padding(.top, 3)
        .padding(.bottom, 8)
        .accessibilityLabel("Dernier message \(label)")
      }
    }
    .padding(.horizontal, Spacing.sm)
    // Les cellules n'héritent pas de l'environnement de la vue qui les
    // héberge : `UIHostingConfiguration` repart d'une racine neuve. Ce que les
    // bulles y lisent se redonne donc ici.
    .environment(store)
    .environment(themes)
    .environment(\.mentionNames, MentionHighlight.withAgents(members.map(\.name)))
  }

  /// Une bulle, avec la photo de l'auteur quand elle termine une prise de
  /// parole reçue — sur son bord bas, comme sur le Mac. Les autres bulles du
  /// groupe gardent la colonne vide, pour rester alignées.
  private func bubbleRow(_ bubble: ThreadRow.Bubble) -> some View {
    let message = bubble.message
    return HStack(alignment: .bottom, spacing: 8) {
      if !bubble.isFromMe {
        if let source = bubble.avatarSource {
          MessageAvatarView(message: source, conversation: conversation, size: 26, theme: theme)
        } else {
          Color.clear.frame(width: 26, height: 1)
        }
      }
      MessageBubble(
        message: message,
        theme: theme,
        typeface: typeface,
        senderLabel: bubble.senderLabel,
        position: bubble.position,
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
            focused = FocusedMessage(message: message, senderLabel: bubble.groupSenderLabel)
          }
        },
        onQuoteTap: message.replyTo?.messageID.map { targetID in
          { jumpTo(targetID) }
        },
        onCancelPending: bubble.canCancelPending ? { store.undoSend(message.id) } : nil,
        onSendProposal: {
          Task { await store.sendAgentProposal(message, conversationID: conversationID) }
        },
        onEditProposal: { store.editAgentProposal(message, conversationID: conversationID) },
        onIgnoreProposal: { store.ignoreAgentProposal(message, conversationID: conversationID) }
      )
      .messageArrival(.encre, isFresh: isFresh(message), isEnabled: !reduceMotion)
      // Le surlignage d'arrivée après un saut de citation : toute la rangée
      // s'éclaire puis s'éteint, le temps que l'œil trouve.
      .background(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(theme.accent.opacity(bubble.isFlashed ? 0.14 : 0))
          .padding(-3)
      )
    }
    .frame(maxWidth: .infinity, alignment: bubble.isFromMe ? .trailing : .leading)
    // L'espace appartient à la rangée : serré dans une prise de parole,
    // desserré entre deux. C'est ce que faisait l'imbrication des piles.
    .padding(.top, bubble.position == .first || bubble.position == .alone ? 10 : 3)
  }

  /// La barre des non-lus : « 3 messages non lus », en travers du fil, là où
  /// la lecture s'était arrêtée. Signal la pose exactement ainsi.
  private func unreadMark(_ count: Int) -> some View {
    HStack(spacing: 8) {
      Rectangle().fill(theme.accent.opacity(0.35)).frame(height: 1)
      Text(count == 1 ? "1 message non lu" : "\(count) messages non lus")
        .font(Typography.meta(typeface))
        .fontWeight(.medium)
        .foregroundStyle(theme.accent)
        .layoutPriority(1)
      Rectangle().fill(theme.accent.opacity(0.35)).frame(height: 1)
    }
    .padding(.top, 14)
    .padding(.bottom, 4)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(count == 1 ? "1 message non lu" : "\(count) messages non lus")
  }

  /// L'encre ne prend que sur une VRAIE arrivée : le dernier message, posté
  /// après l'ouverture du fil, et pas depuis assez longtemps pour être déjà vu.
  /// Ce qu'on trouve en ouvrant une conversation paraît sans cérémonie.
  private func isFresh(_ message: ChatMessage) -> Bool {
    guard message.id == messages.last?.id,
          message.id != settledMessageID,
          message.sentAt > openedAt,
          MessageArrivalPolicy.isNewArrival(sentAt: message.sentAt),
          // Mon envoi a joué en bulle optimiste : sa copie du Relais, sous un
          // autre identifiant, paraît posée au lieu de se ré-encrer.
          !inkLedger.hasInked(message)
    else { return false }
    inkLedger.remember(message)
    return true
  }

  /// Une page de plus au-dessus. La liste tient sa rangée du haut pendant la
  /// remise en page : la lecture ne bouge pas d'un pouce, sans rien à recaler
  /// ici (cf. `ThreadList.restore`).
  private func loadOlder() async {
    guard !store.isLoadingOlder, !isFolded, messages.first != nil else { return }
    await store.loadOlder(conversationID: conversationID)
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
    // Le fil vient de s'ouvrir : il se pose d'abord. On saute après.
    try? await Task.sleep(for: .milliseconds(350))
    guard store.pendingJumpMessageID == messageID else { return }
    store.pendingJumpMessageID = nil
    jumpTo(messageID)
  }

  /// Le saut vers un message cité : on y va, on le surligne, l'éclat s'éteint.
  private func jumpTo(_ messageID: String) {
    guard messages.contains(where: { $0.id == messageID }) else { return }
    list.jump(to: messageID)
    withAnimation(.easeOut(duration: 0.2)) { flashedMessageID = messageID }
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(1.2))
      guard flashedMessageID == messageID else { return }
      withAnimation(.easeOut(duration: 0.5)) { flashedMessageID = nil }
    }
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
