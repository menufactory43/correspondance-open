import SwiftUI

/// Lot M2 — pilotage de Messages.app par l'Accessibilité, app cachée.
/// Éteint, Correspondance se comporte exactement comme avant.
struct SettingsAutomationPane: View {
  @Environment(InboxStore.self) private var store
  @Environment(ThemePreferences.self) private var themes

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      SettingsCard(
        title: "Messages en arrière-plan",
        footnote: "Tapback, réponse citée, modifier, annuler l’envoi et « non lu » sur iMessage. "
          + "Messages est lancée cachée et n’apparaît jamais au premier plan."
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
          label: "État du sondage",
          detail: store.messagesAutomationHealthFR,
          systemImage: "stethoscope"
        ) {
          Button("Re-sonder") {
            Task { await store.refreshAutomationHealthOnly() }
          }
        }
      }

      SettingsCard(
        title: "Repli",
        footnote: "Certaines actions exigent une fenêtre réellement dessinée. "
          + "Elle est alors poussée au-delà du bord de l’écran plutôt que masquée."
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
        Button("Ouvrir Confidentialité → Accessibilité") {
          store.openAccessibilityPrivacySettings()
        }
      }
    }
  }
}
