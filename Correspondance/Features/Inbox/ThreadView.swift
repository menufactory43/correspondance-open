import AppKit
import SwiftUI
import CorrespondanceCore
import CorrespondanceUI

struct ThreadView: View {
  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isShowingThread = false
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
  /// Le compte de messages pour lequel une expansion est programmée : si le
  /// fil a changé entre-temps (chargement arrivé après la queue), on laisse
  /// la passe suivante reprogrammer la sienne.
  @State private var pendingExpansionCount: Int?
  /// Vrai tant que le lecteur n'a pas remonté le fil : c'est ce qui décide si
  /// une hauteur qui change (réaction, citation, aperçu) le garde en bas.
  @State private var isNearBottom = true

  private var theme: WritingTheme { themes.theme }
  private var thread: [ChatMessage] {
    if awaitsFirstFrame { return [] }
    if let launchTail { return Array(store.messages.suffix(launchTail)) }
    return store.messages
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
          if let config = store.sendLaterConfig {
            SendLaterBanner(config: config, theme: theme, typeface: themes.typeface)
          }
          ComposerBar(
            text: Bindable(store).draftText,
            attachmentPaths: Bindable(store).pendingAttachmentPaths,
            isSending: store.isSending,
            isScheduling: store.sendLaterConfig != nil,
            theme: theme,
            onAttach: { store.pickAttachments() },
            onSendLater: { store.toggleSendLaterPicker() },
            onSend: { Task { await store.sendDraft() } }
          )
          .popover(isPresented: sendLaterPickerPresented, arrowEdge: .top) {
            SendLaterPicker()
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

  private var messages: some View {
    ScrollViewReader { proxy in
      ScrollView {
        // Pile simple, et surtout pas paresseuse. Un `LazyVStack` ancré en bas
        // sur des lignes hautes et inégales — des photos — ne converge jamais :
        // il place, découvre que les hauteurs ne sont pas celles qu'il croyait,
        // retraduit l'ancre, replace, sans fin. Le fil tournait à 80 % d'un cœur
        // sans que rien ne bouge à l'écran. Le fil est borné à cent vingt
        // messages : les construire tous coûte moins cher que cette boucle.
        VStack(alignment: .leading, spacing: ThreadMetrics.interGroupSpacing) {
          ForEach(messageGroups) { group in
            if let stamp = group.timeSeparator {
              ThreadTimeSeparator(
                date: stamp,
                network: group.networkOrigin,
                theme: theme,
                typeface: themes.typeface
              )
            }
            groupRow(group)
          }

          if let delivery = store.selectedConversation?.lastDelivery,
             thread.last?.isFromMe == true
          {
            DeliveryReceiptLabel(delivery: delivery, theme: theme, typeface: themes.typeface)
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
        noteArrival(increased: newCount > oldCount)
        pinToBottom(proxy)
      }
      .onChange(of: store.selectedConversationID) { _, _ in
        LaunchTrace.event("select")
        isShowingThread = false
        launchTail = ThreadMetrics.launchTailCount
        animatesArrivals = false
        settledMessageID = store.messages.last?.id
        isNearBottom = true
        pinToBottom(proxy)
      }
      .onChange(of: store.threadSearchCurrentID) { _, target in
        guard let target else { return }
        // On lit une occurrence, plus le bas : ce qui grandit ne doit pas nous y ramener.
        isNearBottom = false
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
  private func groupRow(_ group: MessageGroup) -> some View {
    let first = group.messages.first
    let showsAvatar = themes.showsMessageAvatars
      && !group.isFromMe
      && first?.isSystemEvent != true
    HStack(alignment: .top, spacing: ThreadMetrics.avatarSpacing) {
      if showsAvatar, let first {
        MessageAvatarView(
          message: first,
          conversation: store.conversation(ofMessage: first),
          size: ThreadMetrics.avatarSize,
          theme: theme
        )
        // La photo s'aligne sur la première bulle, pas sur le nom au-dessus.
        .padding(.top, group.senderLabel == nil ? 2 : ThreadMetrics.avatarLabelOffset)
      }
      VStack(alignment: .leading, spacing: ThreadMetrics.intraGroupSpacing) {
        if let label = group.senderLabel {
          Text(label)
            .font(Typography.meta(themes.typeface))
            .foregroundStyle(theme.inkSecondary)
            .lineLimit(1)
            .padding(.leading, ThreadMetrics.senderLabelLeading)
        }
        ForEach(group.messages) { message in
          if let event = message.systemEventText {
            ThreadEventSeparator(text: event, theme: theme, typeface: themes.typeface)
              .id(message.id)
          } else {
            bubble(for: message)
              .id(message.id)
              .messageArrival(
                .encre,
                isFresh: isFresh(message),
                isEnabled: !reduceMotion
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
  private func bubble(for message: ChatMessage) -> some View {
    let automatable = automationAvailable(for: message)
    let onEdit: ((String) -> Void)? = automatable
      ? { newText in Task { await store.editMessageViaAutomation(messageID: message.id, newText: newText) } }
      : nil
    let onUndoSend: (() -> Void)? = automatable
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
      onReact: { emoji in
        Task { await store.react(messageID: message.id, emoji: emoji) }
      },
      onReply: {
        store.selectMessage(message.id)
        store.replyToSelectedMessage()
      },
      onEdit: onEdit,
      onUndoSend: onUndoSend,
      onDeleteLocally: { store.deleteLocally(messageID: message.id) },
      onDeleteEverywhere: store.canDeleteEverywhere(message)
        ? { Task { await store.deleteEverywhere(messageID: message.id) } }
        : nil
    )
  }

  /// « Modifier » et « Annuler l'envoi » n'ont de sens que sur mes iMessages,
  /// et seulement quand l'automatisation Messages est active et saine.
  private func automationAvailable(for message: ChatMessage) -> Bool {
    message.network == .iMessage && message.isFromMe && store.canAutomateMessages
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
  /// Quand un nom coiffe le groupe, la photo descend le long de la première bulle.
  static let avatarLabelOffset: CGFloat = 18
  /// Air au-dessus du premier message, en plus de la zone sûre de la barre
  /// d'outils que le système fournit déjà.
  static let topClearance: CGFloat = 16
  /// Ce que la première peinture du lancement emporte. Assez pour remplir une
  /// fenêtre haute de bulles courtes (≈ 40 pt chacune), assez peu pour que
  /// la passe reste brève : 15 → 30 messages coûtaient ~50 ms de plus.
  static let launchTailCount = 20
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

/// Coche d'acheminement sous le dernier message sortant.
///
/// iMessage la donne complète (`is_delivered` / `is_read`). WhatsApp ne bridge que la
/// **lecture** : on y montre « Envoyé » ou « Vu », jamais « Livré ». Signal ne bridge
/// aucun accusé de livraison — rien ne s'affiche.
private struct DeliveryReceiptLabel: View {
  let delivery: MessageDelivery
  let theme: WritingTheme
  let typeface: WritingTypeface

  var body: some View {
    HStack(spacing: 3) {
      Image(systemName: delivery.systemImage)
        .font(.system(size: 9))
      Text(delivery.labelFR)
        .font(Typography.meta(typeface))
    }
    .foregroundStyle(delivery == .read ? theme.accent : theme.inkTertiary)
    .frame(maxWidth: .infinity, alignment: .trailing)
    .padding(.trailing, 4)
    .accessibilityLabel("Dernier message : \(delivery.labelFR)")
  }
}
