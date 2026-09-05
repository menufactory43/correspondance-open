import CorrespondanceCore
import CorrespondanceUI
import SwiftUI

/// « Fusionner avec… » : on coche les fils qui sont la même personne sur un
/// autre réseau. C'est la voie quand aucun numéro ne peut le dire — un Signal
/// qui cache son numéro, un Messenger qui n'en a pas.
///
/// Même logique que le Mac (`MergePickerSheet`) : ce que l'app a repéré
/// d'elle-même en tête, tous les autres fils dessous ; « Fusionner » ouvre la
/// feuille où l'on choisit nom, visage et chat par défaut — ou, si une ligne
/// déjà fusionnée est dans le lot, tout le monde la rejoint telle quelle.
struct MergePickerSheet: View {
  let source: Conversation

  @Environment(RelayStore.self) private var store
  @Environment(ThemePreferences.self) private var themes
  @Environment(\.dismiss) private var dismiss

  @State private var query = ""
  @State private var selectedIDs: Set<String> = []
  @State private var pairToConfirm: MergeProposal?

  private var theme: WritingTheme { themes.theme }
  private var typeface: WritingTypeface { themes.typeface }
  private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

  /// Ce que l'app a repéré : même numéro, ou même nom mot pour mot. Proposé,
  /// jamais imposé — le ✕ fait taire la proposition.
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

  /// Les fils cochés, dans l'ordre de la liste — le plus récent d'abord.
  private var selection: [Conversation] {
    (suggested + candidates).filter { selectedIDs.contains($0.id) }
  }

  var body: some View {
    NavigationStack {
      list
        .background(theme.paper.ignoresSafeArea())
        .navigationTitle(store.isMerged(source.id) ? "Ajouter un chat" : "Fusionner avec…")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .topBarLeading) { Button("Fermer") { dismiss() } }
        }
        .toolbarBackground(theme.paper, for: .navigationBar)
        .searchable(text: $query, prompt: "Nom ou numéro")
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .navigationDestination(item: $pairToConfirm) { proposal in
          MergeContactSheet(candidates: proposal.candidates) { dismiss() }
        }
    }
    .tint(theme.accent)
  }

  private var list: some View {
    List {
      Section {
        Text("Coche les fils qui sont la même personne sur d'autres réseaux. Ils se liront ensemble ; « Séparer », dans la fiche, défait tout.")
          .font(Typography.meta(typeface))
          .foregroundStyle(theme.inkTertiary)
          .listRowBackground(Color.clear)
          .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 8, trailing: 4))
      }

      if !suggested.isEmpty {
        Section {
          ForEach(suggested) { candidate in
            row(candidate)
          }
        } header: {
          HStack {
            Text("Proposé — même numéro ou même nom")
              .font(Typography.sidebarSection(typeface))
              .foregroundStyle(theme.accent)
            Spacer()
            Button {
              store.dismissMergeCandidate([source] + suggested)
            } label: {
              Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(theme.inkTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Ne plus proposer cette fusion")
          }
        }
        .listRowBackground(theme.paperSecondary.opacity(0.5))
      }

      if candidates.isEmpty && suggested.isEmpty {
        Text(trimmed.isEmpty
          ? "Aucun autre fil à réunir : tous les réseaux de cette personne sont déjà là."
          : "Personne ne répond à « \(trimmed) ».")
          .font(Typography.body(typeface))
          .foregroundStyle(theme.inkSecondary)
          .frame(maxWidth: .infinity)
          .padding(.vertical, Spacing.xl)
          .listRowBackground(Color.clear)
      } else {
        Section {
          ForEach(candidates) { candidate in
            row(candidate)
          }
        } header: {
          if !suggested.isEmpty, !candidates.isEmpty {
            Text("Tous les fils")
              .font(Typography.sidebarSection(typeface))
              .foregroundStyle(theme.inkTertiary)
          }
        }
        .listRowBackground(theme.paperSecondary.opacity(0.5))
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
  }

  private func row(_ candidate: Conversation) -> some View {
    let isSelected = selectedIDs.contains(candidate.id)
    let networks = networks(of: candidate)
    return Button {
      toggle(candidate)
    } label: {
      HStack(spacing: 12) {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 22, weight: .regular))
          .foregroundStyle(isSelected ? theme.accent : theme.inkTertiary.opacity(0.6))
          .accessibilityHidden(true)
        ConversationAvatar(conversation: candidate, size: 40, theme: theme, showsNetworkBadge: false)
        VStack(alignment: .leading, spacing: 2) {
          Text(candidate.title)
            .font(Typography.body(typeface, size: 16))
            .foregroundStyle(theme.ink)
            .lineLimit(1)
          Text(networks.map(\.labelFR).joined(separator: " · "))
            .font(Typography.meta(typeface))
            .foregroundStyle(theme.inkTertiary)
            .lineLimit(1)
        }
        Spacer(minLength: 8)
        HStack(spacing: 4) {
          ForEach(networks) { network in
            Image(systemName: network.systemImage)
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(theme.inkSecondary)
              .accessibilityLabel(network.labelFR)
          }
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
  }

  private var footer: some View {
    VStack(spacing: 6) {
      Button(action: confirm) {
        Text(actionLabel)
          .font(Typography.body(typeface, size: 16))
          .fontWeight(.semibold)
          .foregroundStyle(theme.accentInk)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 13)
          .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
              .fill(selectedIDs.isEmpty ? theme.accentFill.opacity(0.4) : theme.accentFill)
          )
      }
      .buttonStyle(.plain)
      .disabled(selectedIDs.isEmpty)
      Text(selectedIDs.isEmpty
        ? "Aucun fil coché"
        : "\(selectedIDs.count) fil\(selectedIDs.count > 1 ? "s" : "") coché\(selectedIDs.count > 1 ? "s" : "")")
        .font(Typography.meta(typeface))
        .foregroundStyle(theme.inkTertiary)
    }
    .padding(.horizontal, Spacing.md)
    .padding(.top, Spacing.sm)
    .padding(.bottom, Spacing.xs)
    .background(theme.paper)
  }

  private var actionLabel: String {
    let count = selectedIDs.count
    if store.isMerged(source.id) || selection.contains(where: { store.isMerged($0.id) }) {
      return count <= 1 ? "Ajouter à cette personne" : "Ajouter \(count) chats"
    }
    return count == 0 ? "Fusionner" : "Fusionner \(count + 1) chats"
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
      store.addToMerge(mergedID: source.id, chosen)
      dismiss()
    } else if let host = chosen.first(where: { store.isMerged($0.id) }) {
      store.addToMerge(mergedID: host.id, [source] + chosen.filter { $0.id != host.id })
      dismiss()
    } else {
      pairToConfirm = MergeProposal(candidates: [source] + chosen)
    }
  }
}

