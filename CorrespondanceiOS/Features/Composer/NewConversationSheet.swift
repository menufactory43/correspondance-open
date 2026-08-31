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
/// Deux façons d'arriver à quelqu'un : le retrouver parmi les gens que le
/// Relais connaît déjà, ou composer un numéro. Pas de troisième — et pas de
/// groupe : ceux-là se créent dans l'app d'origine, où vivent les règles
/// d'admission de chaque réseau.
struct NewConversationSheet: View {
  @Environment(RelayStore.self) private var store
  @Environment(ThemePreferences.self) private var themes
  @Environment(\.dismiss) private var dismiss

  @State private var network: MessageNetwork?
  @State private var query = ""
  @State private var isOpening = false
  @State private var failure: String?
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
  }

  // MARK: - Puces de réseau

  /// Seuls les réseaux qui ont déjà un fil : une puce Instagram sans compte
  /// Instagram ne mènerait nulle part, et le dirait trop tard.
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
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .scrollDismissesKeyboard(.interactively)
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
    // Un pseudo : Instagram, et seulement si on l'a choisi. Deviner qu'un mot
    // est un pseudo Instagram plutôt qu'un nom mal orthographié, c'est deviner.
    if network == .instagram {
      let bare = trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed
      guard !bare.isEmpty, !bare.contains(" "), !bare.contains("@") else { return nil }
      return Freeform(network: .instagram, identifier: bare)
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
      // Dit une fois, juste au-dessus du champ : les groupes se créent là où
      // vivent leurs règles d'admission, pas ici.
      Text("Les groupes se créent depuis l'app d'origine.")
        .font(Typography.meta(typeface))
        .foregroundStyle(theme.inkTertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.md)
        .padding(.top, 8)
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
        .keyboardType(network == .instagram ? .default : .namePhonePad)
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
    default: "Nom ou numéro"
    }
  }
}
