import SwiftUI
import CorrespondanceCore
import CorrespondanceUI

/// Lot M2 — pilotage de Messages.app par l'Accessibilité, app cachée.
/// Éteint, Correspondance se comporte exactement comme avant.
struct SettingsAutomationPane: View {
  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      SettingsCard(
        title: "Messages en arrière-plan",
        footnote: "Pour les réactions, les réponses citées, modifier ou annuler un envoi sur iMessage. "
          + "Messages tourne caché, tu ne le verras pas."
      ) {
        SettingsRow(
          label: "Piloter Messages",
          detail: store.messagesAutomationStatusFR,
          systemImage: "message.badge.waveform"
        ) {
          Toggle("", isOn: Binding(
            get: { store.isMessagesAutomationEnabled },
            set: { store.isMessagesAutomationEnabled = $0 }
          ))
          .toggleStyle(.switch)
        }

        SettingsDivider()

        SettingsRow(
          label: "État",
          detail: store.messagesAutomationHealthFR,
          systemImage: "stethoscope"
        ) {
          Button("Vérifier") {
            Task { await store.refreshAutomationHealthOnly() }
          }
        }
      }

      SettingsCard(
        title: "Si ça coince",
        footnote: "Certains gestes ont besoin d’une vraie fenêtre Messages. "
          + "Elle est alors placée hors de l’écran."
      ) {
        SettingsRow(
          label: "Fenêtre Messages hors écran",
          systemImage: "rectangle.on.rectangle.slash"
        ) {
          Toggle("", isOn: Binding(
            get: { store.messagesAutomationOffscreenWindow },
            set: { store.messagesAutomationOffscreenWindow = $0 }
          ))
          .toggleStyle(.switch)
        }
      }

      HStack {
        Spacer()
        Button("Ouvrir les réglages d’Accessibilité") {
          store.openAccessibilityPrivacySettings()
        }
      }
    }
  }
}
