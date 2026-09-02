import SwiftUI
import CorrespondanceCore
import CorrespondanceUI

/// « Fusionner avec… » : on choisit à la main le fil qui est la même personne
/// sur un autre réseau. C'est la voie quand aucun numéro ne peut le dire — un
/// Signal qui cache son numéro, un Messenger qui n'en a pas.
///
/// On coche autant de fils qu'on veut — Julie sur Signal ET sur Messenger,
/// d'un coup — puis « Fusionner ». Deux issues :
/// - que des tête-à-tête → la feuille de fusion, où l'on choisit nom, visage et chat par défaut ;
/// - une ligne déjà fusionnée dans le lot (au départ ou parmi les cochés) →
///   tout le monde la rejoint, telle quelle.
struct MergePickerSheet: View {
  let source: Conversation
  let theme: WritingTheme

  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes
  @Environment(\.dismiss) private var dismiss

  @State private var query = ""
  @State private var selectedIDs: Set<String> = []
  @State private var pairToConfirm: [Conversation]?
  @FocusState private var isFieldFocused: Bool

  private var typeface: WritingTypeface { themes.typeface }
  private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

  /// Ce que l'app a repéré d'elle-même : même numéro, ou même nom mot pour
  /// mot. Proposé en tête, jamais imposé — le ✕ fait taire la proposition.
  private var suggested: [Conversation] {
    (store.mergeCandidates(for: source) ?? [])
      .filter { $0.id != source.id }
      .filter { ConversationSearch.matches($0, query: trimmed, messageBlob: nil) }
  }

  /// Les fils qu'on peut réunir au fil de départ : des tête-à-tête, ou des
  /// lignes déjà fusionnées, d'un autre réseau que ceux qu'il porte déjà.
  private var candidates: [Conversation] {
    let taken = Set(networks(of: source))
    let proposed = Set(suggested.map(\.id))
    return store.conversations
      .filter { !proposed.contains($0.id) }
      .filter { $0.id != source.id && !$0.isGroup }
      .filter { $0.network != .selfNote && $0.network != .agent }
      // Un réseau ne se fusionne pas avec lui-même : deux fils WhatsApp sont
      // deux personnes, ou un doublon que le pont réglera.
      .filter { candidate in !networks(of: candidate).contains(where: taken.contains) }
      .filter { ConversationSearch.matches($0, query: trimmed, messageBlob: nil) }
      .sorted { $0.lastMessageAt > $1.lastMessageAt }
  }

  private func networks(of conversation: Conversation) -> [MessageNetwork] {
    store.isMerged(conversation.id)
      ? store.memberConversations(of: conversation.id).map(\.network)
      : [conversation.network]
  }

  var body: some View {
    if let pairToConfirm {
      MergeContactSheet(candidates: pairToConfirm, theme: theme)
    } else {
      picker
    }
  }

