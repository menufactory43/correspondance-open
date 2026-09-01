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

  @Environment(RelayStore.self) private var store
  @Environment(ThemePreferences.self) private var themes

  @State private var isShowingInfo = false
  /// La bulle sous appui long, et le nom qu'elle portait dans le fil.
  @State private var focused: FocusedMessage?
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

  private var theme: WritingTheme { themes.theme }
  private var typeface: WritingTypeface { themes.typeface }

  private var conversation: Conversation? { store.conversation(conversationID) }

  private struct FocusedMessage: Equatable {
    var message: ChatMessage
    var senderLabel: String?
  }

  var body: some View {
    thread
      .background(theme.paper.ignoresSafeArea())
      .safeAreaInset(edge: .bottom, spacing: 0) {
        ThreadComposer(conversationID: conversationID)
      }
      .overlay {
        if let focused {
          MessageActionsOverlay(
            message: focused.message,
            conversationID: conversationID,
            senderLabel: focused.senderLabel
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
      .toolbarBackground(.hidden, for: .navigationBar)
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
      .task(id: conversationID) { await store.open(conversationID: conversationID) }
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
        Color.clear.frame(height: 4)

        ForEach(groups) { group in
          if let separator = group.timeSeparator {
            timeSeparator(separator, network: group.networkOrigin)
          }
          // La photo de l'auteur dans la marge d'une prise de parole reçue,
          // comme sur le Mac : en bas du groupe, en face de la dernière bulle.
          HStack(alignment: .bottom, spacing: 8) {
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
                    onCancelPending: store.canUndoSend(message.id)
                      ? { store.undoSend(message.id) }
                      : nil,
                    onSendProposal: {
                      Task { await store.sendAgentProposal(message, conversationID: conversationID) }
                    },
                    onEditProposal: { store.editAgentProposal(message, conversationID: conversationID) },
                    onIgnoreProposal: { store.ignoreAgentProposal(message, conversationID: conversationID) }
                  )
                  .id(message.id)
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

        // « Alice écrit… », au bas du fil, là où sa bulle apparaîtra.
        if let typing = store.typingLabel(conversationID) {
          Text(typing)
            .font(Typography.meta(typeface))
            .foregroundStyle(theme.inkTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 6)
            .transition(.opacity)
            .accessibilityLabel(typing)
        }

        if let receipt = readReceiptLabel {
          Text(receipt)
            .font(Typography.meta(typeface))
            .foregroundStyle(theme.inkTertiary)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 6)
            .accessibilityLabel("Dernier message \(receipt)")
        }

        Color.clear.frame(height: 8)
      }
      .padding(.horizontal, Spacing.sm)
    }
    .scrollDismissesKeyboard(.interactively)
    .defaultScrollAnchor(.bottom)
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
      let nearBottom = !new.isScrollable || new.distanceToBottom <= 60
      if nearBottom != isNearBottom {
        withAnimation(.easeOut(duration: 0.2)) { isNearBottom = nearBottom }
      }
    }
    // Le chevron au-dessus du bouton d'envoi : il n'apparaît que lorsqu'on
    // a quitté le bas du fil, et un appui y ramène.
    .overlay(alignment: .bottomTrailing) {
      if !isNearBottom {
        Button {
          scrollToBottom(duration: 0.3)
        } label: {
          Image(systemName: "chevron.down")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(theme.ink)
            .frame(width: 38, height: 38)
            // Verre NON interactif : le mode interactif héberge la vue dans
            // une couche de verre qui avale les touches en overlay — vérifié
            // au test d'interface, le bouton devenait intouchable.
            .glassSurface(cornerRadius: 19, fallbackFill: theme.paperSecondary, border: theme.edge)
        }
        .padding(.trailing, Spacing.sm)
        .padding(.bottom, 10)
        .accessibilityLabel("Aller au dernier message")
      }
    }
    .onChange(of: messages.last?.id) { _, _ in
      // Un souffle : la bulle qui vient d'arriver doit être mesurée avant
      // qu'on sache où est le nouveau bas.
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(80))
        scrollToBottom()
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
    withAnimation(.easeOut(duration: duration)) {
      scrollPosition.scrollTo(y: metrics.bottomScrollTarget)
    }
    Task { @MainActor in
      for _ in 0..<3 {
        try? await Task.sleep(for: .milliseconds(Int(duration * 1000) + 80))
        guard metrics.distanceToBottom > 60 else { return }
        withAnimation(.easeOut(duration: 0.15)) {
          scrollPosition.scrollTo(y: metrics.bottomScrollTarget)
        }
      }
    }
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
    /// La cible `scrollTo(y:)` qui repose le dernier message sur le composer.
    var bottomScrollTarget: CGFloat { offsetY + distanceToBottom + insetTop }
    /// Un fil qui tient à l'écran n'a pas de bas où descendre.
    var isScrollable: Bool { contentHeight > visibleHeight - insetTop - insetBottom }
  }

  private var messages: [ChatMessage] { store.visibleMessages(conversationID) }
  private var groups: [MessageGroup] { store.groups(conversationID) }

  /// « Vu » sous le dernier message sortant — quand le réseau l'expose.
  /// Signal et WhatsApp ne le donnent pas : on n'affiche alors rien plutôt
  /// qu'un état inventé.
  private var readReceiptLabel: String? {
    guard let delivery = conversation?.lastDelivery,
          messages.last?.isFromMe == true
    else { return nil }
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
    }
    .padding(.leading, 5)
    .padding(.trailing, 12)
    .padding(.vertical, 5)
    .glassSurface(cornerRadius: 18, fallbackFill: theme.sidebar, border: theme.edge, isInteractive: true)
    .contentShape(Capsule())
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(conversation.title), \(conversation.network.labelFR)")
  }
}
