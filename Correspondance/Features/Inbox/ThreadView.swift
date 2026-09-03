import AppKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers
import CorrespondanceCore
import CorrespondanceUI

struct ThreadView: View {
  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isShowingThread = false
  /// « Traduire ce que j'envoie » a retenu l'envoi : le panneau est ouvert.
  @State private var outgoingTranslation: OutgoingTranslationRequest?
  /// Faux tant que le fil se met en place : à l'ouverture d'une conversation,
  /// les vingt dernières bulles ne doivent pas prendre l'encre une par une.
  @State private var animatesArrivals = false
  /// Ce que le fil considère comme déjà posé. Tout ce qui arrive après se
  /// trace ; ce qui est là depuis toujours paraît sans cérémonie.
  @State private var settledMessageID: String?
  /// Au lancement, le fil attend que la fenêtre soit peinte : construire cent
  /// bulles avant la première frame, c'est le rebond de trop dans le Dock. Il
  /// est de toute façon invisible tant qu'il n'est pas ancré en bas — il
  /// arrive donc entier, un instant plus tard, sans saut.
  @State private var awaitsFirstFrame = !LaunchGate.didPaintFirstWindow
  /// Au lancement comme à chaque bascule de fil, le fil paraît par sa QUEUE :
  /// l'écran ne montre que les derniers messages, inutile d'en construire
  /// cent vingt — corps, mise en page, rendu — avant de le montrer. Le reste
  /// s'ajoute au-dessus, hors champ, une frame plus tard ; le bas tient
  /// (`keepScrolledToBottom`), rien ne bouge à l'écran. Mesuré : le fil
  /// paraît ~190 ms plus tôt au lancement, et 710 → 135 ms entre le clic et
  /// le fil à l'écran sur un fil de 199 messages. `nil` = entier.
  @State private var launchTail: Int? = LaunchGate.didPaintFirstWindow ? nil : ThreadMetrics.launchTailCount
  /// Combien de messages le fil MONTE — pas combien il en connaît. Un fil de
  /// groupe fleuve (quatre cents messages et plus) monté d'un bloc fait un
  /// arbre de calques que le compositeur recompose à chaque frame : l'app ne
  /// calcule rien, et le défilement rame quand même. On monte la fin, le
  /// reste attend derrière « Voir les messages précédents ».
  @State private var windowCount = ThreadMetrics.windowCount
  /// Le tiroir du « + » propose d'inviter les agents qui ne sont pas encore
  /// dans ce fil — un bouton s'il n'y en a qu'un, un menu s'il y en a
  /// plusieurs. Vide quand le fil n'est pas au Relais, ou qu'ils y sont tous.
  @State private var invitableAgents: [String] = []
  /// La voix de chaque agent présent dans ce fil : brouillon ou voix haute. Un
  /// bouton par agent, chacun réglant **sa** console.
  @State private var agentVoices: [AgentVoice] = []
  /// Le compte de messages pour lequel une expansion est programmée : si le
  /// fil a changé entre-temps (chargement arrivé après la queue), on laisse
  /// la passe suivante reprogrammer la sienne.
  @State private var pendingExpansionCount: Int?
  /// Vrai tant que le lecteur n'a pas remonté le fil : c'est ce qui décide si
  /// une hauteur qui change (réaction, citation, aperçu) le garde en bas.
  @State private var isNearBottom = true
  /// La bulle vers laquelle on vient de sauter depuis une citation — surlignée un instant.
  @State private var flashedMessageID: String?
  /// Ce qui est arrivé pendant qu'on lisait plus haut.
  @State private var missedCount = 0
  /// Un fichier survole le fil : la colonne se borde de pointillé.
  @State private var isDropTargeted = false
  /// Le moniteur d'Espace. Pas un raccourci de menu : Espace appartient
  /// d'abord au champ de saisie, et un équivalent-clavier sans modificateur
  /// le lui volerait dans toute l'app.
  @State private var quickLookMonitor: Any?

  private var theme: WritingTheme { themes.theme }
  private var thread: [ChatMessage] {
    if awaitsFirstFrame { return [] }
    let cap = launchTail.map { min($0, windowCount) } ?? windowCount
    // Une réponse proposée sans qu'on demande (`suggest`) ne vit pas dans le
    // fil : elle se rend en bandeau au-dessus de la saisie (`SuggestionBanner`).
    return Array(store.messages.suffix(cap)).filter { $0.agentProposal?.kind != .suggest }
  }

  /// Ce que la fenêtre laisse hors champ, au-dessus.
  private var hiddenOlderCount: Int {
    max(0, store.messages.count - thread.count)
  }

  private var forwardSheetPresented: Binding<Bool> {
    Binding(
      get: { store.forwardingMessage != nil },
      set: { if !$0 { store.cancelForwarding() } }
    )
  }

  private var sendLaterPickerPresented: Binding<Bool> {
    Binding(
      get: { store.sendLaterPicker != nil },
      set: { if !$0 { store.sendLaterPicker = nil } }
    )
  }

