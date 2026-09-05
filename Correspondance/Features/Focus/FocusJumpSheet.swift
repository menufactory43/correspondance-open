import SwiftUI
import CorrespondanceCore
import CorrespondanceUI

/// La feuille de garde (⌘K) : taper un nom, la page tourne.
///
/// Elle se pose sur la page — le papier du thème, voilé —, jamais dans une
/// fenêtre à part : on ne quitte pas le Focus pour changer de conversation,
/// et on ne rouvre pas la liste. La même recherche que la réponse rapide,
/// aucune liste à part. Entrée tourne la page, Échap revient à la lecture,
/// un clic à côté aussi.
struct FocusJumpSheet: View {
  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes
  @State private var query = ""
  @State private var selection = 0
  @FocusState private var isFieldFocused: Bool

  private var theme: WritingTheme { themes.theme }

  /// Huit lignes : une feuille de garde, pas une inbox. La recherche fouille
  /// aussi les messages ; ici on cherche QUELQU'UN : les noms qui commencent
  /// par ce qu'on tape passent devant, puis ceux qui le contiennent, puis
  /// les fils où ça se dit.
  private var matches: [Conversation] {
    let list = store.quickReplyMatches(query)
    let needle = Self.fold(query)
    guard !needle.isEmpty else { return Array(list.prefix(8)) }
    let ranked = list.enumerated().map { index, conversation -> (Int, Int, Conversation) in
      let title = Self.fold(conversation.title)
      let rank = title.hasPrefix(needle) ? 0 : (title.contains(needle) ? 1 : 2)
      return (rank, index, conversation)
    }
    return Array(ranked.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.prefix(8).map(\.2))
  }

  private static func fold(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
  }

  var body: some View {
    ZStack(alignment: .top) {
      // Le voile : le papier, presque opaque, sur la page qu'on quitte un instant.
      Rectangle()
        .fill(.ultraThinMaterial)
        .overlay(theme.paper.opacity(0.86))
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { close() }
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 0) {
        TextField("À qui ?", text: $query)
          .textFieldStyle(.plain)
          .font(Typography.letterHeading(themes.typeface, 20).italic())
          .foregroundStyle(theme.ink)
          .focused($isFieldFocused)
          .padding(.bottom, Spacing.sm)
          .overlay(alignment: .bottom) {
            Rectangle().fill(theme.edge).frame(height: 1)
          }
          .onKeyPress(.escape) { close(); return .handled }
          .onKeyPress(.return) { choose(); return .handled }
          .onKeyPress(.downArrow) { move(1); return .handled }
          .onKeyPress(.upArrow) { move(-1); return .handled }
          .accessibilityLabel("Chercher une conversation")

        if matches.isEmpty {
          Text("Personne à ce nom.")
            .font(Typography.meta(themes.typeface))
            .foregroundStyle(theme.inkTertiary)
            .padding(.top, Spacing.md)
        } else {
          VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(matches.enumerated()), id: \.element.id) { index, conversation in
              row(conversation, isSelected: index == selection)
                .onTapGesture { select(conversation.id) }
                .onHover { if $0 { selection = index } }
            }
          }
          .padding(.top, Spacing.sm)
        }

        HStack(spacing: Spacing.sm) {
          Text("↑↓ choisir")
          Text("⏎ tourner la page")
          Text("esc revenir")
        }
        .font(Typography.meta(themes.typeface))
        .foregroundStyle(theme.inkTertiary)
        .padding(.top, Spacing.lg)
        .accessibilityHidden(true)
      }
      .frame(maxWidth: 440)
      .padding(.horizontal, Spacing.lg)
      .padding(.top, LayoutMetrics.pageTopInset * 1.4)
    }
    .onAppear { isFieldFocused = true }
    .onChange(of: query) { _, _ in selection = 0 }
  }

  private func row(_ conversation: Conversation, isSelected: Bool) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
      Text(conversation.title)
        .font(Typography.body(themes.typeface, size: 14))
        .foregroundStyle(theme.ink)
        .lineLimit(1)
      Text(conversation.preview)
        .font(Typography.meta(themes.typeface))
        .foregroundStyle(theme.inkTertiary)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 0)
      if conversation.unreadCount > 0 {
        Text("\(conversation.unreadCount)")
          .font(Typography.meta(themes.typeface))
          .monospacedDigit()
          .foregroundStyle(theme.inkSecondary)
      }
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, 6)
    .background(
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .fill(isSelected ? theme.paperSecondary : Color.clear)
    )
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
  }

  private func move(_ step: Int) {
    let count = matches.count
    guard count > 0 else { return }
    selection = min(max(selection + step, 0), count - 1)
  }

  private func choose() {
    let list = matches
    guard list.indices.contains(selection) else { return }
    select(list[selection].id)
  }

  private func select(_ id: String) {
    close()
    Task { @MainActor in await store.select(id) }
  }

  private func close() {
    store.isPresentingJump = false
  }
}
