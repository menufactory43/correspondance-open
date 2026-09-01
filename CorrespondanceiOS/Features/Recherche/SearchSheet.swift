import CorrespondanceCore
import CorrespondanceUI
import SwiftUI

/// La recherche : un champ, une rangée d'onglets, et ce qu'on trouve.
///
/// Deux façons de chercher, pas une. Sans onglet, on cherche des
/// **conversations** — un nom, un numéro, un aperçu, le corps des messages
/// chargés (`ConversationSearch`). Avec un onglet, on cherche des **choses** :
/// une photo, une vidéo, un lien, un fichier, un brouillon (`FacetedSearch`).
/// Le champ sert aux deux ; c'est l'onglet qui change la question.
///
/// Tout se passe sur l'appareil, sur ce qui est déjà chargé. Rien n'est demandé
/// au Relais — c'est la règle de la décision 7, celle qui tiendra le jour où le
/// Relais ne saura plus lire un seul message.
struct SearchSheet: View {
  /// Un fil, et rien que lui : la recherche ouverte depuis sa fiche. Sans
  /// onglet, on y cherche alors des messages, pas des conversations.
  var scope: String?

  @Environment(RelayStore.self) private var store
  @Environment(ThemePreferences.self) private var themes
  @Environment(\.dismiss) private var dismiss

  @State private var query = ""
  @State private var facet: MessageFacet?
  @FocusState private var isFocused: Bool

  private var theme: WritingTheme { themes.theme }
  private var typeface: WritingTypeface { themes.typeface }

