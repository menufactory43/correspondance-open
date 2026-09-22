import SwiftUI
import CorrespondanceCore
import CorrespondanceUI

/// Le délai de grâce d'un envoi : le temps pendant lequel la bulle est là mais
/// rien n'a encore quitté l'appareil.
struct SettingsSendingPane: View {
  @Environment(InboxStore.self) private var store

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      SettingsCard(
        title: String(localized: "Annuler l’envoi"),
        footnote: String(localized: "La bulle s’affiche tout de suite, mais le message part seulement après ce délai. ")
          + String(localized: "D’ici là, « Annuler » le ramène dans le champ de saisie.")
      ) {
        SettingsRow(
          label: String(localized: "Délai avant envoi"),
          detail: store.undoSendDelay.isOn
            ? String(localized: "Rattrapable pendant \(store.undoSendDelay.labelFR.lowercased()).")
            : String(localized: "Le message part tout de suite."),
          systemImage: "arrow.uturn.backward"
        ) {
          Picker("", selection: Binding(
            get: { store.undoSendDelay },
            set: { store.undoSendDelay = $0 }
          )) {
            ForEach(UndoSendDelay.allCases) { choice in
              Text(choice.labelFR).tag(choice)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .fixedSize()
        }
      }

      SettingsCard(
        title: String(localized: "Mode incognito"),
        footnote: String(localized: "Ouvrir une conversation n’envoie pas d’accusé de lecture, et le compteur de non-lus reste. ")
          + String(localized: "Répondre ou « Marquer comme lu » le remet à zéro. Raccourci : ⌘⇧I.")
      ) {
        SettingsRow(
          label: String(localized: "Lire sans le dire"),
          detail: store.isIncognito
            ? String(localized: "Personne ne voit que tu lis.")
            : String(localized: "Ouvrir une conversation la marque lue."),
          systemImage: "eye.slash"
        ) {
          Toggle("", isOn: Binding(
            get: { store.isIncognito },
            set: { store.isIncognito = $0 }
          ))
          .labelsHidden()
          .toggleStyle(.switch)
        }
      }
    }
  }
}
