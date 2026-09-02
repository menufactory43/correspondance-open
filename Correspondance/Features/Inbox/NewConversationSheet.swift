import SwiftUI
import CorrespondanceCore
import CorrespondanceUI

/// Nouvelle conversation : on choisit **quelqu'un**, puis **par où**.
///
/// La liste est faite de personnes, pas de réseaux. Chaque ligne porte, à
/// droite, les réseaux où cette personne est joignable : un fil qui existe
/// (plein), ou un fil qu'on peut ouvrir avec un numéro qu'on lui connaît
/// (cerné). Un clic sur la ligne prend le premier ; un clic sur une pastille
/// prend celui-là. Les puces du haut ne sont qu'un filtre : « WhatsApp » ne
/// montre que les gens qu'on peut joindre sur WhatsApp — jamais un contact
/// d'un autre réseau qui n'y mènerait nulle part.
struct NewConversationSheet: View {
  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes
  @Environment(\.dismiss) private var dismiss

  @State private var filter: MessageNetwork?
  @State private var query = ""
  @State private var bookHits: [ContactDirectory.DirectoryHit] = []
  @State private var isCreatingGroup = false
  @FocusState private var isFieldFocused: Bool

  private var theme: WritingTheme { themes.theme }
  private var typeface: WritingTypeface { themes.typeface }

