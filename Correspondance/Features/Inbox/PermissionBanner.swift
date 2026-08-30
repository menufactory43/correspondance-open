import AppKit
import SwiftUI
import CorrespondanceCore
import CorrespondanceUI

/// Visible tant que chat.db est inaccessible — évite de croire que la démo = iMessage.
struct PermissionBanner: View {
  @Environment(ThemePreferences.self) private var themes

  private var theme: WritingTheme { themes.theme }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text("Tes iMessages ne sont pas encore visibles")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(theme.ink)
      Text("Correspondance lit ~/Library/Messages/chat.db. Sans « Accès complet au disque », l’app affiche des conversations fictives (Marie, Julien…).")
        .font(Typography.meta)
        .foregroundStyle(theme.inkSecondary)
        .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: Spacing.sm) {
        Button("Ouvrir Accès disque") {
          if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
          }
        }
        .buttonStyle(.borderedProminent)
        .tint(theme.accent)

        Button("Montrer l’app dans le Finder") {
          NSWorkspace.shared.activateFileViewerSelecting([
            URL(fileURLWithPath: "/Applications/Correspondance.app")
          ])
        }
        .buttonStyle(.bordered)
      }
      .controlSize(.small)

      Text("Ajoute /Applications/Correspondance.app → coche-la → ⌘Q puis relance → actualise.")
        .font(Typography.meta)
        .foregroundStyle(theme.inkTertiary)
    }
    .padding(Spacing.md)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(theme.paperSecondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(theme.edge.opacity(0.8), lineWidth: 1)
    )
  }
}
