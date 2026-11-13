import CorrespondanceCore
import CorrespondanceUI
import SwiftUI

/// L'écran par défaut de l'iPhone (décision 9).
///
/// Le titre nomme la portée — Inbox, Archive, ou le réseau choisi — et ne
/// s'ouvre pas : la portée se change dans la barre d'onglets. Le filtre (Tous /
/// Non lus / Sans réponse / Brouillons / Groupes) tient dans un bouton de la
/// barre, comme celui de Mail ; il ne prend une ligne sous le titre que
/// lorsqu'il est actif, pour dire ce qu'on regarde et s'enlever d'un tap. Une
/// rangée de jetons à demeure coûtait une ligne de file sur les trois ou
/// quatre que montre l'écran extérieur de l'iPhone Duo. Un menu « … » pour ce
/// qui n'est ni un onglet ni un filtre : le réseau, les listes de
/// vérification (Demandes, Rappels, Programmés), la note à soi, le balayage,
/// les Réglages. Entre les deux, la file, épinglées en tête.
struct InboxListView: View {
  /// La portée de cette liste — fixée par l'onglet qui la porte, ou par la
  /// feuille qui la pousse (Demandes, Rappels).
  let scope: InboxScope
  /// Ouverte en feuille depuis le menu : taper une ligne la referme.
  var dismissesOnOpen = false

  @Environment(RelayStore.self) private var store
  @Environment(ThemePreferences.self) private var themes
  @Environment(PushRegistration.self) private var push

  @State private var isComposingNew = false
  @State private var isShowingScheduled = false
  @State private var isShowingSettings = false
  @State private var isSearching = false
  /// Une liste de vérification poussée en feuille : Demandes ou Rappels.
  @State private var checklist: InboxScope?
  /// Le balayage de fin de journée se demande une fois, avec son compte.
  @State private var confirmsArchiveAllRead = false
  @Environment(\.dismiss) private var dismiss

  /// Remis à neuf à chaque retour dans l'app (cf. `ThreadView.toolbarEpoch`). Sur l'écran extérieur de l'iPhone
  /// Duo, iOS range les boutons de la barre dans une bande à droite, et au
  /// retour de l'arrière-plan ils y restaient parfois vides — la capsule est
  /// là, l'icône non (capture du 13 nov. 2026). Leur donner une identité neuve
  /// force la barre à les reposer. Parade à l'aveugle : la cause est chez iOS.
  @State private var toolbarEpoch = 0
  @Environment(\.scenePhase) private var scenePhase

  private var theme: WritingTheme { themes.theme }
  private var typeface: WritingTypeface { themes.typeface }

