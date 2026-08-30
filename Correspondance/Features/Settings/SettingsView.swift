import AppKit
import SwiftUI

/// Les Réglages tels qu'on les attend d'une app Mac : une barre latérale de
/// rubriques à gauche, un volet à droite. Pas un formulaire fleuve où l'on
/// scrolle pour trouver la case « Contacts ».
struct SettingsView: View {
  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes

  @State private var section: SettingsSection = .comptes

  private var theme: WritingTheme { themes.theme }

  var body: some View {
    HStack(spacing: 0) {
      sidebar
      Divider().overlay(theme.separator)
      detail
    }
    .frame(
      minWidth: 840, idealWidth: 900, maxWidth: .infinity,
      minHeight: 620, idealHeight: 680, maxHeight: .infinity
    )
    .background(theme.paper)
    .background {
      SettingsWindowSizer(
        minSize: NSSize(width: 840, height: 620),
        idealSize: NSSize(width: 900, height: 680),
        title: "Réglages",
        isDark: theme.id.prefersDarkChrome
      )
      .frame(width: 0, height: 0)
    }
    .preferredColorScheme(theme.id.prefersDarkChrome ? .dark : .light)
    .tint(theme.accent)
    .sheet(item: Binding(
      get: { store.bridgeLoginNetwork },
      set: { store.bridgeLoginNetwork = $0 }
    )) { network in
      BridgeLoginSheet(network: network)
    }
    .task { await store.refreshMatrixStatus() }
  }

  // MARK: - Barre latérale

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("Réglages")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(theme.inkTertiary)
        .padding(.horizontal, Spacing.sm)
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.xs)

      ForEach(SettingsSection.allCases) { item in
        sidebarButton(item)
      }

      Spacer(minLength: 0)
    }
    .padding(.horizontal, Spacing.xs)
    .padding(.bottom, Spacing.sm)
    .frame(width: 208)
    .fixedSize(horizontal: true, vertical: false)
    .frame(maxHeight: .infinity)
    .background(theme.sidebar.ignoresSafeArea())
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Rubriques des réglages")
  }

  private func sidebarButton(_ item: SettingsSection) -> some View {
    let isSelected = section == item

    return Button {
      section = item
    } label: {
      HStack(spacing: Spacing.xs) {
        Image(systemName: item.systemImage)
          .font(.system(size: 13))
          .frame(width: 20, alignment: .center)
          .foregroundStyle(isSelected ? theme.accent : theme.inkSecondary)
        Text(item.labelFR)
          .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
          .foregroundStyle(isSelected ? theme.ink : theme.inkSecondary)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, Spacing.xs)
      .padding(.vertical, 7)
      .background {
        if isSelected {
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(theme.selection)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }

  // MARK: - Volet

  private var detail: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.lg) {
        SettingsPaneHeader(title: section.labelFR, subtitle: section.subtitleFR)

        switch section {
        case .comptes: SettingsAccountsPane()
        case .matrix: SettingsMatrixPane()
        case .automatisation: SettingsAutomationPane()
        case .autorisations: SettingsPermissionsPane()
        case .apparence: SettingsAppearancePane()
        case .dictee: SettingsDictationPane()
        }
      }
      .padding(.horizontal, Spacing.lg)
      .padding(.bottom, Spacing.xl)
      .frame(maxWidth: 640, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(theme.paper.ignoresSafeArea())
  }
}

/// Les rubriques de la fenêtre — l'ordre ici est l'ordre de la barre latérale.
enum SettingsSection: String, CaseIterable, Identifiable {
  case comptes
  case matrix
  case automatisation
  case autorisations
  case apparence
  case dictee

  var id: String { rawValue }

  var labelFR: String {
    switch self {
    case .comptes: "Comptes"
    case .matrix: "Serveur Matrix"
    case .automatisation: "Automatisation"
    case .autorisations: "Autorisations"
    case .apparence: "Apparence"
    case .dictee: "Dictée"
    }
  }

  var subtitleFR: String {
    switch self {
    case .comptes: "Les réseaux branchés sur Correspondance et l’état de chaque lien."
    case .matrix: "Le homeserver qui porte les ponts WhatsApp et Instagram."
    case .automatisation: "Piloter Messages en arrière-plan pour les actions qu’iMessage réserve à son app."
    case .autorisations: "Ce que macOS a accordé à Correspondance, et où le corriger."
    case .apparence: "Le mode d’ouverture, la police et l’ambiance d’écriture."
    case .dictee: "Le moteur qui transforme la voix en texte dans le composer."
    }
  }

  var systemImage: String {
    switch self {
    case .comptes: "person.2.fill"
    case .matrix: "server.rack"
    case .automatisation: "wand.and.stars"
    case .autorisations: "lock.shield"
    case .apparence: "paintbrush"
    case .dictee: "mic"
    }
  }
}