  private var trimmedQuery: String {
    query.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: - Ce qu'on peut joindre

  /// Les réseaux où un fil neuf s'ouvre depuis un numéro ou une adresse.
  private var freshNetworks: [MessageNetwork] {
    ReachablePeople.freshNetworks(isMatrixConnected: store.isMatrixConnected, inUse: store.hasConversations(on:))
  }

  /// Les puces : iMessage, puis les réseaux bridgés qui ont déjà un fil.
  private var filterNetworks: [MessageNetwork] {
    var networks: [MessageNetwork] = [.iMessage]
    if store.isMatrixConnected {
      networks += MessageNetwork.matrixBridged.filter(store.hasConversations(on:))
    }
    return networks
  }

  private var everyone: [ReachablePerson] {
    ReachablePeople.build(
      conversations: store.conversations,
      members: store.memberConversations(of:),
      book: bookHits,
      freshNetworks: freshNetworks
    )
  }

  private var people: [ReachablePerson] {
    ReachablePeople.filter(everyone, network: filter)
      .filter { ReachablePeople.matches($0, query: trimmedQuery) }
  }

  private var knownPeople: [ReachablePerson] { people.filter(\.isKnownOnRelay) }
  private var bookPeople: [ReachablePerson] { people.filter { !$0.isKnownOnRelay } }

  /// Les agents du Relais, comme des contacts : un tête-à-tête s'ouvre d'un clic.
  private var agents: [String] {
    guard store.isMatrixConnected, filter == nil else { return [] }
    let q = trimmedQuery.lowercased()
    return store.agentDirectory.filter { q.isEmpty || $0.lowercased().contains(q) }
  }

  private var showsSelfNote: Bool {
    guard store.isMatrixConnected, filter == nil else { return false }
    let q = trimmedQuery.lowercased()
    return q.isEmpty || "note à soi".contains(q) || "note a soi".contains(q)
  }

  /// Ce qu'on tape, quand c'est un identifiant reconnaissable et qu'aucune
  /// ligne ne le porte déjà : un fil à ouvrir, sur les réseaux qui savent.
  private struct Freeform {
    var identifier: String
    var networks: [MessageNetwork]
  }

  private var freeform: Freeform? {
    let value = trimmedQuery
    guard !value.isEmpty else { return nil }
    guard !people.contains(where: { person in
      person.reaches.contains { $0.handle.caseInsensitiveCompare(value) == .orderedSame }
        || (PhoneNormalizer.identityKey(for: value) != nil
          && person.reaches.contains { PhoneNormalizer.identityKey(for: $0.handle) == PhoneNormalizer.identityKey(for: value) })
    }) else { return nil }

    if let phone = PhoneNormalizer.e164(value) {
      let networks = freshNetworks.filter { filter == nil || $0 == filter }
      return networks.isEmpty ? nil : Freeform(identifier: phone, networks: networks)
    }
    if value.contains("@"), !value.hasPrefix("@"), value.contains(".") {
      guard filter == nil || filter == .iMessage else { return nil }
      return Freeform(identifier: value.lowercased(), networks: [.iMessage])
    }
    // Un pseudo : Instagram ou Messenger, et seulement quand on l'a choisi —
    // deviner qu'un mot est un pseudo plutôt qu'un nom mal tapé, c'est deviner.
    if let filter, filter == .instagram || filter == .messenger {
      let bare = value.hasPrefix("@") ? String(value.dropFirst()) : value
      guard !bare.isEmpty, !bare.contains(" "), !bare.contains("@") else { return nil }
      return Freeform(identifier: bare, networks: [filter])
    }
    return nil
  }

  // MARK: - Vue

  var body: some View {
    VStack(spacing: 0) {
      header
      searchField
      filterChips
      Divider().overlay(theme.edge)
      results
    }
    .frame(width: 560, height: 640)
    .background(theme.paper)
    .task {
      isFieldFocused = true
      await store.refreshAgentDirectory()
      await refreshBook()
    }
    .onChange(of: query) { _, _ in
      Task { await refreshBook() }
    }
    .onChange(of: store.isMatrixConnected) { _, connected in
      if !connected, let filter, filter.isMatrixBridged { self.filter = nil }
    }
    .sheet(isPresented: $isCreatingGroup) {
      NewGroupSheet()
        .environment(store)
        .environment(themes)
    }
  }

  private var header: some View {
    HStack(spacing: Spacing.sm) {
      Text("Nouvelle conversation")
        .font(Typography.letterHeading(typeface, 17))
        .foregroundStyle(theme.ink)
      Spacer()
      // « Écrire à plusieurs » est la même intention qu'« écrire à quelqu'un » :
      // le geste vit ici. Absent si aucun pont branché ne sait le faire.
      if store.canCreateGroup {
        Button("Nouveau groupe…") { isCreatingGroup = true }
      }
      Button("Fermer") { dismiss() }
        .keyboardShortcut(.cancelAction)
    }
    .padding(.horizontal, Spacing.md)
    .padding(.top, Spacing.md)
    .padding(.bottom, Spacing.sm)
  }

  private var searchField: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(theme.inkTertiary)
      TextField(
        "",
        text: $query,
        prompt: Text(placeholder).foregroundStyle(theme.inkTertiary)
      )
      .textFieldStyle(.plain)
      .font(Typography.composer(typeface))
      .foregroundStyle(theme.ink)
      .focused($isFieldFocused)
      .onSubmit(openFirst)
      if !query.isEmpty {
        Button {
          query = ""
        } label: {
          Image(systemName: "xmark.circle.fill").foregroundStyle(theme.inkTertiary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Effacer")
      }
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, 9)
    .background(theme.paperSecondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(isFieldFocused ? theme.accent.opacity(0.6) : theme.edge, lineWidth: 1)
    )
    .padding(.horizontal, Spacing.md)
  }

  private var placeholder: String {
    switch filter {
    case .whatsapp: "Nom ou numéro WhatsApp"
    case .signal: "Nom ou numéro Signal"
    case .instagram: "Nom d’utilisateur Instagram"
    case .messenger: "Nom ou identifiant Messenger"
    case .iMessage: "Nom, numéro ou e-mail"
    default: "Nom, numéro, e-mail…"
    }
  }

  private var filterChips: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 6) {
        chip(label: "Tous", value: nil)
        ForEach(filterNetworks) { network in
          chip(label: network.labelFR, value: network)
        }
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.sm)
    }
  }

  /// Le libellé seul : six puces illustrées ne tiennent pas sur la largeur de
  /// la feuille, et une puce coupée est une puce qu'on ne voit pas. Le réseau
  /// a son icône sur chaque ligne, là où elle sert.
  private func chip(label: String, value: MessageNetwork?) -> some View {
    let selected = filter == value
    return Button {
      withAnimation(.easeOut(duration: 0.15)) { filter = value }
    } label: {
      Text(label)
        .font(Typography.meta(typeface))
        .fontWeight(selected ? .semibold : .regular)
        .foregroundStyle(selected ? theme.accentInk : theme.inkSecondary)
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(Capsule().fill(selected ? theme.accentFill : theme.paperSecondary.opacity(0.8)))
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
  }

  // MARK: - Résultats

  private var results: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
        if let freeform {
          section("Écrire à") {
            ForEach(freeform.networks) { network in
              PersonRow(
                person: freeformPerson(freeform, network: network),
                theme: theme,
                typeface: typeface,
                onOpen: { open($0) }
              )
            }
          }
        }

        if showsSelfNote || !agents.isEmpty {
          section("Sur le Relais") {
            if showsSelfNote { selfNoteRow }
            ForEach(agents, id: \.self) { agent in
              agentRow(agent)
            }
          }
        }

        if !knownPeople.isEmpty {
          section(filter == nil ? "Déjà en conversation" : "Déjà en conversation sur \(filter?.labelFR ?? "")") {
            ForEach(knownPeople) { person in
              PersonRow(person: person, theme: theme, typeface: typeface, onOpen: { open($0) })
            }
          }
        }

        if !bookPeople.isEmpty {
          section("Dans vos contacts") {
            ForEach(bookPeople) { person in
              PersonRow(person: person, theme: theme, typeface: typeface, onOpen: { open($0) })
            }
          }
        }

        if freeform == nil && knownPeople.isEmpty && bookPeople.isEmpty && agents.isEmpty && !showsSelfNote {
          emptyState
        }
      }
      .padding(.bottom, Spacing.md)
    }
  }

  private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title.uppercased())
        .font(Typography.sidebarSection(typeface))
        .foregroundStyle(theme.inkTertiary)
        .padding(.horizontal, Spacing.md + 4)
        .padding(.top, Spacing.md)
        .padding(.bottom, 4)
      content()
    }
  }

  private var emptyState: some View {
    VStack(spacing: 6) {
      Text(trimmedQuery.isEmpty ? "Personne à joindre pour l'instant." : "Personne ne répond à « \(trimmedQuery) ».")
        .font(Typography.body(typeface))
        .foregroundStyle(theme.inkSecondary)
      Text(filter == nil
        ? "Tape un numéro ou une adresse pour ouvrir un fil neuf."
        : "Un numéro ouvre un fil neuf ici ; « Tous » montre les autres réseaux.")
        .font(Typography.meta(typeface))
        .foregroundStyle(theme.inkTertiary)
    }
    .frame(maxWidth: .infinity)
    .padding(.top, Spacing.xl)
  }

  private var selfNoteRow: some View {
    HoverRow(theme: theme) {
      Task {
        await store.openSelfNote()
        dismiss()
      }
    } content: {
      symbolAvatar(MessageNetwork.selfNote.systemImage)
      VStack(alignment: .leading, spacing: 2) {
        Text("Note à soi")
          .font(Typography.sidebarItem(typeface))
          .foregroundStyle(theme.ink)
        Text("un mot, une adresse, une photo — retrouvés sur l'iPhone")
          .font(Typography.meta(typeface))
          .foregroundStyle(theme.inkTertiary)
          .lineLimit(1)
      }
      Spacer(minLength: Spacing.sm)
    }
  }

  private func agentRow(_ agent: String) -> some View {
    HoverRow(theme: theme) {
      Task {
        await store.openAgentConversation(agent: agent)
        dismiss()
      }
    } content: {
      symbolAvatar(MessageNetwork.agent.systemImage)
      VStack(alignment: .leading, spacing: 2) {
        Text(agent)
          .font(Typography.sidebarItem(typeface))
          .foregroundStyle(theme.ink)
        Text("agent sur le Relais — il répond à tout ce que tu lui écris")
          .font(Typography.meta(typeface))
          .foregroundStyle(theme.inkTertiary)
          .lineLimit(1)
      }
      Spacer(minLength: Spacing.sm)
      NetworkChip(network: .agent, isExisting: true, theme: theme, typeface: typeface)
    }
  }

  private func symbolAvatar(_ systemImage: String) -> some View {
    Image(systemName: systemImage)
      .font(.system(size: 15, weight: .semibold))
      .foregroundStyle(theme.accent)
      .frame(width: 36, height: 36)
      .background(theme.accentSoft, in: Circle())
  }

  // MARK: - Gestes

  private func freeformPerson(_ freeform: Freeform, network: MessageNetwork) -> ReachablePerson {
    ReachablePerson(
      id: "freeform:\(network.rawValue):\(freeform.identifier)",
      name: freeform.identifier,
      detail: "nouveau fil \(network.labelFR)",
      avatar: Conversation(
        id: "freeform:\(freeform.identifier)",
        network: network,
        address: freeform.identifier,
        title: freeform.identifier,
        preview: "",
        lastMessageAt: .distantPast,
        unreadCount: 0,
        isArchived: false,
        transportKey: freeform.identifier,
        isGroup: false
      ),
      reaches: [Reach(network: network, conversationID: nil, handle: freeform.identifier)],
      lastMessageAt: nil
    )
  }

  private func openFirst() {
    if let freeform, let network = freeform.networks.first {
      open((freeformPerson(freeform, network: network), freeformPerson(freeform, network: network).reaches[0]))
      return
    }
    if let agent = agents.first { Task { await store.openAgentConversation(agent: agent); dismiss() }; return }
    if let person = knownPeople.first ?? bookPeople.first, let reach = person.primaryReach {
      open((person, reach))
    }
  }

  /// Un fil qui existe se sélectionne ; un fil neuf s'ouvre avec l'identifiant.
  private func open(_ choice: (person: ReachablePerson, reach: Reach)) {
    let (person, reach) = choice
    Task {
      if let id = reach.conversationID {
        store.mode = .inbox
        await store.select(id)
      } else {
        await store.openOrCreateConversation(network: reach.network, handle: reach.handle, title: person.name)
      }
      dismiss()
    }
  }

  private func refreshBook() async {
    bookHits = await ContactDirectory.shared.searchPeople(query: trimmedQuery)
  }
}

