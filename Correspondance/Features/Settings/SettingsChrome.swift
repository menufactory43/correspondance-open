import SwiftUI
import CorrespondanceCore
import CorrespondanceUI

/// Le vocabulaire visuel des Réglages : un en-tête de page, une ligne de compte,
/// une ligne d'état, un bouton d'action. Les volets n'inventent rien d'autre.

/// En-tête d'un volet — titre, sous-titre. Le pendant du gros titre d'un
/// panneau de Réglages système : on sait toujours où l'on est.
struct SettingsPaneHeader: View {
  @Environment(ThemePreferences.self) private var themes

  let title: String
  let subtitle: String

  private var theme: WritingTheme { themes.theme }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.xxs) {
      Text(title)
        .font(.system(size: 20, weight: .semibold))
        .foregroundStyle(theme.ink)
      Text(subtitle)
        .font(.callout)
        .foregroundStyle(theme.inkSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.top, Spacing.lg)
  }
}

/// Un groupe de réglages : titre discret + carte creusée dans le papier.
struct SettingsCard<Content: View>: View {
  @Environment(ThemePreferences.self) private var themes

  let title: String
  var footnote: String?
  @ViewBuilder var content: Content

  private var theme: WritingTheme { themes.theme }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text(title.uppercased())
        .font(.system(size: 11, weight: .semibold))
        .tracking(0.6)
        .foregroundStyle(theme.inkTertiary)
        .padding(.horizontal, Spacing.xxs)

      VStack(alignment: .leading, spacing: 0) {
        content
      }
      .padding(.vertical, Spacing.xxs)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(theme.paperSecondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .strokeBorder(theme.separator.opacity(0.6), lineWidth: 1)
      }

      if let footnote {
        Text(footnote)
          .font(.caption)
          .foregroundStyle(theme.inkTertiary)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
          .padding(.horizontal, Spacing.xxs)
      }
    }
  }
}

/// Une rangée de carte : libellé à gauche, contrôle à droite, explication dessous.
struct SettingsRow<Trailing: View>: View {
  @Environment(ThemePreferences.self) private var themes

  let label: String
  var detail: String?
  var systemImage: String?
  @ViewBuilder var trailing: Trailing

  private var theme: WritingTheme { themes.theme }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
      if let systemImage {
        Image(systemName: systemImage)
          .font(.system(size: 13))
          .foregroundStyle(theme.accent)
          .frame(width: 18, alignment: .center)
      }

      VStack(alignment: .leading, spacing: 2) {
        Text(label)
          .font(.body)
          .foregroundStyle(theme.ink)
        if let detail {
          Text(detail)
            .font(.caption)
            .foregroundStyle(theme.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }
      }

      Spacer(minLength: Spacing.sm)

      trailing
        .labelsHidden()
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.xs)
  }
}

extension SettingsRow where Trailing == EmptyView {
  init(label: String, detail: String? = nil, systemImage: String? = nil) {
    self.init(label: label, detail: detail, systemImage: systemImage) { EmptyView() }
  }
}

/// Le trait qui sépare deux rangées d'une même carte — jamais aux extrémités.
struct SettingsDivider: View {
  @Environment(ThemePreferences.self) private var themes

  var body: some View {
    Rectangle()
      .fill(themes.theme.separator.opacity(0.5))
      .frame(height: 1)
      .padding(.leading, Spacing.sm)
  }
}