/// Les fils qu'on s'apprête à réunir — une valeur, pour pousser la feuille.
private struct MergeProposal: Hashable {
  let candidates: [Conversation]
  func hash(into hasher: inout Hasher) { hasher.combine(candidates.map(\.id)) }
  static func == (lhs: Self, rhs: Self) -> Bool { lhs.candidates.map(\.id) == rhs.candidates.map(\.id) }
}

/// « Fusionner ces chats ? » — nom, visage et réseau par défaut avant que
/// deux fils n'en deviennent un. Rien d'irréversible : « Séparer » défait tout.
struct MergeContactSheet: View {
  let candidates: [Conversation]
  /// Appelé une fois la fusion faite : la feuille qui nous porte se referme.
  var onDone: () -> Void

  @Environment(RelayStore.self) private var store
  @Environment(ThemePreferences.self) private var themes

  @State private var title = ""
  @State private var avatarConversationID: String?
  @State private var defaultConversationID = ""

  private var theme: WritingTheme { themes.theme }
  private var typeface: WritingTypeface { themes.typeface }

  private var avatarConversation: Conversation? {
    candidates.first { $0.id == avatarConversationID } ?? candidates.first
  }

  var body: some View {
    ScrollView {
      VStack(spacing: Spacing.lg) {
        if let avatarConversation {
          ConversationAvatar(conversation: avatarConversation, size: 88, theme: theme, showsNetworkBadge: false)
            .padding(.top, Spacing.sm)
        }

        TextField("Nom", text: $title)
          .font(Typography.body(typeface, size: 22))
          .fontWeight(.semibold)
          .foregroundStyle(theme.ink)
          .multilineTextAlignment(.center)
          .textFieldStyle(.plain)
          .padding(.horizontal, Spacing.lg)

        VStack(alignment: .leading, spacing: Spacing.xs) {
          sectionTitle("Photo")
          HStack(spacing: Spacing.md) {
            ForEach(candidates) { conversation in
              Button {
                avatarConversationID = conversation.id
              } label: {
                VStack(spacing: 6) {
                  ConversationAvatar(conversation: conversation, size: 52, theme: theme)
                    .overlay(
                      Circle().strokeBorder(
                        theme.accent,
                        lineWidth: conversation.id == avatarConversation?.id ? 2.5 : 0
                      )
                    )
                  Text(conversation.network.labelFR)
                    .font(Typography.meta(typeface))
                    .foregroundStyle(theme.inkSecondary)
                }
              }
              .buttonStyle(.plain)
              .accessibilityLabel("Utiliser la photo \(conversation.network.labelFR)")
              .accessibilityAddTraits(conversation.id == avatarConversation?.id ? .isSelected : [])
            }
            Spacer(minLength: 0)
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 12)
          .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.paperSecondary))
        }

        VStack(alignment: .leading, spacing: Spacing.xs) {
          sectionTitle("Chat par défaut")
          VStack(spacing: 0) {
            ForEach(Array(candidates.enumerated()), id: \.element.id) { index, conversation in
              Button {
                defaultConversationID = conversation.id
              } label: {
                HStack(spacing: 12) {
                  Image(systemName: conversation.network.systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(theme.inkSecondary)
                    .frame(width: 24)
                  Text(conversation.networkAndReadableAddress)
                    .font(Typography.body(typeface, size: 16))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                  Spacer(minLength: 0)
                  if conversation.id == defaultConversationID {
                    Image(systemName: "checkmark")
                      .font(.system(size: 14, weight: .semibold))
                      .foregroundStyle(theme.accent)
                  }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .accessibilityAddTraits(conversation.id == defaultConversationID ? [.isButton, .isSelected] : .isButton)
              if index < candidates.count - 1 {
                Divider().overlay(theme.edge.opacity(0.6)).padding(.leading, 48)
              }
            }
          }
          .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.paperSecondary))
          Text("Les fils se liront ensemble, du plus ancien au plus récent. Le chat par défaut est celui où part le prochain message.")
            .font(Typography.meta(typeface))
            .foregroundStyle(theme.inkTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
        }
      }
      .padding(.horizontal, Spacing.md)
      .padding(.bottom, Spacing.lg)
    }
    .background(theme.paper.ignoresSafeArea())
    .navigationTitle("Fusionner")
    .navigationBarTitleDisplayMode(.inline)
    .toolbarBackground(theme.paper, for: .navigationBar)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      Button {
        store.merge(
          candidates,
          title: title,
          avatarConversationID: avatarConversationID,
          defaultConversationID: defaultConversationID
        )
        onDone()
      } label: {
        Text("Fusionner \(candidates.count) chats")
          .font(Typography.body(typeface, size: 16))
          .fontWeight(.semibold)
          .foregroundStyle(theme.accentInk)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 13)
          .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.accentFill))
      }
      .buttonStyle(.plain)
      .padding(.horizontal, Spacing.md)
      .padding(.top, Spacing.sm)
      .padding(.bottom, Spacing.xs)
      .background(theme.paper)
    }
    .onAppear(perform: prime)
  }

  private func sectionTitle(_ text: String) -> some View {
    Text(text)
      .font(Typography.meta(typeface))
      .fontWeight(.semibold)
      .foregroundStyle(theme.inkSecondary)
      .padding(.horizontal, 4)
  }

  /// Le meilleur nom qu'on ait déjà, et le réseau du dernier message reçu
  /// comme chat par défaut (iMessage n'existe pas sur l'iPhone).
  private func prime() {
    guard defaultConversationID.isEmpty else { return }
    title = candidates.first { !$0.hasPlaceholderTitle }?.title
      ?? candidates.first?.title
      ?? "Contact"
    avatarConversationID = candidates.first { $0.remoteAvatarID != nil }?.id
      ?? candidates.first { !$0.hasPlaceholderTitle }?.id
      ?? candidates.first?.id
    defaultConversationID = candidates.max(by: { $0.lastMessageAt < $1.lastMessageAt })?.id
      ?? candidates.first?.id
      ?? ""
  }
}
