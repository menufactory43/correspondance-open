import CorrespondanceCore
import CorrespondanceUI
import SwiftUI

/// Nouvelle conversation — la feuille, à la Beeper.
///
/// Les puces de réseau en haut, les résultats au milieu, le champ **en bas**,
/// sous le pouce, là où le clavier va le pousser de toute façon. C'est
/// l'inverse du Mac (`NewConversationSheet`), et pour une raison de main : sur
/// un téléphone, ce qui se tape se met près de ce qui tape.
///
/// Trois façons d'arriver à quelqu'un : le retrouver parmi les gens que le
/// Relais connaît déjà, le retrouver dans le carnet d'adresses de l'iPhone,
/// ou composer un numéro. Et un groupe se crée d'ici quand un pont branché
/// sait le faire (`NewGroupSheet`) — sinon, dans l'app d'origine.
struct NewConversationSheet: View {
  @Environment(RelayStore.self) private var store
  @Environment(ThemePreferences.self) private var themes
  @Environment(\.dismiss) private var dismiss

  @State private var network: MessageNetwork?
  @State private var query = ""
  @State private var isOpening = false
  @State private var failure: String?
  @State private var isCreatingGroup = false
  @State private var bookHits: [ContactBook.Person] = []
  @FocusState private var isFocused: Bool

  private var theme: WritingTheme { themes.theme }
  private var typeface: WritingTypeface { themes.typeface }