  private var picker: some View {
    VStack(spacing: 0) {
      header
      searchField
      Divider().overlay(theme.edge)
      list
      Divider().overlay(theme.edge)
      footer
    }
    .frame(width: 480, height: 600)
    .background(theme.paper)
    .task { isFieldFocused = true }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(store.isMerged(source.id) ? "Ajouter un chat à \(source.title)" : "Fusionner \(source.title) avec…")
          .font(Typography.letterHeading(typeface, 17))
          .foregroundStyle(theme.ink)
          .lineLimit(1)
        Spacer()
        Button("Fermer") { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
      Text("Coche les fils qui sont la même personne sur d'autres réseaux. Ils se liront ensemble ; « Séparer », dans la fiche, défait tout.")
        .font(Typography.meta(typeface))
        .foregroundStyle(theme.inkTertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, Spacing.md)
    .padding(.top, Spacing.md)
    .padding(.bottom, Spacing.sm)
  }

  private var searchField: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(theme.inkTertiary)
      TextField("", text: $query, prompt: Text("Nom ou numéro").foregroundStyle(theme.inkTertiary))
        .textFieldStyle(.plain)
        .font(Typography.composer(typeface))
        .foregroundStyle(theme.ink)
        .focused($isFieldFocused)
        .onSubmit {
          if !selectedIDs.isEmpty { confirm() } else if let first = suggested.first ?? candidates.first { toggle(first) }
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
    .padding(.bottom, Spacing.sm)
  }

  private var list: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        if !suggested.isEmpty {
          HStack {
            Text("PROPOSÉ — MÊME NUMÉRO OU MÊME NOM")
              .font(Typography.sidebarSection(typeface))
              .foregroundStyle(theme.accent)
            Spacer()
            Button {
              store.dismissMergeCandidate([source] + suggested)
            } label: {
              Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(theme.inkTertiary)
            }
            .buttonStyle(.plain)
            .help("Ne plus proposer cette fusion")
            .accessibilityLabel("Ne plus proposer cette fusion")
          }
          .padding(.horizontal, Spacing.md + 4)
          .padding(.top, Spacing.xs)
          .padding(.bottom, 4)
          ForEach(suggested) { candidate in
            CandidateRow(
              conversation: candidate,
              networks: networks(of: candidate),
              isSelected: selectedIDs.contains(candidate.id),
              theme: theme,
              typeface: typeface
            ) { toggle(candidate) }
          }
          if !candidates.isEmpty {
            Text("TOUS LES FILS")
              .font(Typography.sidebarSection(typeface))
              .foregroundStyle(theme.inkTertiary)
              .padding(.horizontal, Spacing.md + 4)
              .padding(.top, Spacing.md)
              .padding(.bottom, 4)
          }
        }
        if candidates.isEmpty && suggested.isEmpty {
          Text(trimmed.isEmpty
            ? "Aucun autre fil à réunir : tous les réseaux de cette personne sont déjà là."
            : "Personne ne répond à « \(trimmed) ».")
            .font(Typography.body(typeface))
            .foregroundStyle(theme.inkSecondary)
            .frame(maxWidth: .infinity)
            .padding(.top, Spacing.xl)
        }
        ForEach(candidates) { candidate in
          CandidateRow(
            conversation: candidate,
            networks: networks(of: candidate),
            isSelected: selectedIDs.contains(candidate.id),
            theme: theme,
            typeface: typeface
          ) { toggle(candidate) }
        }
      }
      .padding(.vertical, Spacing.xs)
    }
  }

  /// Les fils cochés, dans l'ordre de la liste — le plus récent d'abord.
  private var selection: [Conversation] {
    (suggested + candidates).filter { selectedIDs.contains($0.id) }
  }

  private var footer: some View {
    HStack {
      Text(selectedIDs.isEmpty
        ? "Aucun fil coché"
        : "\(selectedIDs.count) fil\(selectedIDs.count > 1 ? "s" : "") coché\(selectedIDs.count > 1 ? "s" : "")")
        .font(Typography.meta(typeface))
        .foregroundStyle(theme.inkTertiary)
      Spacer()
      Button(actionLabel) { confirm() }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .disabled(selectedIDs.isEmpty)
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
  }

  private var actionLabel: String {
    let count = selectedIDs.count
    if store.isMerged(source.id) || selection.contains(where: { store.isMerged($0.id) }) {
      return count <= 1 ? "Ajouter à cette personne" : "Ajouter \(count) chats"
    }
    return "Fusionner \(count + 1) chats"
  }

  private func toggle(_ conversation: Conversation) {
    if selectedIDs.contains(conversation.id) {
      selectedIDs.remove(conversation.id)
    } else {
      selectedIDs.insert(conversation.id)
    }
  }

  /// Une ligne déjà fusionnée dans le lot accueille tout le monde ; sinon on
  /// passe par la feuille où l'on choisit nom, visage et chat par défaut.
  private func confirm() {
    let chosen = selection
    guard !chosen.isEmpty else { return }
    if store.isMerged(source.id) {
      let id = source.id
      dismiss()
      Task { await store.addToMerge(mergedID: id, chosen) }
    } else if let host = chosen.first(where: { store.isMerged($0.id) }) {
      let others = [source] + chosen.filter { $0.id != host.id }
      dismiss()
      Task { await store.addToMerge(mergedID: host.id, others) }
    } else {
      pairToConfirm = [source] + chosen
    }
  }
}

private struct CandidateRow: View {
  let conversation: Conversation
  let networks: [MessageNetwork]
  let isSelected: Bool
  let theme: WritingTheme
  let typeface: WritingTypeface
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
        .font(.system(size: 17, weight: .regular))
        .foregroundStyle(isSelected ? theme.accent : theme.inkTertiary.opacity(0.7))
        .accessibilityHidden(true)
      ConversationAvatarView(conversation: conversation, size: 34, theme: theme, showsNetworkBadge: false)
      VStack(alignment: .leading, spacing: 2) {
        Text(conversation.title)
          .font(Typography.sidebarItem(typeface))
          .foregroundStyle(theme.ink)
          .lineLimit(1)
        Text(networks.map(\.labelFR).joined(separator: " · "))
          .font(Typography.meta(typeface))
          .foregroundStyle(theme.inkTertiary)
          .lineLimit(1)
      }
      Spacer(minLength: Spacing.sm)
      HStack(spacing: 3) {
        ForEach(networks) { network in
          Image(systemName: network.systemImage)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(theme.inkSecondary)
            .accessibilityLabel(network.labelFR)
        }
      }
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, 7)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(isSelected ? theme.selection.opacity(0.8) : (isHovered ? theme.selection.opacity(0.5) : Color.clear))
    )
    .padding(.horizontal, Spacing.xs)
    .contentShape(Rectangle())
    .onTapGesture(perform: action)
    .onHover { isHovered = $0 }
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
  }
}
