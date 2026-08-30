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
      SettingsCard(title: "Autorisations demandées par l’app") {
        SettingsRow(
          label: "Contacts",
          detail: store.contactsStatusFR,
          systemImage: "person.crop.circle"
        ) {
          Button("Autoriser…") {
            Task { await store.requestContactsPermission() }
          }
        }

        SettingsDivider()

        SettingsRow(
          label: "Notifications",
          detail: store.notificationStatusFR,
          systemImage: "bell.badge"
        ) {
          Button("Autoriser…") {
            Task {
              await store.requestNotificationPermission()
              // Déjà refusé : macOS ne réaffiche plus la boîte, on ouvre les Réglages.
              if store.notificationStatusFR.contains("refus") {
                store.openNotificationSettings()
              }
            }
          }
        }

        SettingsDivider()

        SettingsRow(
          label: "Messages (Automatisation)",
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
        title: "Réglages système",
        footnote: "L’accès disque est ce qui donne l’historique iMessage : sans lui, la sync reste vide."
      ) {
        SettingsRow(label: "Accès complet au disque", systemImage: "externaldrive") {
          Button("Ouvrir") { openPrivacy("Privacy_AllFiles") }
        }
        SettingsDivider()
        SettingsRow(label: "Contacts", systemImage: "person.2") {
          Button("Ouvrir") { openPrivacy("Privacy_Contacts") }
        }
        SettingsDivider()
        SettingsRow(label: "Automatisation", systemImage: "app.connected.to.app.below.fill") {
          Button("Ouvrir") { store.openAutomationPrivacySettings() }
        }
        SettingsDivider()
        SettingsRow(label: "Accessibilité", systemImage: "accessibility") {
          Button("Ouvrir") { store.openAccessibilityPrivacySettings() }
        }
      }
    }
  }

  private func openPrivacy(_ anchor: String) {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
    Platform.open(url)
  }
}