  var body: some View {
    Group {
      if store.selectedConversation != nil {
        VStack(spacing: 0) {
          if store.isThreadSearchActive {
            ThreadSearchBar(theme: theme, typeface: themes.typeface)
          }
          messages
          if let quoted = store.replyingToMessage {
            ReplyBanner(message: quoted, theme: theme, typeface: themes.typeface)
          }
          if let edited = store.editingMessage {
            EditBanner(message: edited, theme: theme, typeface: themes.typeface)
          }
          if let config = store.sendLaterConfig {
            SendLaterBanner(config: config, theme: theme, typeface: themes.typeface)
          }
          if #available(macOS 15, *), let request = outgoingTranslation {
            OutgoingTranslationPanel(request: request, theme: theme, typeface: themes.typeface) {
              outgoingTranslation = nil
            }
          }
          ComposerBar(
            text: Bindable(store).draftText,
            attachmentPaths: Bindable(store).pendingAttachmentPaths,
            isSending: store.isSending,
            isScheduling: store.sendLaterConfig != nil,
            theme: theme,
            onAttach: { store.pickAttachments() },
            onSendLater: { store.toggleSendLaterPicker() },
            invitableAgents: invitableAgents,
            onInviteAgent: { agent in
              invitableAgents.removeAll { $0 == agent }
              Task {
                await store.inviteAgent(agent)
                await rechargerLesAgents()
                // Plusieurs agents dans un salon en font un atelier : chacun
                // doit connaître les autres, sinon ils se répondent en boucle.
                await store.linkAgentPeersInSelectedConversation()
              }
            },
            agentVoices: agentVoices,
            onToggleAgentVoice: agentVoices.isEmpty ? nil : { agent in
              guard let courante = agentVoices.first(where: { $0.agent == agent })?.mode else { return }
              // Brouillon ⇄ voix haute ; « répond seul » ne se choisit que
              // dans la fiche du fil, avec un cadre — cliquer le bouton en sort.
              let suivante: AgentSettings.Mode = courante == .draft ? .direct : .draft
              Task {
                if let posee = await store.setAgentVoice(suivante, agent: agent) {
                  agentVoices = agentVoices.map {
                    $0.agent == agent ? AgentVoice(agent: agent, mode: posee) : $0
                  }
                }
              }
            },
            onManageGroup: store.selectedConversationID.flatMap { id in
              store.canManageGroup(id) ? { store.presentGroupSheet(id) } : nil
            },
            voiceConversationID: store.canRecordVoice(in: store.selectedConversationID)
              ? store.selectedConversationID
              : nil,
            onSend: {
              if #available(macOS 15, *) {
                OutgoingTranslationPanel.send(store: store, request: $outgoingTranslation)
              } else {
                Task { await store.sendDraft() }
              }
            }
          )
          .popover(isPresented: sendLaterPickerPresented, arrowEdge: .top) {
            SendLaterPicker()
          }
        }
        // Déposer un fichier n'importe où sur le fil vaut le joindre : c'est
        // toute la colonne qui accueille, pas un rectangle à viser.
        .dropDestination(for: URL.self) { urls, _ in
          store.attach(urls: urls)
          return true
        } isTargeted: { isDropTargeted = $0 }
        .onAppear(perform: watchQuickLook)
        .onDisappear {
          if let quickLookMonitor { NSEvent.removeMonitor(quickLookMonitor) }
          quickLookMonitor = nil
        }
        .overlay {
          if isDropTargeted {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
              .strokeBorder(theme.accent, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
              .padding(Spacing.xs)
              .allowsHitTesting(false)
          }
        }
        .sheet(isPresented: forwardSheetPresented) {
          if let message = store.forwardingMessage {
            ForwardSheet(message: message)
          }
        }
      } else {
        Text("Aucune conversation")
          .font(Typography.emptyState(themes.typeface))
          .foregroundStyle(theme.inkSecondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          // Pas de fil à attendre : ce qui patiente derrière lui peut y aller.
          .onAppear { LaunchGate.markThreadPainted() }
      }
    }
    .background(theme.paper)
    // Les gens du fil descendent jusqu'aux bulles : c'est ce qui fait d'un
    // « @Nom » une mention plutôt qu'un mot comme les autres.
    .environment(\.mentionNames, mentionNames)
  }

  /// Les noms qu'on peut mentionner ici — la liste que le menu « @ » du
  /// composer tient déjà à jour pour la session ouverte, plus les agents que
  /// le Relais connaît. Dans un atelier, c'est la mention qui désigne lequel
  /// répond : un « @hermes » sans encre laisserait croire qu'on n'a appelé
  /// personne.
  private var mentionNames: [String] {
    MentionHighlight.withAgents(
      store.primarySession?.mentionCandidates.map(\.name) ?? [],
      agents: store.agentDirectory.isEmpty ? MatrixIdentity.knownAgents : store.agentDirectory
    )
  }

