import CorrespondanceCore
import CorrespondanceUI
import SwiftUI

/// L'écran par défaut de l'iPhone (décision 9).
///
/// Le titre nomme la portée — Inbox, Archive, ou le réseau choisi — et ne
/// s'ouvre pas : la portée se change dans la barre d'onglets. Sous le titre, le
/// filtre en jetons (Tous / Non lus / Sans réponse / Brouillons / Groupes),
/// comme les catégories de Mail. En haut à droite, un seul menu « … » pour ce
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

  private var theme: WritingTheme { themes.theme }
  private var typeface: WritingTypeface { themes.typeface }

  var body: some View {
    @Bindable var store = store
    let list = store.conversations(in: scope)
    let sections = InboxOrdering.sections(list, state: store.viewState)

    return Group {
        if list.isEmpty {
          emptyState
        } else {
          List(selection: $store.selectedConversationID) {
            if !sections.pinned.isEmpty {
              Section {
                ForEach(sections.pinned) { row($0) }
              } header: {
                sectionHeader("Épinglées")
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
          moreMenu
          newConversationButton
        }
      }
    }
    .toolbarBackground(theme.paper, for: .navigationBar)
    .safeAreaInset(edge: .top, spacing: 0) {
      VStack(spacing: 0) {
        syncBanner
        if scope == .inbox || scope == .archive { filterChips }
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
    .onTapGesture { open(conversation.id) }
    // Balayage à droite : archiver — le geste qui vide la file.
    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
      Button {
        store.toggleArchived(conversation.id)
      } label: {
        Label(
          store.isArchived(conversation.id) ? "Désarchiver" : "Archiver",
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
          store.isPinned(conversation.id) ? "Désépingler" : "Épingler",
          systemImage: store.isPinned(conversation.id) ? "pin.slash" : "pin"
        )
      }
      .tint(theme.accentSoft)

      Button {
        store.toggleMuted(conversation.id)
      } label: {
        Label(
          store.isMuted(conversation.id) ? "Réactiver" : "Muet",
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

  /// Le filtre, en jetons sous le titre : visible, un tap. Le jeton actif
  /// porte son compte quand il en a un.
  private var filterChips: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 6) {
        ForEach(ConversationFilter.allCases.filter { $0 != .scheduled }) { candidate in
          let selected = store.filter == candidate
          Button {
            withAnimation(.easeOut(duration: 0.16)) { store.filter = candidate }
          } label: {
            HStack(spacing: 5) {
              Text(candidate.labelFR)
              if candidate == .unread, unreadInScope > 0 {
                Text("\(unreadInScope)")
                  .monospacedDigit()
                  .opacity(0.85)
              }
            }
            .font(Typography.meta(typeface))
            .fontWeight(selected ? .semibold : .regular)
            .foregroundStyle(selected ? theme.accentInk : theme.inkSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
              Capsule().fill(selected ? theme.accentFill : theme.paperSecondary.opacity(0.7))
            )
            .overlay(Capsule().strokeBorder(selected ? Color.clear : theme.edge.opacity(0.6)))
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Filtre \(candidate.labelFR)")
          .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        }
      }
      .padding(.horizontal, Spacing.md)
      .padding(.top, 2)
      .padding(.bottom, Spacing.xs)
    }
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
          store.scheduled.isEmpty ? "Programmés" : "Programmés (\(store.scheduled.count))",
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
      Image(systemName: "ellipsis.circle")
        .font(.system(size: 17, weight: .medium))
    }
    .accessibilityLabel("Plus")
  }

  private func checklistButton(_ scope: InboxScope, count: Int) -> some View {
    Button {
      checklist = scope
    } label: {
      Label(
        count == 0 ? scope.labelFR : "\(scope.labelFR) (\(count))",
        systemImage: scope.systemImage
      )
    }
  }

  private var newConversationButton: some View {
    Button {
      isComposingNew = true
    } label: {
      Image(systemName: "square.and.pencil")
        .font(.system(size: 17, weight: .medium))
    }
    .accessibilityLabel("Nouvelle conversation")
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
    if store.filter != .all { return "Rien en « \(store.filter.labelFR) »" }
    if let network = store.networkFilter { return "Aucune conversation \(network.labelFR)" }
    switch scope {
    case .inbox: return "Vous êtes à jour"
    case .archive: return "L'archive est vide"
    case .reminders: return "Rien de mis de côté"
    case .requests: return "Aucune demande"
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