  var body: some View {
    @Bindable var store = store
    let list = store.conversations(in: scope)
    let sections = InboxOrdering.sections(list, state: store.viewState)

    return Group {
        if list.isEmpty {
          if !store.isRestoring { emptyState }
        } else {
          List(selection: $store.selectedConversationID) {
            if !sections.pinned.isEmpty {
              Section {
                pinnedRows(sections.pinned)
              } header: {
                sectionHeader(String(localized: "Épinglées"))
              }
            }
            Section {
              ForEach(sections.others) { row($0) }
            } header: {
              if !sections.pinned.isEmpty { sectionHeader(scope.labelFR) }
            }
          }
          .listStyle(.plain)
          .scrollContentBackground(.hidden)
          .environment(\.defaultMinListRowHeight, 0)
        }
      }
      .background(theme.paper.ignoresSafeArea())
    .navigationTitle("")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarLeading) { titleLabel }
        .plainToolbarItem()
      if dismissesOnOpen {
        ToolbarItem(placement: .topBarTrailing) { Button("Fermer") { dismiss() } }
      } else {
        ToolbarItemGroup(placement: .topBarTrailing) {
          if scope == .inbox || scope == .archive { filterMenu.id(toolbarEpoch) }
          moreMenu.id(toolbarEpoch)
          newConversationButton.id(toolbarEpoch)
        }
      }
    }
    .toolbarBackground(theme.paper, for: .navigationBar)
    .safeAreaInset(edge: .top, spacing: 0) {
      VStack(spacing: 0) {
        syncBanner
        if scope == .inbox || scope == .archive, store.filter != .all { activeFilterChip }
      }
      .background(theme.paper)
    }
    .sheet(isPresented: $isSearching) {
      SearchSheet()
        .environment(store)
        .environment(themes)
    }
    .sheet(item: $checklist) { scope in
      NavigationStack {
        InboxListView(scope: scope, dismissesOnOpen: true)
      }
      .environment(store)
      .environment(themes)
      .environment(push)
      .tint(theme.accent)
    }
    .sheet(isPresented: $isComposingNew) {
      NewConversationSheet()
        .environment(store)
        .environment(themes)
    }
    .sheet(isPresented: $isShowingScheduled) {
      ScheduledMessagesView()
        .environment(store)
        .environment(themes)
    }
    .sheet(isPresented: $isShowingSettings) {
      SettingsView()
        .environment(store)
        .environment(themes)
        .environment(push)
    }
    .confirmationDialog(
      ArchiveSweep.confirmationFR(count: store.readArchivableConversations.count),
      isPresented: $confirmsArchiveAllRead,
      titleVisibility: .visible
    ) {
      Button("Archiver") { store.archiveAllRead() }
      Button("Annuler", role: .cancel) {}
    } message: {
      Text("Les fils épinglés et les non lus restent dans la file. Un nouveau message ramène un fil archivé.")
    }
    .task { openDemoSheetIfRequested() }
    .onChange(of: scenePhase) { _, phase in
        guard phase == .active else { return }
        toolbarEpoch += 1
        // Une seconde fois, la transition de retour finie : c'est pendant
        // elle que la bande se vide.
        Task { @MainActor in
          try? await Task.sleep(for: .milliseconds(450))
          toolbarEpoch += 1
        }
      }
  }

  /// En démonstration, la feuille demandée s'ouvre seule — une capture n'a pas
  /// de doigt. Cf. `RootView.openDemoScreenIfRequested`.
  private func openDemoSheetIfRequested() {
    guard store.isDemo else { return }
    switch DemoRelay.requestedScreen {
    case .nouvelle: isComposingNew = true
    case .recherche: isSearching = true
    case .reglages: isShowingSettings = true
    default: break
    }
  }

  // MARK: - Lignes

  /// Les épinglées se rangent à la main depuis iOS 27 : un appui long soulève
  /// la ligne, on la pose où on veut, et l'ordre reste (`RelayStore.pinnedOrder`).
  /// Avant iOS 27, la section est la même, dans l'ordre de la date.
  @ViewBuilder
  private func pinnedRows(_ pinned: [Conversation]) -> some View {
    if #available(iOS 27.0, *) {
      ForEach(pinned) { row($0) }
        .reorderable()
        .reorderContainer(for: Conversation.self) { difference in
          let before: String? =
            switch difference.destination.position {
            case .before(let id): id
            case .end: nil
            }
          store.movePinned(visible: pinned.map(\.id), moving: difference.sources, before: before)
        }
    } else {
      ForEach(pinned) { row($0) }
    }
  }

  @ViewBuilder
  private func row(_ conversation: Conversation) -> some View {
    ConversationRow(
      conversation: conversation,
      theme: theme,
      typeface: typeface,
      isPinned: store.isPinned(conversation.id),
      isMuted: store.isMuted(conversation.id),
      draft: store.draftText(conversation.id).trimmingCharacters(in: .whitespacesAndNewlines)
    )
    .listRowInsets(EdgeInsets())
    .listRowSeparatorTint(theme.edge.opacity(0.5))
    .listRowBackground(
      store.selectedConversationID == conversation.id ? theme.selection : Color.clear
    )
    .tag(conversation.id)
    // La ligne paraît : sa page locale se charge déjà, pour que le fil
    // s'ouvre plein plutôt que vide puis rempli.
    .task { await store.warm(conversationID: conversation.id) }
    .onTapGesture { open(conversation.id) }
    // Balayage à droite : archiver — le geste qui vide la file.
    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
      Button {
        store.toggleArchived(conversation.id)
      } label: {
        Label(
          store.isArchived(conversation.id) ? String(localized: "Désarchiver") : String(localized: "Archiver"),
          systemImage: store.isArchived(conversation.id) ? "tray.and.arrow.up" : "archivebox"
        )
      }
      .tint(theme.accent)
    }
    // Balayage à gauche : épingler et muet, les deux autres décisions.
    .swipeActions(edge: .leading, allowsFullSwipe: false) {
      Button {
        store.togglePinned(conversation.id)
      } label: {
        Label(
          store.isPinned(conversation.id) ? String(localized: "Désépingler") : String(localized: "Épingler"),
          systemImage: store.isPinned(conversation.id) ? "pin.slash" : "pin"
        )
      }
      .tint(theme.accentSoft)

      Button {
        store.toggleMuted(conversation.id)
      } label: {
        Label(
          store.isMuted(conversation.id) ? String(localized: "Réactiver") : String(localized: "Muet"),
          systemImage: store.isMuted(conversation.id) ? "bell" : "bell.slash"
        )
      }
      .tint(theme.inkTertiary)
    }
    .contextMenu {
      if conversation.hasUnread {
        Button {
          Task { await store.markRead(conversationID: conversation.id) }
        } label: {
          Label("Marquer comme lu", systemImage: "envelope.open")
        }
      }
      reminderMenu(conversation)
      requestMenu(conversation)
    }
  }

  /// Accepter ou refuser une demande. Accepter la fait entrer dans la file ;
  /// refuser la range, et elle ne redemandera plus.
  @ViewBuilder
  private func requestMenu(_ conversation: Conversation) -> some View {
    if store.isRequest(conversation.id) {
      Section("Demande") {
        Button {
          store.decideRequest(.accepted, conversationID: conversation.id)
        } label: {
          Label("Accepter", systemImage: "checkmark.circle")
        }
        Button(role: .destructive) {
          store.decideRequest(.declined, conversationID: conversation.id)
        } label: {
          Label("Refuser", systemImage: "xmark.circle")
        }
      }
    }
  }

  /// « Me le rappeler » : la conversation quitte la file jusqu'à l'heure dite,
  /// et y revient d'elle-même — ou plus tôt si l'autre répond. Les heures
  /// proposées sont celles d'« Envoyer plus tard » : mêmes mots, même question.
  @ViewBuilder
  private func reminderMenu(_ conversation: Conversation) -> some View {
    if let rappel = store.reminder(conversation.id) {
      Section("De côté jusqu'à \(rappel.labelFR())") {
        Button {
          store.setReminder(nil, conversationID: conversation.id)
        } label: {
          Label("Remettre dans la file", systemImage: "tray.and.arrow.down")
        }
      }
    } else {
      Menu {
        ForEach(ConversationReminder.suggestions()) { suggestion in
          Button(suggestion.title) {
            store.setReminder(suggestion.date, conversationID: conversation.id)
          }
        }
      } label: {
        Label("Me le rappeler…", systemImage: "clock.arrow.circlepath")
      }
    }
  }

  private func open(_ id: String) {
    store.selectedConversationID = id
    Task { await store.open(conversationID: id) }
    if dismissesOnOpen { dismiss() }
  }

  /// Le titre est un titre : il nomme la portée et ne s'ouvre pas.
  private var titleLabel: some View {
    HStack(spacing: 8) {
      Text(title)
        .font(Typography.letterHeading(typeface, 24))
        .foregroundStyle(theme.ink)
        .fixedSize()
        .accessibilityAddTraits(.isHeader)
      // L'incognito se voit : un œil barré à côté du titre, tant qu'il dure.
      if store.isIncognito {
        Image(systemName: "eye.slash")
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(theme.inkTertiary)
          .accessibilityLabel("Mode incognito actif")
      }
    }
  }

  /// Le titre nomme la portée, ou le réseau quand un seul est choisi.
  private var title: String {
    if scope == .inbox || scope == .archive, let network = store.networkFilter {
      return network.labelFR
    }
    return scope.labelFR
  }

  private func sectionHeader(_ title: String) -> some View {
    Text(title.uppercased())
      .font(Typography.sidebarSection(typeface))
      .kerning(0.6)
      .foregroundStyle(theme.inkTertiary)
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, 4)
      .frame(maxWidth: .infinity, alignment: .leading)
      .listRowInsets(EdgeInsets())
      .background(theme.paper)
  }

  // MARK: - Chrome

  /// Les filtres qu'on propose : « Programmés » a sa propre feuille.
  private var filterChoices: [ConversationFilter] {
    ConversationFilter.allCases.filter { $0 != .scheduled }
  }

  /// Le filtre, dans la barre : un bouton, plein quand un filtre est posé.
  private var filterMenu: some View {
    Menu {
      Picker("Filtrer", selection: Binding(
        get: { store.filter },
        set: { new in withAnimation(.easeOut(duration: 0.16)) { store.filter = new } }
      )) {
        ForEach(filterChoices) { candidate in
          Label(
            candidate == .unread && unreadInScope > 0
              ? String(localized: "\(candidate.labelFR) (\(unreadInScope))") : candidate.labelFR,
            systemImage: candidate.systemImage
          )
          .tag(candidate)
        }
      }
    } label: {
      // Une étiquette nue, sans fonte ni couleur à nous : la barre en fait un
      // vrai bouton du système, qu'elle sait ranger dans sa bande latérale.
      Label(
        "Filtrer",
        systemImage: store.filter == .all
          ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill"
      )
    }
    .accessibilityValue(store.filter.labelFR)
  }

  /// Le filtre posé, sous le titre : ce qu'on regarde, et la croix qui l'enlève.
  /// Absent sans filtre — la file commence alors sous la barre.
  private var activeFilterChip: some View {
    Button {
      withAnimation(.easeOut(duration: 0.16)) { store.filter = .all }
    } label: {
      HStack(spacing: 5) {
        Text(store.filter.labelFR)
        if store.filter == .unread, unreadInScope > 0 {
          Text("\(unreadInScope)")
            .monospacedDigit()
            .opacity(0.85)
        }
        Image(systemName: "xmark")
          .font(.system(size: 9, weight: .bold))
          .opacity(0.7)
      }
      .font(Typography.meta(typeface))
      .fontWeight(.semibold)
      .foregroundStyle(theme.accentInk)
      .padding(.horizontal, 10)
      .padding(.vertical, 4)
      .background(Capsule().fill(theme.accentFill))
      // La cible reste confortable, la ligne reste mince.
      .contentShape(Rectangle().inset(by: -8))
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Retirer le filtre \(store.filter.labelFR)")
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, Spacing.md)
    .padding(.bottom, 6)
  }

  private var unreadInScope: Int {
    store.conversations(in: scope).filter(\.hasUnread).count
  }

  /// Le menu « … » : un seul endroit pour ce qui n'est ni un onglet ni un
  /// filtre. Comme Mail et Notes.
  private var moreMenu: some View {
    Menu {
      Picker("Réseau", selection: Binding(
        get: { store.networkFilter },
        set: { store.networkFilter = $0 }
      )) {
        Label("Tous les réseaux", systemImage: "square.stack.3d.up").tag(MessageNetwork?.none)
        ForEach(store.networksInUse) { network in
          Label(network.labelFR, systemImage: network.systemImage)
            .tag(MessageNetwork?.some(network))
        }
      }
      Divider()
      checklistButton(.requests, count: store.conversations(in: .requests).count)
      checklistButton(.reminders, count: store.conversations(in: .reminders).count)
      Button {
        isShowingScheduled = true
      } label: {
        Label(
          store.scheduled.isEmpty ? String(localized: "Programmés")
            : String(localized: "Programmés (\(store.scheduled.count))"),
          systemImage: "clock"
        )
      }
      Divider()
      Button {
        Task { await store.openSelfNote() }
      } label: {
        Label(MessageNetwork.selfNote.labelFR, systemImage: MessageNetwork.selfNote.systemImage)
      }
      Button {
        confirmsArchiveAllRead = true
      } label: {
        Label("Archiver tout ce qui est lu…", systemImage: "archivebox")
      }
      .disabled(store.readArchivableConversations.isEmpty)
      Divider()
      // Comme Beeper : lire sans accusé de lecture, répondre à son rythme.
      Toggle(isOn: Binding(
        get: { store.isIncognito },
        set: { store.isIncognito = $0 }
      )) {
        Label("Mode incognito", systemImage: "eye.slash")
      }
      Divider()
      Button {
        isShowingSettings = true
      } label: {
        Label("Réglages", systemImage: "gearshape")
      }
    } label: {
      Label("Plus", systemImage: "ellipsis.circle")
    }
  }

  private func checklistButton(_ scope: InboxScope, count: Int) -> some View {
    Button {
      checklist = scope
    } label: {
      Label(
        count == 0 ? scope.labelFR : String(localized: "\(scope.labelFR) (\(count))"),
        systemImage: scope.systemImage
      )
    }
  }

  private var newConversationButton: some View {
    Button {
      isComposingNew = true
    } label: {
      Label("Nouvelle conversation", systemImage: "square.and.pencil")
    }
  }

  @ViewBuilder
  private var syncBanner: some View {
    if let error = store.syncError {
      HStack(spacing: 6) {
        Image(systemName: "antenna.radiowaves.left.and.right.slash")
        Text(error)
          .lineLimit(2)
        Spacer(minLength: 0)
      }
      .font(Typography.meta(typeface))
      .foregroundStyle(theme.ink)
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, 6)
      .background(theme.accentSoft.opacity(0.2))
      .accessibilityLabel("Relais injoignable. \(error)")
    }
  }

  // MARK: - Vide

  private var emptyState: some View {
    VStack(spacing: Spacing.sm) {
      Image(systemName: emptyIcon)
        .font(.system(size: 34, weight: .light))
        .foregroundStyle(theme.inkTertiary)
      Text(emptyTitle)
        .font(Typography.emptyState(typeface))
        .foregroundStyle(theme.inkSecondary)
        .multilineTextAlignment(.center)
      if store.syncError != nil {
        Text("Le Relais ne répond pas. Vérifie Tailscale.")
          .font(Typography.meta(typeface))
          .foregroundStyle(theme.inkTertiary)
      }
    }
    .padding(Spacing.lg)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var emptyIcon: String {
    if store.filter != .all { return store.filter.systemImage }
    return scope == .inbox ? "tray" : scope.systemImage
  }

  private var emptyTitle: String {
    if store.filter != .all { return String(localized: "Rien en « \(store.filter.labelFR) »") }
    if let network = store.networkFilter { return String(localized: "Aucune conversation \(network.labelFR)") }
    switch scope {
    case .inbox: return String(localized: "Vous êtes à jour")
    case .archive: return String(localized: "L'archive est vide")
    case .reminders: return String(localized: "Rien de mis de côté")
    case .requests: return String(localized: "Aucune demande")
    }
  }
}

extension ToolbarItem where ID == Void, Content: View {
  /// Un titre n'est pas un bouton : pas de capsule de verre derrière lui.
  /// iOS 26 en pose une par défaut sous chaque élément de la barre.
  @ToolbarContentBuilder
  func plainToolbarItem() -> some ToolbarContent {
    if #available(iOS 26.0, *) {
      sharedBackgroundVisibility(.hidden)
    } else {
      self
    }
  }
}