  /// Qui est là, qui manque, et de quelle voix — relu depuis le Relais. Tout
  /// ce que le tiroir « + » affiche vient de là : un agent membre du salon, une
  /// voix écrite dans **sa** console.
  private func rechargerLesAgents() async {
    await store.refreshAgentDirectory()
    invitableAgents = await store.invitableAgents()
    agentVoices = await store.agentVoicesInSelectedConversation()
  }

  /// Espace ouvre Quick Look sur la bulle SURVOLÉE — c'est le survol qui
  /// désigne le message (`selectMessage`), comme pour ⌘R. Le champ de saisie a
  /// toujours le curseur dans cette fenêtre : c'est donc le BROUILLON qui
  /// tranche — dès qu'on y a écrit quelque chose, Espace lui revient. Une
  /// espace en tête de message ne veut rien dire ; une espace au milieu d'une
  /// phrase, si. Rien à faire non plus quand le panneau est déjà ouvert (Espace
  /// le referme) ou quand le message ne porte aucune photo.
  private func watchQuickLook() {
    guard quickLookMonitor == nil else { return }
    quickLookMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      guard event.keyCode == 49,
            event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
            store.draftText.isEmpty,
            !(QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible),
            let id = store.selectedMessageID,
            let message = store.messages.first(where: { $0.id == id })
      else { return event }
      let urls = MessageBubbleView.quickLookURLs(for: message)
      guard !urls.isEmpty else { return event }
      QuickLookPanel.open(urls: urls)
      return nil
    }
  }

  /// Le fil ne montre plus une bulle isolée par message : les prises de parole
  /// consécutives se serrent, le nom ne s'écrit qu'une fois, l'heure ne revient
  /// qu'après un silence. Cf. `MessageGrouping`.
  private var messageGroups: [MessageGroup] {
    MessageGrouping.groups(
      for: thread,
      showsSenderNames: store.selectedConversation?.isGroup == true,
      // Fil fusionné : le séparateur d'heure dit sur quel réseau on repart.
      showsNetworkOrigin: isMergedThread
    )
  }

  private var isMergedThread: Bool {
    guard let id = store.selectedConversationID else { return false }
    return store.isMerged(id)
  }

  /// « Voir les messages précédents » : la fenêtre s'ouvre d'un cran, et la
  /// vue reste sur le message qu'on lisait — ce qui arrive arrive au-dessus.
  private func olderMessagesButton(_ proxy: ScrollViewProxy) -> some View {
    Button {
      let anchorID = thread.first?.id
      isNearBottom = false
      windowCount += ThreadMetrics.windowCount
      if let anchorID {
        DispatchQueue.main.async {
          var transaction = Transaction()
          transaction.disablesAnimations = true
          withTransaction(transaction) { proxy.scrollTo(anchorID, anchor: .top) }
        }
      }
    } label: {
      Text("Voir les \(min(hiddenOlderCount, ThreadMetrics.windowCount)) messages précédents")
        .font(Typography.meta(themes.typeface))
        .foregroundStyle(theme.accent)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Voir les messages précédents")
  }

  private var messages: some View {
    ScrollViewReader { proxy in
      ScrollView {
        // Pile simple, et surtout pas paresseuse. Un `LazyVStack` ancré en bas
        // sur des lignes hautes et inégales — des photos — ne converge jamais :
        // il place, découvre que les hauteurs ne sont pas celles qu'il croyait,
        // retraduit l'ancre, replace, sans fin. Le fil tournait à 80 % d'un cœur
        // sans que rien ne bouge à l'écran. La pile reste donc simple, et c'est
        // `windowCount` qui la borne — cf. `thread`.
        VStack(alignment: .leading, spacing: ThreadMetrics.interGroupSpacing) {
          if hiddenOlderCount > 0, launchTail == nil {
            olderMessagesButton(proxy)
          }
          ForEach(messageGroups) { group in
            if let stamp = group.timeSeparator {
              ThreadTimeSeparator(
                date: stamp,
                network: group.networkOrigin,
                theme: theme,
                typeface: themes.typeface
              )
            }
            groupRow(group, proxy: proxy)
          }

          // « Annuler » vit sur CETTE ligne, pas sous la bulle : la ligne est
          // là de « Envoi… » à « Vu », à hauteur constante — un bouton qui
          // prenait une ligne sous la bulle puis s'en allait faisait sauter
          // tout le fil, ancré en bas, à chaque changement d'état.
          // Et elle se déduit du dernier message du fil, pas seulement de la
          // ligne d'inbox : celle-ci se réécrit à chaque `/sync` — une frappe
          // qui dit « écrit… » suffit — et un accusé absent le temps d'un
          // aller-retour faisait clignoter la ligne, donc sauter le fil.
          if let last = thread.last, last.isFromMe {
            let delivery = store.selectedConversation?.lastDelivery
              ?? (last.isPending || store.canUndoSend(last.id) ? .sending : .sent)
            DeliveryReceiptLabel(
              delivery: delivery,
              seenBy: store.selectedConversationID.flatMap { store.seenByLabel($0) },
              onUndo: store.canUndoSend(last.id) ? { store.undoSend(last.id) } : nil,
              theme: theme,
              typeface: themes.typeface
            )
          }

          // Ce qui partira plus tard attend en bas du fil, en pointillé.
          ForEach(store.scheduledForSelection) { scheduled in
            ScheduledMessageRow(
              message: scheduled,
              theme: theme,
              typeface: themes.typeface,
              textScale: themes.textScale
            )
              .id("scheduled-\(scheduled.id)")
          }

          // Les trois points, là où la bulle apparaîtra.
          if let id = store.selectedConversationID, let typing = store.typingLabel(id) {
            TypingBubble(
              name: store.selectedConversation?.isGroup == true ? typing : nil,
              accessibilityLabel: typing,
              theme: theme,
              typeface: themes.typeface,
              cornerRadius: 14
            )
            .padding(.leading, 4)
            .transition(.opacity)
          }

          // LE bas du fil : sous le dernier message il y a l'accusé, les envois
          // programmés… Viser le message laissait tout ça hors champ.
          Color.clear
            .frame(height: 1)
            .id(Self.bottomAnchorID)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.bottom, Spacing.md)
      }
      // `contentMargins` s'AJOUTE à la zone sûre de la barre d'outils — inutile
      // d'y recompter la hauteur du titre.
      .contentMargins(.top, ThreadMetrics.topClearance, for: .scrollContent)
      .defaultScrollAnchor(.bottom)
      .overlay(alignment: .top) { TopScrollFade(theme: theme) }
      // La pilule ↓ : elle ne paraît que lorsqu'on a remonté, et dit combien
      // de messages sont arrivés depuis.
      .overlay(alignment: .bottomTrailing) {
        if !isNearBottom, isShowingThread {
          ScrollToBottomButton(unreadCount: missedCount, theme: theme, size: 34) {
            missedCount = 0
            isNearBottom = true
            withAnimation(.easeOut(duration: 0.2)) {
              proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
          }
          .padding(.trailing, Spacing.md)
          .padding(.bottom, Spacing.sm)
        }
      }
      // Une réaction, une citation, un aperçu qui arrive après coup : le fil
      // grandit sans que son compte bouge, et le bas doit tenir quand même.
      .keepScrolledToBottom(isNearBottom: $isNearBottom) { keepBottom(proxy) }
      // TODO(macOS 27) : réduire la barre d'outils au défilement vers le bas.
      // .toolbarMinimizeBehavior(.onScrollDown, for: .navigationBar)
      .opacity(isShowingThread ? 1 : 0)
      // Cliquer dans le fil vaut lecture. `simultaneousGesture` pour ne rien
      // voler à la sélection de texte ni aux liens des bulles.
      .simultaneousGesture(TapGesture().onEnded { store.confirmSelectionAsRead() })
      .onAppear { pinToBottom(proxy) }
      .task {
        guard awaitsFirstFrame else { return }
        await LaunchGate.firstWindowOnScreen()
        awaitsFirstFrame = false
        LaunchTrace.mark("thread-begin")
        pinToBottom(proxy)
      }
      .onChange(of: store.messages.count) { oldCount, newCount in
        if newCount > oldCount, !isNearBottom { missedCount += newCount - oldCount }
        noteArrival(increased: newCount > oldCount)
        pinToBottom(proxy)
      }
      .task(id: store.selectedConversationID) {
        await rechargerLesAgents()
      }
      .onChange(of: store.selectedConversationID) { _, _ in
        LaunchTrace.event("select")
        missedCount = 0
        isShowingThread = false
        launchTail = ThreadMetrics.launchTailCount
        windowCount = ThreadMetrics.windowCount
        animatesArrivals = false
        settledMessageID = store.messages.last?.id
        isNearBottom = true
        pinToBottom(proxy)
      }
      .onChange(of: store.threadSearchCurrentID) { _, target in
        guard let target else { return }
        // On lit une occurrence, plus le bas : ce qui grandit ne doit pas nous y ramener.
        isNearBottom = false
        // L'occurrence peut vivre au-dessus de la fenêtre : on l'ouvre jusqu'à
        // elle, puis on y va — après la passe de layout, sinon l'ancre n'existe pas.
        if !thread.contains(where: { $0.id == target }),
           let index = store.messages.firstIndex(where: { $0.id == target }) {
          windowCount = max(windowCount, store.messages.count - index + 10)
          DispatchQueue.main.async {
            proxy.scrollTo(target, anchor: .center)
          }
          return
        }
        withAnimation(.easeOut(duration: 0.18)) {
          proxy.scrollTo(target, anchor: .center)
        }
      }
    }
  }

  /// Une prise de parole : la photo de son auteur dans la marge, puis ses bulles.
  /// La photo se coupe dans Réglages ; les événements de conversation, eux, ne
  /// sont de personne et gardent toute la largeur.
  @ViewBuilder
  private func groupRow(_ group: MessageGroup, proxy: ScrollViewProxy) -> some View {
    let first = group.messages.first
    let showsAvatar = themes.showsMessageAvatars
      && !group.isFromMe
      && first?.isSystemEvent != true
    // La photo se pose EN BAS de la prise de parole, en face de la dernière
    // bulle : c'est là que Messages, WhatsApp et Telegram la mettent, et c'est
    // la bulle la plus récente que l'œil cherche à attribuer. Sur son BORD, pas
    // sous ce qui la suit — cf. `VerticalAlignment.bubbleBottom`.
    HStack(alignment: .bubbleBottom, spacing: ThreadMetrics.avatarSpacing) {
      if showsAvatar, let first {
        MessageAvatarView(
          message: first,
          conversation: store.conversation(ofMessage: first),
          size: ThreadMetrics.avatarSize,
          theme: theme
        )
      }
      VStack(alignment: .leading, spacing: ThreadMetrics.intraGroupSpacing) {
        if let label = group.senderLabel {
          Text(label)
            .font(Typography.meta(themes.typeface))
            .foregroundStyle(SenderTint.color(for: label, theme: theme))
            .lineLimit(1)
            .padding(.leading, ThreadMetrics.senderLabelLeading)
        }
        ForEach(Array(group.messages.enumerated()), id: \.element.id) { index, message in
          if let proposal = message.agentProposal {
            AgentProposalCard(
              proposal: proposal,
              theme: theme,
              typeface: themes.typeface,
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
              typeface: themes.typeface,
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
            ThreadEventSeparator(text: event, theme: theme, typeface: themes.typeface)
              .id(message.id)
          } else if message.isFromMe, message.isPiloted {
            // Envoyé par cc en mon nom : la bulle est la mienne, la ligne
            // dessous le dit — en rouge, parce que c'est le mode qui engage.
            VStack(alignment: .trailing, spacing: 2) {
              bubble(for: message, position: BubblePosition(index: index, count: group.messages.count), proxy: proxy)
                .equatable()
              PilotedFootnote(
                agent: store.agentsInSelectedConversation.first ?? MatrixIdentity.agentName,
                sentAt: message.sentAt,
                theme: theme,
                typeface: themes.typeface
              )
            }
            .id(message.id)
          } else {
            // `.equatable()` : le fil se rafraîchit pour mille raisons qui ne
            // regardent pas cette bulle-là. Cf. `MessageBubbleView: Equatable`.
            bubble(for: message, position: BubblePosition(index: index, count: group.messages.count), proxy: proxy)
              .equatable()
              .id(message.id)
              .messageArrival(
                .encre,
                isFresh: isFresh(message),
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

  /// Une bulle et tout ce qu'on peut lui faire. Extraite de la boucle : le
  /// vérificateur de types s'y perdait.
  /// Le type concret, pas `some View` : `.equatable()` a besoin de savoir que
  /// c'est une `MessageBubbleView` pour se servir de son `==`.
  private func bubble(for message: ChatMessage, position: BubblePosition, proxy: ScrollViewProxy) -> MessageBubbleView {
    // « Modifier » ouvre le composer en mode correction ; c'est le magasin qui
    // choisit ensuite le chemin — automatisation Messages ou `m.replace`.
    let onEdit: (() -> Void)? = store.canEditAnyway(message)
      ? { store.beginEditing(message) }
      : nil
    // Deux minutes, pas plus : au-delà, Messages n'a plus l'entrée du menu.
    let onUndoSend: (() -> Void)? = store.canUndoSendViaAutomation(message)
      ? { Task { await store.undoSendViaAutomation(messageID: message.id) } }
      : nil
    return MessageBubbleView(
      message: message,
      theme: theme,
      typeface: themes.typeface,
      textScale: themes.textScale,
      showsLinkPreviews: themes.showsLinkPreviews,
      highlightQuery: store.isThreadSearchActive ? store.threadSearchQuery : "",
      isCurrentMatch: store.threadSearchCurrentID == message.id,
      position: position,
      // Survoler une bulle, c'est la viser : ⌘R, ⌘T et ⌘⌥R agissaient sinon
      // sur le dernier message du fil, jamais sur celui qu'on regardait.
      onHoverBegan: { store.selectMessage(message.id) },
      onQuoteTap: message.replyTo?.messageID.map { targetID in { jumpTo(targetID, proxy: proxy) } },
      onReact: { emoji in
        Task { await store.react(messageID: message.id, emoji: emoji) }
      },
      onReply: {
        store.selectMessage(message.id)
        store.replyToSelectedMessage()
      },
      onEdit: onEdit,
      onUndoSend: onUndoSend,
      onForward: store.canForward(message) ? { store.beginForwarding(message) } : nil,
      // Le dernier message a son « Annuler » sur la ligne de l'accusé ; seul
      // un envoi en sursis qui n'est plus le dernier garde le sien sous lui.
      onCancelPending: store.canUndoSend(message.id) && thread.last?.id != message.id
        ? { store.undoSend(message.id) } : nil,
      onDeleteLocally: { store.deleteLocally(messageID: message.id) },
      onDeleteEverywhere: store.canDeleteEverywhere(message)
        ? { Task { await store.deleteEverywhere(messageID: message.id) } }
        : nil,
      onVotePoll: message.poll == nil ? nil : { answerID in
        Task { await store.votePoll(messageID: message.id, answerID: answerID) }
      }
    )
  }

  /// L'encre ne prend que sur un vrai message, jamais sur une bascule de
  /// conversation. Et elle ne dure que le temps du geste : passé ce délai la
  /// bulle est une bulle comme les autres, et elle ne se retracera pas si le
  /// défilement la fait renaître.
  /// Vrai pour le dernier message tant qu'il n'a pas fini de se poser. Calculé
  /// dans le corps de la vue : la ligne connaît donc son sort dès sa naissance,
  /// et sa valeur initiale suffit à lancer le geste — pas de rattrapage.
  private func isFresh(_ message: ChatMessage) -> Bool {
    animatesArrivals
      && store.didSettleInitialMatrixSync
      && message.id == store.messages.last?.id
      && message.id != settledMessageID
      // Un message d'hier découvert en ouvrant le fil est déjà vu : posé, pas tracé.
      && MessageArrivalPolicy.isNewArrival(sentAt: message.sentAt)
  }

  private func noteArrival(increased: Bool) {
    guard increased, animatesArrivals else { return }
    let id = store.messages.last?.id
    Task {
      try? await Task.sleep(for: .seconds(1.2))
      if store.messages.last?.id == id { settledMessageID = id }
    }
  }

  /// Le saut vers un message cité : on y va — en ouvrant la fenêtre jusqu'à lui
  /// s'il est plus haut qu'elle, comme le fait ⌘F — on le surligne, l'éclat s'éteint.
  private func jumpTo(_ messageID: String, proxy: ScrollViewProxy) {
    isNearBottom = false
    if !thread.contains(where: { $0.id == messageID }) {
      guard let index = store.messages.firstIndex(where: { $0.id == messageID }) else { return }
      windowCount = max(windowCount, store.messages.count - index + 10)
      launchTail = nil
      DispatchQueue.main.async { proxy.scrollTo(messageID, anchor: .center) }
    } else {
      withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(messageID, anchor: .center) }
    }
    withAnimation(.easeOut(duration: 0.2)) { flashedMessageID = messageID }
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(1.2))
      guard flashedMessageID == messageID else { return }
      withAnimation(.easeOut(duration: 0.5)) { flashedMessageID = nil }
    }
  }

  /// Si on lisait le bas, on y reste — dans la même passe, sans animer : rien
  /// ne doit défiler à l'écran. Remonter d'un cran libère l'ancre.
  private static let bottomAnchorID = "thread-bottom"

  private func keepBottom(_ proxy: ScrollViewProxy) {
    guard isNearBottom else { return }
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) { proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom) }
  }

  private func pinToBottom(_ proxy: ScrollViewProxy) {
    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
    DispatchQueue.main.async {
      // Pas de second `scrollTo(id)` ici : il s'arrête 14 pt trop haut et, joué
      // après coup, il défaisait le recalage au bord réel que
      // `keepScrolledToBottom` vient de faire sur le contenu arrivé — le fil
      // paraissait alors décalé, puis sautait au premier changement de hauteur.
      // Tant que le fil n'est pas arrivé, rien n'est « posé » ni à montrer.
      guard !awaitsFirstFrame else { return }
      isShowingThread = true
      LaunchTrace.mark("thread")
      LaunchTrace.event("shown", store.messages.count)
      LaunchBench.noteShown(count: store.messages.count)
      LaunchGate.markThreadPainted()
      if launchTail != nil, !store.messages.isEmpty {
        // La queue est peinte ; le reste du fil monte au-dessus, hors champ.
        // Un court délai, pour que la frame de la queue parte avant. Si le
        // fil change d'ici là (chargement après la bascule), la passe qui
        // suit reprogrammera la sienne.
        let count = store.messages.count
        pendingExpansionCount = count
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(80)) {
          guard pendingExpansionCount == count, store.messages.count == count else { return }
          pendingExpansionCount = nil
          launchTail = nil
          DispatchQueue.main.async {
            LaunchTrace.mark("thread-full")
            LaunchTrace.event("full", store.messages.count)
          }
        }
      }
      // Ce qui est à l'écran à l'ouverture est déjà posé.
      settledMessageID = store.messages.last?.id
      // Un fil encore vide (la session vient de naître, le chargement suit)
      // n'arme pas le geste : ce qui va le remplir est un chargement, pas une
      // arrivée. Il s'armera à la passe suivante, une fois le fil posé.
      animatesArrivals = !store.messages.isEmpty
    }
  }
}

enum ThreadMetrics {
  /// Deux bulles d'une même prise de parole se touchent presque…
  static let intraGroupSpacing: CGFloat = 2
  /// …et l'on ne respire qu'entre deux prises de parole. Un cran au-dessus de
  /// l'ancien 12 : les bulles ayant gagné leur interligne de lecture, il fallait
  /// que l'air ENTRE deux voix reste plus large que l'air entre deux lignes.
  static let interGroupSpacing: CGFloat = Spacing.md
  /// Le nom s'aligne sur le texte de la bulle, pas sur son bord.
  static let senderLabelLeading: CGFloat = 16
  /// Le visage de l'auteur dans la marge gauche, comme Beeper.
  static let avatarSize: CGFloat = 26
  /// Air entre la photo et la première bulle.
  static let avatarSpacing: CGFloat = 8
  /// Air au-dessus du premier message, en plus de la zone sûre de la barre
  /// d'outils que le système fournit déjà.
  static let topClearance: CGFloat = 16
  /// Ce que la première peinture du lancement emporte. Assez pour remplir une
  /// fenêtre haute de bulles courtes (≈ 40 pt chacune), assez peu pour que
  /// la passe reste brève : 15 → 30 messages coûtaient ~50 ms de plus.
  static let launchTailCount = 20
  /// La fenêtre d'affichage du fil : ce qui est monté d'un coup. Au-delà,
  /// « Voir les messages précédents ». Cent cinquante : trois fois le plus
  /// gros fil sain mesuré, un tiers du fil qui ramait.
  static let windowCount = 150
  /// Hauteur de la bande où le fil se dissout sous la barre d'outils.
  static let topFadeHeight: CGFloat = 64
}

/// Séparateur horaire centré, discret — comme Messages : on ne redate que
/// lorsque la conversation a repris après un silence, jamais sous chaque bulle.
struct ThreadTimeSeparator: View {
  let date: Date
  /// Sur un fil fusionné : le réseau d'où repart la suite (« 15:48 · iMessage »).
  var network: MessageNetwork?
  let theme: WritingTheme
  let typeface: WritingTypeface

  var body: some View {
    HStack(spacing: 4) {
      Text(label)
      if let network {
        Text("·")
        Image(systemName: network.systemImage)
          .font(.system(size: 9, weight: .semibold))
        Text(network.labelFR)
      }
    }
    .font(Typography.meta(typeface))
    .foregroundStyle(theme.inkTertiary)
    .frame(maxWidth: .infinity)
    .padding(.top, Spacing.xs)
    .padding(.bottom, Spacing.xxs)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      network.map { "Reprise de la conversation sur \($0.labelFR), \(label)" }
        ?? "Reprise de la conversation, \(label)"
    )
  }

  /// Aujourd'hui : l'heure suffit. Plus loin : il faut aussi le jour, sinon
  /// « 09:12 » ne dit pas si c'était ce matin ou l'an dernier.
  private var label: String {
    let calendar = Calendar.current
    let time = date.formatted(date: .omitted, time: .shortened)
    if calendar.isDateInToday(date) { return time }
    if calendar.isDateInYesterday(date) { return "Hier \(time)" }
    if let days = calendar.dateComponents([.day], from: date, to: .now).day, days < 7 {
      return "\(date.formatted(.dateTime.weekday(.wide))) \(time)"
    }
    return date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
  }
}

/// Événement de conversation (« X a ajouté Y », renommage, départ) : une ligne
/// centrée, du même gris que les horodatages — présente, jamais bavarde.
struct ThreadEventSeparator: View {
  let text: String
  let theme: WritingTheme
  let typeface: WritingTypeface

  var body: some View {
    Text(text)
      .font(Typography.meta(typeface))
      .foregroundStyle(theme.inkTertiary)
      .multilineTextAlignment(.center)
      .frame(maxWidth: .infinity)
      .padding(.vertical, Spacing.xxs)
      .accessibilityLabel(text)
  }
}

/// Barre ⌘F du fil : champ, compteur, précédent / suivant, Échap pour fermer.
private struct ThreadSearchBar: View {
  @Environment(InboxStore.self) private var store
  let theme: WritingTheme
  let typeface: WritingTypeface
  @FocusState private var isFocused: Bool

  private var countLabel: String {
    let total = store.threadSearchMatchIDs.count
    guard total > 0 else {
      return store.threadSearchQuery.isEmpty ? "" : "Aucun résultat"
    }
    return "\(store.threadSearchCursor + 1) sur \(total)"
  }

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 11))
        .foregroundStyle(theme.inkTertiary)

      TextField("Rechercher dans le fil", text: Bindable(store).threadSearchQuery)
        .textFieldStyle(.plain)
        .font(Typography.meta(typeface))
        .foregroundStyle(theme.ink)
        .focused($isFocused)
        .onKeyPress(.escape) {
          store.closeThreadSearch()
          return .handled
        }
        .onKeyPress(.return) {
          if NSEvent.modifierFlags.contains(.shift) {
            store.threadSearchPrevious()
          } else {
            store.threadSearchNext()
          }
          return .handled
        }

      Text(countLabel)
        .font(Typography.meta(typeface))
        .foregroundStyle(theme.inkTertiary)
        .monospacedDigit()

      Button { store.threadSearchPrevious() } label: {
        Image(systemName: "chevron.up")
      }
      .disabled(store.threadSearchMatchIDs.isEmpty)
      .accessibilityLabel("Résultat précédent")

      Button { store.threadSearchNext() } label: {
        Image(systemName: "chevron.down")
      }
      .disabled(store.threadSearchMatchIDs.isEmpty)
      .accessibilityLabel("Résultat suivant")

      Button { store.closeThreadSearch() } label: {
        Image(systemName: "xmark")
      }
      .accessibilityLabel("Fermer la recherche")
    }
    .buttonStyle(.borderless)
    .font(.system(size: 11, weight: .semibold))
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, 7)
    .background(theme.paperSecondary)
    .overlay(alignment: .bottom) {
      Rectangle().fill(theme.edge).frame(height: 1)
    }
    .onAppear { isFocused = true }
  }
}

