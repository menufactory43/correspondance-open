import CorrespondanceCore
import CorrespondanceUI
import SwiftUI

/// La barre flottante du bas — en verre, posée sur la file.
///
/// À gauche le filtre (Tous / Non lus / Brouillons / Sans réponse / Groupes) ;
/// au centre la pilule Inbox · Archive · Focus, qui est le chemin vers Focus
/// (décision 9) ; à droite la recherche, inactive jusqu'à la phase C2.
struct InboxFloatingBar: View {
  @Binding var mode: PhoneMode
  /// La recherche est ouverte par la loupe d'ici, mais l'inbox la tient : c'est
  /// elle que la démonstration doit pouvoir ouvrir sans doigt.
  @Binding var isSearching: Bool

  @Environment(RelayStore.self) private var store
  @Environment(ThemePreferences.self) private var themes

  private var theme: WritingTheme { themes.theme }
  private var typeface: WritingTypeface { themes.typeface }

  var body: some View {
    HStack(spacing: Spacing.xs) {
      filterMenu
      modePill
      searchButton
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 6)
    .glassSurface(
      cornerRadius: 26,
      fallbackFill: theme.sidebar,
      border: theme.edge,
      isInteractive: true
    )
    .shadow(color: .black.opacity(theme.isDark ? 0.35 : 0.12), radius: 12, y: 4)
    .sheet(isPresented: $isSearching) {
      SearchSheet()
        .environment(store)
        .environment(themes)
    }
  }

  // MARK: - Filtre

  private var filterMenu: some View {
    Menu {
      Picker("Filtre", selection: Binding(
        get: { store.filter },
        set: { store.filter = $0 }
      )) {
        ForEach(ConversationFilter.allCases) { filter in
          Label(filter.labelFR, systemImage: filter.systemImage).tag(filter)
        }
      }
    } label: {
      ZStack {
        Image(systemName: "line.3.horizontal.decrease")
          .font(.system(size: 15, weight: .medium))
          .foregroundStyle(store.filter == .all ? theme.inkSecondary : theme.accent)
      }
      .frame(width: 40, height: 34)
      .background(
        Capsule().fill(store.filter == .all ? Color.clear : theme.accentSoft.opacity(0.25))
      )
    }
    .accessibilityLabel("Filtre : \(store.filter.labelFR). Changer de filtre.")
  }

  // MARK: - Pilule de mode

  private var modePill: some View {
    HStack(spacing: 2) {
      ForEach(PhoneMode.allCases) { candidate in
        Button {
          select(candidate)
        } label: {
          Text(candidate.labelFR)
            .font(Typography.meta(typeface))
            .fontWeight(mode == candidate ? .semibold : .regular)
            .foregroundStyle(mode == candidate ? theme.accentInk : theme.inkSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
              Capsule().fill(mode == candidate ? theme.accentFill : Color.clear)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(candidate.labelFR)
        .accessibilityAddTraits(mode == candidate ? [.isSelected, .isButton] : .isButton)
      }
    }
    .padding(2)
    .background(Capsule().fill(theme.paperSecondary.opacity(0.6)))
    .frame(maxWidth: .infinity)
    .animation(.easeOut(duration: 0.16), value: mode)
  }

  private func select(_ candidate: PhoneMode) {
    mode = candidate
    if let scope = candidate.scope { store.scope = scope }
  }

  // MARK: - Recherche

  private var searchButton: some View {
    Button {
      isSearching = true
    } label: {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(theme.inkSecondary)
        .frame(width: 40, height: 34)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Rechercher")
  }
}