// MARK: - Une personne, ses réseaux

private struct PersonRow: View {
  let person: ReachablePerson
  let theme: WritingTheme
  let typeface: WritingTypeface
  let onOpen: ((person: ReachablePerson, reach: Reach)) -> Void

  var body: some View {
    HoverRow(theme: theme) {
      if let reach = person.primaryReach { onOpen((person, reach)) }
    } content: {
      ConversationAvatarView(conversation: person.avatar, size: 36, theme: theme, showsNetworkBadge: false)
      VStack(alignment: .leading, spacing: 2) {
        Text(person.name)
          .font(Typography.sidebarItem(typeface))
          .foregroundStyle(theme.ink)
          .lineLimit(1)
        if !person.detail.isEmpty {
          Text(person.detail)
            .font(Typography.meta(typeface))
            .foregroundStyle(theme.inkTertiary)
            .lineLimit(1)
        }
      }
      Spacer(minLength: Spacing.sm)
      HStack(spacing: 4) {
        ForEach(person.reaches) { reach in
          Button {
            onOpen((person, reach))
          } label: {
            NetworkChip(network: reach.network, isExisting: reach.isExisting, theme: theme, typeface: typeface)
          }
          .buttonStyle(.plain)
          .help(reach.isExisting
            ? "Ouvrir le fil \(reach.network.labelFR)"
            : "Ouvrir un nouveau fil \(reach.network.labelFR) vers \(reach.handle)")
        }
      }
    }
  }
}