/// Bandeau « en réponse à… » au-dessus du composer, avec sa croix pour annuler.
private struct ReplyBanner: View {
  @Environment(InboxStore.self) private var store
  let message: ChatMessage
  let theme: WritingTheme
  let typeface: WritingTypeface

  /// Le nom qu'on affiche — jamais l'identifiant technique du réseau. Un
  /// message bridgé sans nom retombe sur le titre du fil : c'est toujours
  /// à quelqu'un qu'on répond.
  private var targetNameFR: String {
    message.displayedSenderName ?? store.selectedConversation?.title ?? "ce message"
  }

  var body: some View {
    HStack(spacing: 8) {
      RoundedRectangle(cornerRadius: 1, style: .continuous)
        .fill(theme.accent)
        .frame(width: 2, height: 26)
      VStack(alignment: .leading, spacing: 1) {
        Text(message.isFromMe ? "Réponse à moi-même" : "En réponse à \(targetNameFR)")
          .font(Typography.meta(typeface))
          .foregroundStyle(theme.accent)
        Text(message.sidebarPreviewText)
          .font(Typography.meta(typeface))
          .foregroundStyle(theme.inkSecondary)
          .lineLimit(1)
      }
      Spacer(minLength: 8)
      Button { store.cancelReply() } label: {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .semibold))
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("Annuler la citation")
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, 6)
    .background(theme.paperSecondary)
  }
}

