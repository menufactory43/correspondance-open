import SwiftUI
import CorrespondanceCore
import CorrespondanceUI

struct InboxListPane: View {
  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes

  @State private var pendingLeaveID: String?
  @FocusState private var isSearchFocused: Bool

  private var theme: WritingTheme { themes.theme }

  /// La `List` n'a plus de sélection native : son surlignage se peint avec
  /// l'accent du système — un bleu franc qui écrase la ligne une demi-seconde
  /// avant de céder la place à la nôtre. C'est donc le clic qui choisit.
  private func choose(_ id: String) {
    // En sélection multiple, cliquer coche : on désigne des fils, on n'en lit
    // aucun. Ouvrir en même temps marquerait comme lu ce qu'on allait archiver.
    guard !store.isSelectionMode else {
      store.toggleSelection(id)
      return
    }
    // Recliquer la ligne déjà sélectionnée n'est pas un non-événement quand
    // c'est l'app qui l'avait choisie au lancement : c'est le geste par
    // lequel l'utilisateur dit qu'il lit enfin ce fil.
    guard id != store.selectedConversationID else {
      store.confirmSelectionAsRead()
      return
    }
    Task { await store.select(id) }
  }

  var body: some View {
    VStack(spacing: 0) {
      if store.usingDemoData {
        PermissionBanner()
          .padding(.horizontal, Spacing.sm)
          .padding(.vertical, Spacing.xs)
      }
      if store.needsContactsPermission {
        ContactsPermissionBanner()
          .padding(.horizontal, Spacing.sm)
          .padding(.bottom, Spacing.xs)
      }

      searchField

      if store.isFilterBarVisible { filterRow }

      facetRow

      List {
        if let facet = store.searchFacet, !facet.isConversationFacet {
          facetSection(facet)
        } else if store.searchFacet == .drafts {
          section(title: "Brouillons", items: store.facetDrafts)
        } else if store.isShowingScheduled {
          scheduledSection
        } else if store.isShowingArchived {
          section(title: "Archivés", items: store.archivedQueue)
        } else {
          // Les inconnus qui ont écrit les premiers : rien n'entre dans la
          // file avant qu'on l'ait accepté.
          section(title: "Demandes", items: store.requestsQueue)
          section(title: "Récents", items: store.inboxRecents)
          section(title: "Groupes", items: store.inboxGroups)
          section(title: "Contacts", items: store.inboxContacts)
          // Ce qu'on a mis de côté : hors de la file, mais jamais hors de vue.
          // Chaque ligne revient d'elle-même à l'heure dite.
          section(title: "Rappels", items: store.remindersQueue)
        }
      }
      .listStyle(.sidebar)
      .scrollContentBackground(.hidden)
      .environment(\.defaultMinListRowHeight, 52)
      .overlay {
        if currentQueue.isEmpty, store.searchFacet == nil {
          emptyState
        }
      }

      if store.isSelectionMode { selectionBar }

      archiveToggle
    }
    .confirmationDialog(
      "Quitter le groupe ?",
      isPresented: Binding(
        get: { pendingLeaveID != nil },
        set: { if !$0 { pendingLeaveID = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Quitter le groupe", role: .destructive) {
        guard let id = pendingLeaveID else { return }
        Task { await store.leaveGroup(conversationID: id) }
        pendingLeaveID = nil
      }
      Button("Annuler", role: .cancel) { pendingLeaveID = nil }
    } message: {
      Text("Tu ne recevras plus les messages de ce groupe.")
    }
    .confirmationDialog(
      store.archiveAllReadPrompt ?? "",
      isPresented: Binding(
        get: { store.archiveAllReadPrompt != nil },
        set: { if !$0 { store.cancelArchiveAllRead() } }
      ),
      titleVisibility: .visible
    ) {
      Button("Archiver") { Task { await store.archiveAllRead() } }
      Button("Annuler", role: .cancel) { store.cancelArchiveAllRead() }
    } message: {
      Text("Les fils épinglés et les non lus restent dans la file. Un nouveau message ramène un fil archivé.")
    }
  }

  /// Le champ de recherche appartient à la LISTE, pas à la colonne.
  /// `.searchable(placement: .sidebar)` le hisse au-dessus de la colonne
  /// entière : la pilule enjambait alors le rail des réseaux. Posé ici, il
  /// commence là où commence la liste et s'arrête avec elle.
  private var searchField: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 12))
        .foregroundStyle(theme.inkTertiary)

