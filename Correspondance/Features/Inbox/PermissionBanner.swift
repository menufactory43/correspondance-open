import AppKit
import SwiftUI
import CorrespondanceCore
import CorrespondanceUI

/// Visible tant que chat.db est inaccessible — évite de croire que la démo = iMessage.
struct PermissionBanner: View {
  @Environment(ThemePreferences.self) private var themes
  @State private var hasOpenedSettings = false

  private var theme: WritingTheme { themes.theme }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text("Tes iMessages ne sont pas encore visibles")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(theme.ink)
      Text(explanation)
        .font(Typography.meta)
        .foregroundStyle(theme.inkSecondary)
        .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: Spacing.sm) {
        Button("Ouvrir Accès disque") {
          hasOpenedSettings = true
          DiskAccess.openSettings()
        }
        .buttonStyle(.borderedProminent)
        .tint(theme.accent)

        // Le geste que macOS impose : la case cochée ne vaut qu'au prochain
        // lancement. Mis en avant dès qu'on est allé dans les Réglages.
        if hasOpenedSettings {
          Button("Quitter et rouvrir") { DiskAccess.relaunch() }
            .buttonStyle(.borderedProminent)
            .tint(theme.accent)
        } else {
          Button("Quitter et rouvrir") { DiskAccess.relaunch() }
            .buttonStyle(.bordered)
        }

        if !DiskAccess.isRunFromXcode {
          Button("Montrer l’app dans le Finder") { DiskAccess.revealInFinder() }
            .buttonStyle(.bordered)
        }
      }
      .controlSize(.small)

      Text(steps)
        .font(Typography.meta)
        .foregroundStyle(theme.inkTertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(Spacing.md)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(theme.paperSecondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(theme.edge.opacity(0.8), lineWidth: 1)
    )
  }

  private var explanation: String {
    if DiskAccess.isRunFromXcode {
      return "Lancée depuis Xcode, l’app lit le disque avec les droits d’Xcode : c’est à Xcode qu’il faut « Accès complet au disque », pas à Correspondance."
    }
    return "Correspondance lit ~/Library/Messages/chat.db. Sans « Accès complet au disque », l’app affiche des conversations fictives (Marie, Julien…)."
  }

  private var steps: String {
    if DiskAccess.isRunFromXcode {
      return "Coche Xcode dans la liste (ajoute-le avec « + » s’il n’y est pas), puis relance depuis Xcode."
    }
    let place = DiskAccess.isInstalledInApplications
      ? "/Applications/Correspondance.app"
      : "cette copie-ci (\(DiskAccess.bundleURL.path)) — pas une autre"
    return "Ajoute \(place) avec « + », coche-la, puis « Quitter et rouvrir » : macOS n’applique la case qu’au prochain lancement."
  }
}