/// Bandeau « correction en cours » au-dessus du composer, avec sa croix.
/// Même forme que la citation (⌘R) : c'est le même geste, sur l'autre bord du
/// temps — l'un désigne ce à quoi on répond, l'autre ce qu'on réécrit.
private struct EditBanner: View {
  @Environment(InboxStore.self) private var store
  let message: ChatMessage
  let theme: WritingTheme
  let typeface: WritingTypeface

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "pencil")
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(theme.accent)
      VStack(alignment: .leading, spacing: 1) {
        Text("Modification du message")
          .font(Typography.meta(typeface))
          .foregroundStyle(theme.accent)
        Text(message.text)
          .font(Typography.meta(typeface))
          .foregroundStyle(theme.inkSecondary)
          .lineLimit(1)
      }
      Spacer(minLength: 8)
      Button { store.cancelEditing() } label: {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .semibold))
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("Renoncer à la modification")
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, 6)
    .background(theme.paperSecondary)
  }
}

/// Coche d'acheminement sous le dernier message sortant.
///
/// iMessage la donne complète (`is_delivered` / `is_read`). WhatsApp ne bridge que la
/// **lecture** : on y montre « Envoyé » ou « Vu », jamais « Livré ». Signal ne bridge
/// aucun accusé de livraison — rien ne s'affiche.
private struct DeliveryReceiptLabel: View {
  let delivery: MessageDelivery
  /// « Vu par Alice et Bruno » — le détail des lecteurs, dans un groupe.
  /// Quand il existe, il remplace le « Vu » anonyme.
  var seenBy: String?
  /// Le dernier envoi est encore rattrapable : « Annuler » à côté de « Envoi… ».
  var onUndo: (() -> Void)?
  let theme: WritingTheme
  let typeface: WritingTypeface

  private var label: String {
    delivery == .read ? (seenBy ?? delivery.labelFR) : delivery.labelFR
  }

  var body: some View {
    HStack(spacing: 3) {
      if let onUndo {
        Button("Annuler", action: onUndo)
          .buttonStyle(.plain)
          .font(Typography.meta(typeface))
          .foregroundStyle(theme.accent)
          .help("Ce message n’est pas encore parti")
          .accessibilityLabel("Annuler l’envoi de ce message")
        Text("·")
          .font(Typography.meta(typeface))
          .padding(.horizontal, 2)
      }
      Image(systemName: delivery.systemImage)
        .font(.system(size: 9))
      Text(label)
        .font(Typography.meta(typeface))
    }
    .foregroundStyle(delivery == .read ? theme.accent : theme.inkTertiary)
    .frame(maxWidth: .infinity, alignment: .trailing)
    .padding(.trailing, 4)
    // La ligne ne change pas de hauteur quand « Annuler » s'en va ou que le
    // libellé change : même fonte, même rangée. Ce qui bouge, c'est le mot.
    .animation(nil, value: label)
    .accessibilityLabel("Dernier message : \(label)")
  }
}