      TextField(
        "Rechercher une conversation",
        text: Bindable(store).searchQuery
      )
      .textFieldStyle(.plain)
      .font(Typography.meta(themes.typeface))
      .foregroundStyle(theme.ink)
      .focused($isSearchFocused)
      .onKeyPress(.escape) {
        guard !store.searchQuery.isEmpty else { return .ignored }
        store.searchQuery = ""
        return .handled
      }

      if !store.searchQuery.isEmpty {
        Button {
          store.searchQuery = ""
          isSearchFocused = true
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 12))
            .foregroundStyle(theme.inkTertiary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Effacer la recherche")
      }
    }
    .padding(.horizontal, Spacing.xs)
    .padding(.vertical, 6)
    .background {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(theme.room.opacity(theme.isDark ? 0.55 : 0.45))
    }
    .padding(.horizontal, Spacing.xs)
    .padding(.top, Spacing.xs)
    .padding(.bottom, Spacing.xxs)
    .background {
      // ⌘F pose le curseur dans le champ sans afficher de bouton.
      Button("") { isSearchFocused = true }
        .keyboardShortcut("f", modifiers: .command)
        .opacity(0)
        .accessibilityHidden(true)
    }
  }

  private var currentQueue: [Conversation] {
    if store.isShowingScheduled { return store.scheduledQueue }
    if store.isShowingArchived { return store.archivedQueue }
    return store.activeQueue + store.remindersQueue + store.requestsQueue
  }

  /// Vue « Programmés » (bouton du rail) : un fil par ligne, son prochain départ.
  @ViewBuilder
  private var scheduledSection: some View {
    if !store.scheduledQueue.isEmpty {
      Section("Programmés") {
        ForEach(store.scheduledQueue) { conversation in
          let scheduled = store.scheduledMessages(for: conversation.id)
          ScheduledConversationRow(
            conversation: conversation,
            scheduled: scheduled,
            theme: theme,
            typeface: themes.typeface
          )
          .contentShape(Rectangle())
          .onTapGesture { choose(conversation.id) }
          .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
          .listRowBackground(rowBackground(for: conversation.id))
          .contextMenu {
            Button("Ouvrir la discussion") {
              Task { await store.select(conversation.id) }
            }
            Divider()
            ForEach(scheduled) { message in
              if scheduled.count > 1 {
                Menu(SendLaterTime.label(for: message.sendAt)) {
                  ScheduledMessageMenu(message: message)
                }
              } else {
                ScheduledMessageMenu(message: message)
              }
            }
          }
        }
      }
    }
  }

  /// La rangée de pilules (⌘⇧Y) : ce que je veux voir maintenant.
  ///
  /// Cachée par défaut — la file se lit sans elle, et un filtre oublié est une
  /// file qui ment. Les quatre premières pilules disent l'état du fil, les
  /// suivantes son réseau (le rail ⌘1…⌘9 mène au même endroit, par un autre
  /// chemin : ici on choisit à la souris, là au clavier).
  private var filterRow: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 4) {
        ForEach(ConversationFilter.allCases.filter { $0 != .all }) { candidate in
          pill(
            label: candidate.labelFR,
            systemImage: candidate.systemImage,
            isOn: store.listFilter == candidate
          ) {
            store.setListFilter(candidate)
          }
        }

        if !connectedNetworks.isEmpty {
          Divider().frame(height: 14).overlay(theme.edge)
          ForEach(connectedNetworks) { network in
            pill(
              label: network.labelFR,
              systemImage: network.systemImage,
              isOn: store.networkFilter == network
            ) {
              store.setNetworkFilter(store.networkFilter == network ? nil : network)
            }
          }
        }
      }
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, 6)
    }
  }

  /// Les réseaux réellement branchés — une pilule pour un réseau muet n'aurait
  /// rien à filtrer.
  private var connectedNetworks: [MessageNetwork] {
    MessageNetwork.allCases.filter { store.hasConversations(on: $0) }
  }

  private func pill(
    label: String,
    systemImage: String,
    isOn: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Label(label, systemImage: systemImage)
        .font(Typography.meta(themes.typeface))
        .foregroundStyle(isOn ? theme.accentInk : theme.inkSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(isOn ? theme.accentFill : theme.paperSecondary.opacity(0.6)))
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isOn ? [.isSelected, .isButton] : .isButton)
  }

  /// Le pied de liste quand on coche : ce qu'on a désigné, et ce qu'on peut
  /// en faire d'un seul geste.
  private var selectionBar: some View {
    HStack(spacing: 8) {
      Text(selectionLabel)
        .font(Typography.meta(themes.typeface))
        .foregroundStyle(theme.inkSecondary)
      Spacer(minLength: 4)
      Button("Archiver") { Task { await store.archiveSelection() } }
      Button("Marquer lu") { Task { await store.markSelectionRead() } }
      Button("Muet") { store.muteSelection() }
      Button("Terminer") { store.clearSelection() }
    }
    .buttonStyle(.borderless)
    .font(Typography.meta(themes.typeface))
    .disabled(store.selectedConversationIDs.isEmpty)
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, 7)
    .background(theme.paperSecondary)
  }

  private var selectionLabel: String {
    let count = store.selectedConversationIDs.count
    if count == 0 { return "Choisir des fils" }
    return count == 1 ? "1 fil sélectionné" : "\(count) fils sélectionnés"
  }

  /// La rangée d'onglets — Images · Vidéos · Liens · Fichiers · Brouillons.
  /// Sans onglet on cherche des **conversations** ; avec, on cherche des
  /// **choses**. Le champ sert aux deux, c'est l'onglet qui change la question.
  /// Elle n'apparaît qu'en recherche : hors recherche, elle n'a rien à trier.
  @ViewBuilder
  private var facetRow: some View {
    if !store.searchQuery.isEmpty || store.searchFacet != nil {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 4) {
          ForEach(MessageFacet.allCases) { candidate in
            let selected = store.searchFacet == candidate
            Button {
              // Retaper l'onglet actif le referme : on revient aux conversations.
              store.setSearchFacet(selected ? nil : candidate)
            } label: {
              Label(candidate.labelFR, systemImage: candidate.systemImage)
                .font(Typography.meta(themes.typeface))
                .foregroundStyle(selected ? theme.accentInk : theme.inkSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                  Capsule().fill(selected ? theme.accentFill : theme.paperSecondary.opacity(0.6))
                )
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
          }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, 6)
      }
    }
  }

  /// Les messages d'un onglet, dans leur fil. Un clic ouvre la conversation.
  @ViewBuilder
  private func facetSection(_ facet: MessageFacet) -> some View {
    let hits = store.facetHits
    if hits.isEmpty {
      Text("Rien en « \(facet.labelFR) ».")
        .font(Typography.meta(themes.typeface))
        .foregroundStyle(theme.inkTertiary)
        .padding(.vertical, Spacing.sm)
    } else {
      Section(facet.labelFR) {
        ForEach(hits) { hit in
          Button {
            choose(hit.conversation.id)
          } label: {
            VStack(alignment: .leading, spacing: 2) {
              HStack(spacing: 5) {
                Image(systemName: hit.conversation.network.systemImage)
                  .font(.system(size: 9))
                Text(hit.conversation.title).fontWeight(.semibold)
                Spacer(minLength: 4)
                Text(hit.message.sentAt, style: .date)
                  .monospacedDigit()
              }
              .font(Typography.meta(themes.typeface))
              .foregroundStyle(theme.inkTertiary)
              Text(hit.message.sidebarPreviewText)
                .font(Typography.meta(themes.typeface))
                .foregroundStyle(theme.inkSecondary)
                .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      }
    }
  }

  /// Bascule permanente en pied de liste : l'archive est une vue, pas un dossier caché.
  private var archiveToggle: some View {
    Button {
      store.setShowingArchived(!store.isShowingArchived)
    } label: {
      HStack(spacing: 6) {
        Image(systemName: store.isShowingArchived ? "tray.full" : "archivebox")
          .font(.system(size: 11))
        Text(store.isShowingArchived ? "Retour à l’inbox" : "Archivés")
          .font(Typography.meta(themes.typeface))
        Spacer()
        if !store.isShowingArchived, !store.archivedQueue.isEmpty {
          Text("\(store.archivedQueue.count)")
            .font(Typography.meta(themes.typeface))
            .foregroundStyle(theme.inkTertiary)
        }
      }
      .foregroundStyle(theme.inkSecondary)
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, 7)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(store.isShowingArchived ? "Revenir à l’inbox" : "Voir les fils archivés")
  }

  private var emptyState: some View {
    VStack(spacing: Spacing.xs) {
      Text(emptyStateTitle)
        .font(Typography.emptyState(themes.typeface))
        .foregroundStyle(theme.inkSecondary)
      if store.networkFilter != nil {
        Button("Voir tous les réseaux") { store.setNetworkFilter(nil) }
          .buttonStyle(.link)
      }
    }
    .padding(Spacing.md)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var emptyStateTitle: String {
    if store.isShowingScheduled { return "Rien de programmé." }
    if store.isShowingArchived { return "Rien d’archivé." }
    return store.networkFilter.map { "Rien sur \($0.labelFR)." } ?? "Rien à traiter."
  }

  @ViewBuilder
  private func section(title: String, items: [Conversation]) -> some View {
    if !items.isEmpty {
      Section(title) {
        ForEach(items) { conversation in
          row(conversation)
        }
      }
    }
  }

  private func row(_ conversation: Conversation) -> some View {
    HStack(spacing: Spacing.xs) {
      // La case ne paraît qu'en sélection multiple : le reste du temps, la
      // ligne n'a rien à cocher et récupère toute sa largeur.
      if store.isSelectionMode {
        Image(systemName: store.isSelected(conversation.id) ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 15))
          .foregroundStyle(store.isSelected(conversation.id) ? theme.accent : theme.inkTertiary)
          .padding(.leading, Spacing.xs)
      }
      ConversationRowView(
        conversation: conversation,
        theme: theme,
        typeface: themes.typeface,
        isSyncing: store.isInitialSync || store.isLoading || store.isLiveSyncing,
        isPinned: store.isPinned(conversation.id),
        isMuted: store.isMuted(conversation.id)
      )
    }
    .contentShape(Rectangle())
    .onTapGesture { choose(conversation.id) }
    .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
    .listRowBackground(rowBackground(for: conversation.id))
    .accessibilityAddTraits(
      store.isSelectionMode && store.isSelected(conversation.id) ? .isSelected : []
    )
    .contextMenu {
      conversationContextMenu(conversation)
    }
  }

  /// Le fond de la ligne choisie : le papier mêlé d'un peu d'accent, posé
  /// nous-mêmes pour que la couleur ne dépende d'aucune humeur d'AppKit.
  @ViewBuilder
  private func rowBackground(for id: String) -> some View {
    if id == store.selectedConversationID {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(theme.selection)
        .padding(.horizontal, 6)
    } else {
      Color.clear
    }
  }

  /// « Me le rappeler » : la conversation sort de la file jusqu'à l'heure dite,
  /// et y revient d'elle-même — ou plus tôt si l'autre répond. Les heures
  /// proposées sont celles d'« Envoyer plus tard » : mêmes mots, même question.
  @ViewBuilder
  private func reminderMenu(_ conversation: Conversation) -> some View {
    if let rappel = store.reminder(conversation.id) {
      Button("Remettre dans la file (de côté jusqu’à \(rappel.labelFR()))") {
        store.setReminder(nil, conversationID: conversation.id)
      }
    } else {
      Menu("Me le rappeler…") {
        ForEach(ConversationReminder.suggestions()) { suggestion in
          Button(suggestion.title) {
            store.setReminder(suggestion.date, conversationID: conversation.id)
          }
        }
      }
    }
  }

  @ViewBuilder
  private func conversationContextMenu(_ conversation: Conversation) -> some View {
    Button("Ouvrir la discussion") {
      Task { await store.select(conversation.id) }
    }

    Button("Détacher la conversation") {
      store.detach(conversationID: conversation.id)
    }

    Button(store.isSelectionMode ? "Quitter la sélection" : "Sélectionner plusieurs fils") {
      store.toggleSelectionMode()
      if store.isSelectionMode { store.toggleSelection(conversation.id) }
    }

    Button(store.isArchived(conversation.id) ? "Désarchiver" : "Archiver") {
      Task { await store.toggleArchived(conversationID: conversation.id) }
    }

    reminderMenu(conversation)

    if store.isRequest(conversation.id) {
      Divider()
      Button("Accepter la demande") {
        Task { await store.decideRequest(.accepted, conversationID: conversation.id) }
      }
      Button("Refuser la demande", role: .destructive) {
        Task { await store.decideRequest(.declined, conversationID: conversation.id) }
      }
    }

    Divider()

    if conversation.network.livesOnRelay {
      Button(conversation.hasUnread ? "Marquer comme lu" : "Marquer comme non lu") {
        if conversation.hasUnread {
          Task { await store.select(conversation.id) }
        } else {
          store.markUnread(conversationID: conversation.id)
        }
      }

      Button(store.isPinned(conversation.id) ? "Désépingler la discussion" : "Épingler la discussion") {
        store.togglePinned(conversationID: conversation.id)
      }

      Button(store.isMuted(conversation.id) ? "Réactiver les notifications" : "Couper les notifications") {
        store.toggleMuted(conversationID: conversation.id)
      }

      if conversation.isGroup, conversation.network.bridge?.relaysGroupLeave == true {
        Button("Quitter le groupe…", role: .destructive) {
          pendingLeaveID = conversation.id
        }
      }
    } else {
      Button(conversation.hasUnread ? "Marquer comme lu" : "Marquer comme non lu") {
        if conversation.hasUnread {
          Task { await store.select(conversation.id) }
        } else {
          store.markUnread(conversationID: conversation.id)
        }
      }
      Button(store.isPinned(conversation.id) ? "Désépingler" : "Épingler") {
        store.togglePinned(conversationID: conversation.id)
      }
    }
  }
}

private enum DisappearingOption: Int, CaseIterable, Identifiable {
  case off = 0
  case thirtySeconds = 30
  case fiveMinutes = 300
  case oneHour = 3_600
  case oneDay = 86_400
  case oneWeek = 604_800
  case fourWeeks = 2_419_200

  var id: Int { rawValue }
  var seconds: Int { rawValue }

  var titleFR: String {
    switch self {
    case .off: "Désactivés"
    case .thirtySeconds: "30 secondes"
    case .fiveMinutes: "5 minutes"
    case .oneHour: "1 heure"
    case .oneDay: "1 jour"
    case .oneWeek: "1 semaine"
    case .fourWeeks: "4 semaines"
    }
  }
}