  private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        networkChips
        Divider().overlay(theme.edge)
        results
      }
      .background(theme.paper.ignoresSafeArea())
      .navigationTitle("Nouvelle conversation")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Fermer") { dismiss() }
        }
      }
      .toolbarBackground(theme.paper, for: .navigationBar)
      .safeAreaInset(edge: .bottom, spacing: 0) { searchField }
    }
    .tint(theme.accent)
    .task { isFocused = !store.isDemo }
    .sheet(isPresented: $isCreatingGroup) {
      NewGroupSheet()
        .environment(store)
        .environment(themes)
    }
    .onChange(of: query) { _, _ in
      Task { await refreshBookHits() }
    }
  }

  // MARK: - Puces de réseau

  /// Seuls les réseaux qui ont déjà un fil : une puce Messenger sans compte
  /// Messenger ne mènerait nulle part, et le dirait trop tard.
  private var networks: [MessageNetwork] {
    let inUse = store.networksInUse
    return inUse.isEmpty ? MessageNetwork.matrixBridged : inUse
  }

  private var networkChips: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 6) {
        chip(label: "Tous", value: nil)
        ForEach(networks) { candidate in
          chip(label: candidate.labelFR, value: candidate)
        }
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.sm)
    }
  }

  /// Le libellé seul, sans icône : quatre puces illustrées ne tiennent pas sur
  /// la largeur d'un iPhone, et une puce à moitié coupée est une puce qu'on ne
  /// voit pas.
  private func chip(label: String, value: MessageNetwork?) -> some View {
    let selected = network == value
    return Button {
      network = value
    } label: {
      Text(label)
        .font(Typography.meta(typeface))
        .fontWeight(selected ? .semibold : .regular)
        .foregroundStyle(selected ? theme.accentInk : theme.inkSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
          Capsule().fill(selected ? theme.accentFill : theme.paperSecondary.opacity(0.7))
        )
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
  }

  // MARK: - Résultats

  /// Les gens que le Relais connaît : un fil en tête-à-tête EST un contact.
  /// Les lignes de fusion en font partie — une personne reconnue sur deux
  /// réseaux n'apparaît qu'une fois, comme dans la file.
  private var candidates: [Conversation] {
    store.conversations
      .filter { !$0.isGroup }
      .filter { network == nil || $0.network == network || MergedContact.isMergedID($0.id) }
      .filter { ConversationSearch.matches($0, query: trimmed, messageBlob: nil) }
      .sorted { $0.lastMessageAt > $1.lastMessageAt }
  }

  private var results: some View {
    List {
      // « Écrire à plusieurs » est la même intention qu'« écrire à quelqu'un » :
      // le geste vit ici. Absent si aucun pont branché ne sait le faire.
      if store.canCreateGroup {
        Section {
          Button {
            isCreatingGroup = true
          } label: {
            Label {
              Text("Nouveau groupe…")
                .foregroundStyle(theme.ink)
            } icon: {
              Image(systemName: "person.2.badge.plus")
                .foregroundStyle(theme.accent)
            }
          }
        }
        .listRowBackground(theme.paperSecondary.opacity(0.5))
      }

      if let composable {
        Section {
          Button {
            open(freeform: composable)
          } label: {
            Label {
              VStack(alignment: .leading, spacing: 2) {
                Text("Écrire à \(composable.identifier)")
                  .foregroundStyle(theme.ink)
                Text("Nouveau fil \(composable.network.labelFR)")
                  .font(Typography.meta(typeface))
                  .foregroundStyle(theme.inkTertiary)
              }
            } icon: {
              Image(systemName: composable.network.systemImage)
                .foregroundStyle(theme.accent)
            }
          }
          .disabled(isOpening)
        }
        .listRowBackground(theme.paperSecondary.opacity(0.5))
      }

      if let failure {
        Text(failure)
          .font(Typography.meta(typeface))
          .foregroundStyle(theme.accent)
          .listRowBackground(Color.clear)
      }

      Section {
        ForEach(candidates) { conversation in
          Button {
            open(existing: conversation)
          } label: {
            ConversationRow(
              conversation: conversation,
              theme: theme,
              typeface: typeface,
              draft: ""
            )
            .listRowInsets(EdgeInsets())
          }
          .buttonStyle(.plain)
          .listRowInsets(EdgeInsets())
          .listRowBackground(Color.clear)
        }
      } header: {
        if !candidates.isEmpty {
          Text("Déjà sur le Relais")
            .font(Typography.sidebarSection(typeface))
            .foregroundStyle(theme.inkTertiary)
        }
      }

      // Le carnet d'adresses de l'iPhone : les gens qu'on connaît mais que le
      // Relais n'a pas encore vus. Une ligne par numéro composable — un fil
      // déjà ouvert avec ce numéro reste dans « Déjà sur le Relais ».
      if let bookNetwork {
        Section {
          ForEach(bookHits) { person in
            ForEach(composablePhones(of: person), id: \.self) { phone in
              Button {
                guard let e164 = PhoneNormalizer.e164(phone) else { return }
                open(freeform: Freeform(network: bookNetwork, identifier: e164))
              } label: {
                Label {
                  VStack(alignment: .leading, spacing: 2) {
                    Text(person.name)
                      .foregroundStyle(theme.ink)
                    Text("\(phone) — nouveau fil \(bookNetwork.labelFR)")
                      .font(Typography.meta(typeface))
                      .foregroundStyle(theme.inkTertiary)
                  }
                } icon: {
                  Image(systemName: bookNetwork.systemImage)
                    .foregroundStyle(theme.accent)
                }
              }
              .disabled(isOpening)
              .listRowBackground(Color.clear)
            }
          }
        } header: {
          if bookHits.contains(where: { !composablePhones(of: $0).isEmpty }) {
            Text("Dans vos contacts")
              .font(Typography.sidebarSection(typeface))
              .foregroundStyle(theme.inkTertiary)
          }
        }
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .scrollDismissesKeyboard(.interactively)
  }

  // MARK: - Le carnet d'adresses

  /// Le réseau qui recevra un numéro du carnet : celui choisi s'il se compose
  /// (WhatsApp, Signal) ; « Tous » prend celui qu'on utilise déjà. Instagram et
  /// Messenger ne connaissent pas les numéros — pas de section.
  private var bookNetwork: MessageNetwork? {
    if let network {
      return (network == .whatsapp || network == .signal) ? network : nil
    }
    if networks.contains(.whatsapp) { return .whatsapp }
    return networks.contains(.signal) ? .signal : nil
  }

  /// Les numéros d'une personne qui ouvrent vraiment un fil neuf : composables
  /// en E.164, et pas déjà une conversation du Relais.
  private func composablePhones(of person: ContactBook.Person) -> [String] {
    person.phones.filter { phone in
      guard let e164 = PhoneNormalizer.e164(phone) else { return false }
      let suffix = String(e164.filter(\.isNumber).suffix(9))
      return !store.conversations.contains { conversation in
        !conversation.isGroup
          && String(conversation.address.filter(\.isNumber).suffix(9)) == suffix
      }
    }
  }

  private func refreshBookHits() async {
    guard !store.isDemo else { return }
    bookHits = await ContactBook.shared.search(query: trimmed)
  }

  // MARK: - Composer un numéro

  /// Ce qu'on peut ouvrir à partir de ce qui est tapé, quand c'est reconnaissable.
  private struct Freeform {
    var network: MessageNetwork
    var identifier: String
  }

  private var composable: Freeform? {
    guard !trimmed.isEmpty else { return nil }
    // Déjà dans la liste : proposer de « l'écrire » en double serait absurde.
    guard !candidates.contains(where: {
      $0.address.caseInsensitiveCompare(trimmed) == .orderedSame
        || $0.title.caseInsensitiveCompare(trimmed) == .orderedSame
    }) else { return nil }

    // Un numéro : WhatsApp et Signal. Le réseau choisi tranche ; « Tous »
    // prend celui qu'on utilise déjà, WhatsApp à défaut.
    if let phone = PhoneNormalizer.e164(trimmed) {
      let target = network ?? (networks.contains(.whatsapp) ? .whatsapp : networks.first)
      guard let target, target == .whatsapp || target == .signal else { return nil }
      return Freeform(network: target, identifier: phone)
    }
    // Un pseudo : Instagram, Messenger ou X, et seulement si on l'a choisi. Deviner
    // qu'un mot est un pseudo plutôt qu'un nom mal orthographié, c'est deviner.
    if let network, network == .instagram || network == .messenger || network == .twitter || network == .slack {
      let bare = trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed
      guard !bare.isEmpty, !bare.contains(" "), !bare.contains("@") else { return nil }
      return Freeform(network: network, identifier: bare)
    }
    return nil
  }

  private func open(existing conversation: Conversation) {
    store.selectedConversationID = conversation.id
    Task { await store.open(conversationID: conversation.id) }
    dismiss()
  }

  /// Le pont ouvre le fil : la commande part au bot, et le salon arrive par
  /// le `/sync` qui suit. On ferme la feuille — attendre devant serait mentir
  /// sur qui fait le travail.
  private func open(freeform: Freeform) {
    isOpening = true
    failure = nil
    Task {
      do {
        try await store.startBridgeChat(network: freeform.network, identifier: freeform.identifier)
        dismiss()
      } catch {
        failure = RelayStore.readable(error)
      }
      isOpening = false
    }
  }

  // MARK: - Le champ, en bas

  private var searchField: some View {
    VStack(spacing: 0) {
      Divider().overlay(theme.edge)
      // Dit une fois, juste au-dessus du champ — seulement quand aucun pont
      // branché ne sait créer de groupe : sinon le geste est dans la liste.
      if !store.canCreateGroup {
        Text("Les groupes se créent depuis l'app d'origine.")
          .font(Typography.meta(typeface))
          .foregroundStyle(theme.inkTertiary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, Spacing.md)
          .padding(.top, 8)
      }
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(theme.inkTertiary)
        TextField(
          "",
          text: $query,
          prompt: Text(placeholder).foregroundStyle(theme.inkTertiary)
        )
        .font(Typography.composer(typeface))
        .foregroundStyle(theme.ink)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .keyboardType(network == .instagram || network == .messenger || network == .twitter || network == .slack ? .default : .namePhonePad)
        .focused($isFocused)
        .submitLabel(.go)
        .onSubmit { if let composable { open(freeform: composable) } }
        if !query.isEmpty {
          Button {
            query = ""
          } label: {
            Image(systemName: "xmark.circle.fill").foregroundStyle(theme.inkTertiary)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Effacer")
        }
        if isOpening { ProgressView() }
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, 10)
      .background(.bar)
    }
  }

  private var placeholder: String {
    switch network {
    case .whatsapp: "Nom ou numéro WhatsApp"
    case .signal: "Nom ou numéro Signal"
    case .instagram: "Nom d'utilisateur Instagram"
    case .messenger: "Nom ou identifiant Messenger"
    case .twitter: "Pseudo X, sans l'arobase"
    case .slack: "Nom ou e-mail Slack"
    default: "Nom ou numéro"
    }
  }
}
