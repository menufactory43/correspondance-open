import SwiftUI
import CorrespondanceCore
import CorrespondanceUI

/// Invite à autoriser Contacts — obligatoire pour que l’app apparaisse dans Confidentialité.
struct ContactsPermissionBanner: View {
  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes
  @State private var isRequesting = false

  private var theme: WritingTheme { themes.theme }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text("Autoriser les Contacts")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(theme.ink)
      Text(store.contactsStatusFR.isEmpty || store.contactsStatusFR == "…"
        ? "Correspondance doit afficher la boîte système macOS. Sans ça, l’app n’apparaît pas dans Confidentialité → Contacts."
        : store.contactsStatusFR)
        .font(Typography.meta)
        .foregroundStyle(theme.inkSecondary)
        .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: Spacing.sm) {
        Button {
          isRequesting = true
          Task {
            await store.requestContactsPermission()
            isRequesting = false
          }
        } label: {
          if isRequesting {
            Text("Demande…")
          } else {
            Text("Autoriser Contacts…")
          }
        }
        .buttonStyle(.borderedProminent)
        .tint(theme.accent)
        .controlSize(.small)
        .disabled(isRequesting)

        Button("Ouvrir Confidentialité") {
          store.openContactsPrivacySettings()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }
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