/// La pastille d'un réseau. Pleine : le fil existe. Cernée : il reste à ouvrir.
private struct NetworkChip: View {
  let network: MessageNetwork
  let isExisting: Bool
  let theme: WritingTheme
  let typeface: WritingTypeface

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: network.systemImage)
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(isExisting ? theme.paper : tint)
        .frame(width: 15, height: 15)
        .background(Circle().fill(isExisting ? tint : tint.opacity(0.12)))
      Text(network.labelFR)
        .font(Typography.meta(typeface))
        .fontWeight(.medium)
        .foregroundStyle(isExisting ? theme.ink : theme.inkSecondary)
      if !isExisting {
        Image(systemName: "plus")
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(theme.inkTertiary)
      }
    }
    .padding(.leading, 4)
    .padding(.trailing, 8)
    .padding(.vertical, 4)
    .background(
      Capsule().fill(isExisting ? theme.paperSecondary : Color.clear)
    )
    .overlay(
      Capsule().strokeBorder(isExisting ? Color.clear : theme.edge, style: StrokeStyle(lineWidth: 1, dash: isExisting ? [] : [3, 2]))
    )
    .accessibilityLabel(isExisting ? network.labelFR : "Nouveau fil \(network.labelFR)")
  }

  /// La même teinte que la pastille des avatars : un réseau, une couleur, partout.
  private var tint: Color {
    switch network {
    case .selfNote: Color(red: 0.55, green: 0.52, blue: 0.48)
    case .agent: theme.accent
    case .iMessage: Color(red: 0.25, green: 0.75, blue: 0.45)
    case .signal: theme.accent
    case .whatsapp: Color(red: 0.15, green: 0.72, blue: 0.42)
    case .instagram: Color(red: 0.78, green: 0.23, blue: 0.55)
    case .messenger: Color(red: 0.35, green: 0.40, blue: 0.95)
    }
  }
}

/// Une ligne qui s'éclaire sous la souris et s'ouvre d'un clic — la liste
/// n'est pas une `List` : les pastilles y sont des boutons à part entière.
private struct HoverRow<Content: View>: View {
  let theme: WritingTheme
  let action: () -> Void
  @ViewBuilder let content: () -> Content

  @State private var isHovered = false

  var body: some View {
    HStack(spacing: Spacing.sm) {
      content()
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, 7)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(isHovered ? theme.selection.opacity(0.6) : Color.clear)
    )
    .padding(.horizontal, Spacing.xs)
    .contentShape(Rectangle())
    .onTapGesture(perform: action)
    .onHover { isHovered = $0 }
  }
}
