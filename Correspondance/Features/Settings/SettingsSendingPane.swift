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
        title: "Annuler l’envoi",
        footnote: "La bulle paraît tout de suite, mais le message n’est envoyé qu’au bout de ce délai : "
          + "d’ici là, « Annuler » sous la bulle rend le texte au composer et personne n’aura rien vu. "
          + "Désactivé, « Entrée » veut dire « parti »."
      ) {
        SettingsRow(
          label: "Délai avant envoi",
          detail: store.undoSendDelay.isOn
            ? "Rattrapable pendant \(store.undoSendDelay.labelFR.lowercased())."
            : "Le message part dès qu’on appuie sur Entrée.",
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
        title: "Mode incognito",
        footnote: "Ouvrir un fil n’envoie aucun accusé de lecture — ni au Relais, ni à Messages — "
          + "et le compteur de non-lus reste là, comme un pense-bête. "
          + "Répondre, ou « Marquer comme lu », dit alors au réseau qu’on a lu. ⌘⇧I dans le menu Inbox."
      ) {
        SettingsRow(
          label: "Lire sans le dire",
          detail: store.isIncognito
            ? "Personne ne voit que vous lisez."
            : "Ouvrir un fil l’accuse lu, comme d’habitude.",
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