  private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        field
        facetRow
        Divider().overlay(theme.edge)
        results
      }
      .background(theme.paper.ignoresSafeArea())
      .navigationTitle("Rechercher")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) { Button("Fermer") { dismiss() } }
      }
      .toolbarBackground(theme.paper, for: .navigationBar)
    }
    .tint(theme.accent)
    .task { isFocused = !store.isDemo }
  }

  // MARK: - Le champ

  private var field: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass").foregroundStyle(theme.inkTertiary)
      TextField(
        "",
        text: $query,
        prompt: Text("Un nom, un mot, un numéro").foregroundStyle(theme.inkTertiary)
      )
      .font(Typography.composer(typeface))
      .foregroundStyle(theme.ink)
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()
      .focused($isFocused)
      if !query.isEmpty {
        Button {
          query = ""
        } label: {
          Image(systemName: "xmark.circle.fill").foregroundStyle(theme.inkTertiary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Effacer la recherche")
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.paperSecondary.opacity(0.7))
    )
    .padding(.horizontal, Spacing.md)
    .padding(.top, Spacing.xs)
  }

  // MARK: - Les onglets

  private var facetRow: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 5) {
        ForEach(MessageFacet.allCases) { candidate in
          let selected = facet == candidate
          Button {
            // Retaper l'onglet actif le referme : on revient aux conversations.
            facet = selected ? nil : candidate
          } label: {
            Label(candidate.labelFR, systemImage: candidate.systemImage)
              .font(Typography.meta(typeface))
              .fontWeight(selected ? .semibold : .regular)
              .foregroundStyle(selected ? theme.accentInk : theme.inkSecondary)
              .padding(.horizontal, 9)
              .padding(.vertical, 6)
              .background(
                Capsule().fill(selected ? theme.accentFill : theme.paperSecondary.opacity(0.6))
              )
          }
          .buttonStyle(.plain)
          .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        }
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.sm)
    }
  }

  // MARK: - Résultats

  /// Les conversations dans lesquelles on cherche : toutes, ou celle du fil.
  private var conversations: [Conversation] {
    guard let scope else { return store.conversations }
    return store.conversations.filter { $0.id == scope }
  }

  @ViewBuilder
  private var results: some View {
    switch facet {
    case .none where scope != nil:
      threadMessageResults
    case .none:
      conversationResults
    case .some(.drafts):
      draftResults
    case .some(let facet):
      messageResults(facet)
    }
  }

  /// Toutes les conversations, cherchées jusque dans le corps des messages déjà
  /// chargés — c'est ce que `blob` indexe.
  private var conversationResults: some View {
    let hits = ConversationSearch.filter(
      conversations, query: trimmed, index: store.searchIndex(query: trimmed)
    )
      .sorted { $0.lastMessageAt > $1.lastMessageAt }
    return list(empty: "Rien de ce nom-là") {
      ForEach(hits) { conversation in
        row(conversation, subtitle: nil)
      }
    }
  }

  /// Dans un fil : ses messages qui contiennent le mot, du plus récent au plus
  /// ancien. Sans mot, rien — la liste entière est déjà derrière la feuille.
  private var threadMessageResults: some View {
    let hits = threadHits
    return list(empty: trimmed.isEmpty ? "Un mot, et le fil se cherche" : "Rien dans ce fil") {
      ForEach(hits) { message in
        messageRow(message, in: conversations.first)
      }
    }
  }

  private var threadHits: [ChatMessage] {
    guard let scope, !trimmed.isEmpty else { return [] }
    return store.visibleMessages(scope)
      .filter { $0.text.localizedStandardContains(trimmed) }
      .reversed()
  }

  private var draftResults: some View {
    let hits = FacetedSearch.conversationsWithDrafts(
      conversations,
      drafts: store.viewState.drafts,
      query: trimmed
    )
    return list(empty: "Aucun brouillon en cours") {
      ForEach(hits) { conversation in
        row(conversation, subtitle: store.viewState.drafts[conversation.id])
      }
    }
  }

  /// Les messages, dans leur fil, avec la bulle telle qu'elle est — c'est elle
  /// qu'on reconnaît, pas une ligne de résumé.
  private func messageResults(_ facet: MessageFacet) -> some View {
    let hits = facetHits(facet)

    return list(empty: "Rien en « \(facet.labelFR) »") {
      ForEach(hits) { hit in
        messageRow(hit.message, in: hit.conversation)
      }
    }
  }

  private func facetHits(_ facet: MessageFacet) -> [FacetedSearch.Hit] {
    let hits = store.facetHits(facet: facet, query: trimmed)
    guard let scope else { return hits }
    return hits.filter { $0.conversation.id == scope }
  }

  private func messageRow(_ message: ChatMessage, in conversation: Conversation?) -> some View {
    Button {
      if let conversation { open(conversation.id, jumpingTo: message.id) }
    } label: {
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 5) {
          if let conversation {
            Image(systemName: conversation.network.systemImage)
              .font(.system(size: 10))
            Text(conversation.title)
              .fontWeight(.semibold)
          }
          Spacer(minLength: 6)
          Text(ConversationRow.shortDate(message.sentAt))
            .monospacedDigit()
        }
        .font(Typography.meta(typeface))
        .foregroundStyle(theme.inkTertiary)

        MessageBubble(
          message: message,
          theme: theme,
          typeface: typeface,
          // Pas d'aperçu de lien dans un résultat : dix cartes qui se
          // chargent en même temps, c'est une liste qui saute.
          showsLinkPreviews: false
        )
        .allowsHitTesting(false)
      }
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, 8)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .listRowInsets(EdgeInsets())
    .listRowBackground(Color.clear)
  }

  // MARK: - Habillage

  @ViewBuilder
  private func list<Content: View>(
    empty: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    let rendered = content()
    List { rendered }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .scrollDismissesKeyboard(.interactively)
      .overlay {
        if isEmpty {
          VStack(spacing: Spacing.sm) {
            Image(systemName: "magnifyingglass")
              .font(.system(size: 30, weight: .light))
              .foregroundStyle(theme.inkTertiary)
            Text(empty)
              .font(Typography.emptyState(typeface))
              .foregroundStyle(theme.inkSecondary)
          }
        }
      }
  }

  /// Vide au sens de l'écran : rien à montrer pour la question posée.
  private var isEmpty: Bool {
    switch facet {
    case .none where scope != nil:
      return threadHits.isEmpty
    case .none:
      return ConversationSearch.filter(
        conversations, query: trimmed, index: store.searchIndex(query: trimmed)
      ).isEmpty
    case .some(.drafts):
      return FacetedSearch.conversationsWithDrafts(
        conversations, drafts: store.viewState.drafts, query: trimmed
      ).isEmpty
    case .some(let facet):
      return facetHits(facet).isEmpty
    }
  }

  private func row(_ conversation: Conversation, subtitle: String?) -> some View {
    Button {
      open(conversation.id)
    } label: {
      ConversationRow(
        conversation: conversation,
        theme: theme,
        typeface: typeface,
        isPinned: store.isPinned(conversation.id),
        isMuted: store.isMuted(conversation.id),
        draft: subtitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      )
    }
    .buttonStyle(.plain)
    .listRowInsets(EdgeInsets())
    .listRowBackground(Color.clear)
  }

  /// Ouvrir la conversation — et, quand c'est un message qu'on a touché, s'y
  /// rendre : le fil vise l'identifiant et le surligne à l'arrivée.
  private func open(_ conversationID: String, jumpingTo messageID: String? = nil) {
    store.pendingJumpMessageID = messageID
    store.selectedConversationID = conversationID
    Task { await store.open(conversationID: conversationID) }
    dismiss()
  }
}
