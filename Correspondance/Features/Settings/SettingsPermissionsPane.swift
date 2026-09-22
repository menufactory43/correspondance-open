import AppKit
import SwiftUI
import CorrespondanceCore
import CorrespondanceUI

/// Ce que macOS a accordé, et le chemin le plus court pour le corriger.
/// Chaque ligne dit son état et porte son bouton : jamais de chasse au réglage.
struct SettingsPermissionsPane: View {
  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      SettingsCard(title: String(localized: "Autorisations")) {
        SettingsRow(
          label: String(localized: "Contacts"),
          detail: store.contactsStatusFR,
          systemImage: "person.crop.circle"
        ) {
          Button("Autoriser…") {
            Task { await store.requestContactsPermission() }
          }
        }

        SettingsDivider()

        SettingsRow(
          label: String(localized: "Notifications"),
          detail: store.notificationStatusFR,
          systemImage: "bell.badge"
        ) {
          Button("Autoriser…") {
            Task {
              await store.requestNotificationPermission()
              // Déjà refusé : macOS ne réaffiche plus la boîte, on ouvre les Réglages.
              // Comparé à la MÊME chaîne localisée, et non à un morceau de
              // français : le texte change avec la langue, le test doit suivre.
              if store.notificationStatusFR
                == String(localized: "Refusées. Autorise Correspondance dans Réglages Système, Notifications.")
              {
                store.openNotificationSettings()
              }
            }
          }
        }

        SettingsDivider()

        SettingsRow(
          label: String(localized: "Piloter Messages"),
          detail: store.messagesAutomationStatusFR,
          systemImage: "gearshape.arrow.triangle.2.circlepath"
        ) {
          Button("Autoriser…") {
            let ok = store.requestMessagesAutomation()
            if !ok { store.openAutomationPrivacySettings() }
          }
        }
      }

      SettingsCard(
        title: String(localized: "Réglages système"),
        footnote: String(localized: "Sans l’accès complet au disque, Correspondance ne peut pas lire tes iMessage.")
      ) {
        SettingsRow(label: String(localized: "Accès complet au disque"), systemImage: "externaldrive") {
          Button("Ouvrir") { openPrivacy("Privacy_AllFiles") }
        }
        SettingsDivider()
        SettingsRow(label: String(localized: "Contacts"), systemImage: "person.2") {
          Button("Ouvrir") { openPrivacy("Privacy_Contacts") }
        }
        SettingsDivider()
        SettingsRow(label: String(localized: "Automatisation"), systemImage: "app.connected.to.app.below.fill") {
          Button("Ouvrir") { store.openAutomationPrivacySettings() }
        }
        SettingsDivider()
        SettingsRow(label: String(localized: "Accessibilité"), systemImage: "accessibility") {
          Button("Ouvrir") { store.openAccessibilityPrivacySettings() }
        }
        SettingsDivider()
        // L'extension de partage est là dès l'installation, mais macOS ne coche
        // pas une extension tierce tout seul : une case, une fois.
        SettingsRow(
          label: String(localized: "Partager depuis le Finder, Safari, Photos"),
          detail: String(localized: "Coche Correspondance dans Extensions › Partage, une fois."),
          systemImage: "square.and.arrow.up"
        ) {
          Button("Ouvrir") { openExtensions() }
        }
      }
    }
  }

  private func openExtensions() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences?Sharing") else { return }
    NSWorkspace.shared.open(url)
  }

  private func openPrivacy(_ anchor: String) {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
    Platform.open(url)
  }
}
