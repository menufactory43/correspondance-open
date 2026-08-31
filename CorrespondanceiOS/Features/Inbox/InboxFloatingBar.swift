import CorrespondanceCore
import CorrespondanceUI
import SwiftUI

/// La barre flottante du bas — trois surfaces de verre posées sur la file,
/// comme Beeper : un rond à gauche, la pilule au centre, un rond à droite.
///
/// Pas une capsule qui englobe tout : chaque geste a son propre relief, et la
/// pilule Inbox · Archive · Focus — le chemin vers Focus (décision 9) — reste
/// seule à porter la sélection. À gauche le filtre (Tous / Non lus /
/// Brouillons / Sans réponse / Groupes) ; à droite la recherche.
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
    HStack(spacing: Spacing.sm) {
      filterMenu
        .modifier(FloatingGlass(cornerRadius: Self.roundSize / 2, theme: theme))
      modePill
        .modifier(FloatingGlass(cornerRadius: Self.pillHeight / 2, theme: theme))
      searchButton
        .modifier(FloatingGlass(cornerRadius: Self.roundSize / 2, theme: theme))
    }
    .sheet(isPresented: $isSearching) {
      SearchSheet()
        .environment(store)
        .environment(themes)
    }
  }

  /// Les deux ronds : un carré de 46, arrondi en cercle par la surface.
  private static let roundSize: CGFloat = 46
  /// La pilule : 2 de marge + 8 de padding autour d'une ligne de méta.
  private static let pillHeight: CGFloat = 46

  /// Le verre commun aux trois surfaces, ombre comprise : c'est la même
  /// matière, à trois endroits.
  private struct FloatingGlass: ViewModifier {
    let cornerRadius: CGFloat
    let theme: WritingTheme

    func body(content: Content) -> some View {
      content
        .glassSurface(
          cornerRadius: cornerRadius,
          fallbackFill: theme.sidebar,
          border: theme.edge,
          isInteractive: true
        )
        .shadow(color: .black.opacity(theme.isDark ? 0.35 : 0.12), radius: 12, y: 4)
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
          .font(.system(size: 16, weight: .medium))
          .foregroundStyle(store.filter == .all ? theme.inkSecondary : theme.accent)
      }
      .frame(width: Self.roundSize, height: Self.roundSize)
      .background(
        Circle().fill(store.filter == .all ? Color.clear : theme.accentSoft.opacity(0.25))
      )
      .contentShape(Circle())
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
    .frame(maxWidth: .infinity)
    .frame(height: Self.pillHeight)
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
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(theme.inkSecondary)
        .frame(width: Self.roundSize, height: Self.roundSize)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Rechercher")
  }
}
